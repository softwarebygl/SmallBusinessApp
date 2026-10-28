//
//  DesignSnapshotTests.swift
//  GLSmallBusinessTests
//
//  Hosted-window PNG snapshots of real screens with real demo data — the visual
//  gate for the Gold Life design unification (see claude/docs/GoldLifeUI-Plan.md).
//
//  Why a hosted window and not ImageRenderer: the QA pass of 2026-08-18 proved
//  ImageRenderer renders ZERO pixels for ScrollView and placeholders for
//  List/Form/NavigationStack, and ignores .preferredColorScheme. GLTestHost puts a
//  real UIHostingController in a real UIWindow — the scheme forced with
//  overrideUserInterfaceStyle, Dynamic Type through the SwiftUI environment — and
//  hands the live controller to `probe`, which is where the capture happens.
//
//  Runs ONLY with MM_SNAPSHOT_DIR set: it writes <dir>/<screen>-<scheme>-<size>.png
//  and a manifest.sha256 so a redesign phase can diff against the pre-redesign
//  baseline byte-for-byte. Set it as TEST_RUNNER_MM_SNAPSHOT_DIR when running via
//  xcodebuild. Without it the suite is skipped: in the gate run it rendered nine
//  screens a third time with a 7s settle loop and asserted nothing — 27% of the
//  unit suite (suite review 2026-09-02). ViewRenderingTests and the coverage suites
//  own the crash-free render claim.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
import CryptoKit
@testable import GLSmallBusiness

@Suite(.serialized, .enabled(if: !(ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] ?? "").isEmpty))
@MainActor
struct DesignSnapshotTests {

    // Every cell in the matrix is a (screen, scheme, dynamic-type) triple.
    // Widths: 393 = iPhone; 1024 = iPad regular width for adaptive screens.
    private struct Cell {
        let name: String
        let scheme: UIUserInterfaceStyle
        let typeSize: DynamicTypeSize
        let size: CGSize
        var suffix: String {
            let s = scheme == .dark ? "dark" : "light"
            let t: String = switch typeSize {
                case .large: "L"
                case .accessibility3: "AX3"
                default: "XXXL"
            }
            return "\(name)-\(s)-\(t)-\(Int(size.width))"
        }
    }

    private static let schemes: [UIUserInterfaceStyle] = [.dark, .light]
    private static let sizes: [DynamicTypeSize] = [.large, .xxxLarge]

    /// Host through the shared harness, settle until the frame stops changing, capture.
    private func snapshot<V: View>(_ view: V, _ container: ModelContainer, _ cell: Cell) {
        GLTestHost.render(view, container: container, scheme: cell.scheme,
                          typeSize: cell.typeSize, size: cell.size) { controller in
            guard let window = controller.view.window else {
                Issue.record("\(cell.suffix): the hosted controller has no window — nothing to capture")
                return
            }
            // Settle until the rendered frame stops changing (bounded), so async
            // loads and appear-animations never leave a half-drawn baseline.
            // Stable AND has content: two identical black frames also "stabilize", and
            // a screen that paints black-then-content (CategoriesScreen) stopped the
            // loop early and captured the black (2026-08-18). Bounded at ~5s.
            // THREE consecutive identical frames, not two: a screen whose height
            // changes when async content lands (StoreKit products on the subscription
            // screen) settles briefly, moves, and settles again — two matching probes
            // caught the intermediate state and the cell flapped between runs
            // (2026-08-19). Bounded at ~7s.
            var last: Data? = nil, prev: Data? = nil
            for _ in 0..<28 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
                let probe = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                    controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                if probe == last, last == prev, Self.hasInk(probe) { break }
                prev = last; last = probe
            }

            // PNGs are written only under the env var. The suite trait gates every test on it;
            // this guard keeps the WRITE under it too, should that gate ever loosen.
            guard let dir = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"], !dir.isEmpty else { return }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: {
                let f = UIGraphicsImageRendererFormat.default(); f.scale = 2; return f }())
            // host.view.drawHierarchy(afterScreenUpdates: true) is the ONE capture path
            // that works here, bisected 2026-08-18 against a plain white Text, the
            // period control, and both tab screens:
            //   window.drawHierarchy      → blank (a test-made UIWindow has no windowScene)
            //   window.layer.render(in:)  → shapes yes, TEXT no (glyphs never rasterize
            //                               without a committed frame; text-only screens
            //                               came out single-color)
            //   host.view.drawHierarchy   → everything, because afterScreenUpdates forces
            //                               the render server to commit the frame first.
            let png = renderer.pngData { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            // Vacuity guard: a blank capture is a harness bug, never a pass.
            #expect(Self.hasInk(png), "\(cell.suffix): blank snapshot — capture path painted nothing")
            let url = URL(fileURLWithPath: dir).appendingPathComponent(cell.suffix + ".png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: url)
            let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let line = "\(sha)  \(cell.suffix).png\n"
            let manifest = URL(fileURLWithPath: dir).appendingPathComponent("manifest.sha256")
            if let h = try? FileHandle(forWritingTo: manifest) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: manifest, atomically: true, encoding: .utf8) }
        }
    }

    /// The decision-render set: the screens that make or break the eight open
    /// design decisions (rows/cards, hub, forms, status capsules, watermark, titles).
    @Test func snapshotDecisionScreens() throws {
        // DemoWorld's rows are SORTED, so `.first` is always the same record. An unsorted
        // fetch handed a DIFFERENT customer between runs and the baseline flapped between
        // two real, correct screens (caught 2026-08-19 — "Nguyen, Sofia" vs "Carter,
        // Danielle"). A visual baseline must pin its subject, not just its layout.
        let world = try TestStore.demoWorld()
        let customer = try #require(world.customers.first)
        let invoice = try #require(world.invoices.first)
        let estimate = try #require(world.estimates.first)
        for scheme in Self.schemes {
            for size in Self.sizes {
                func cell(_ n: String) -> Cell { Cell(name: n, scheme: scheme, typeSize: size, size: GLTestHost.phone) }
                snapshot(CustomersScreen(), world.container, cell("customers"))
                snapshot(MenuScreen(), world.container, cell("menu"))
                snapshot(CustomerDetailScreen(customer: customer), world.container, cell("customerDetail"))
                snapshot(InvoiceDetailScreen(invoice: invoice), world.container, cell("invoiceDetail"))
                snapshot(AllInvoicesScreen(), world.container, cell("allInvoices"))
                snapshot(EstimateDetailScreen(estimate: estimate), world.container, cell("estimateDetail"))
                snapshot(StatsScreen(), world.container, cell("stats"))
                snapshot(SettingsScreen(), world.container, cell("settings"))
                snapshot(CustomerFormScreen(), world.container, cell("customerForm"))
            }
        }
    }

    /// True if the PNG carries real content. Counts pixels that differ from the
    /// dominant background tone rather than min/max range: a pure-black screen
    /// with white text and one gold number is mostly background, so a coarse
    /// range check misread dark screens as blank (2026-08-18). A blank window is a
    /// single tone everywhere; any real screen has hundreds of departures.
    nonisolated private static func hasInk(_ data: Data) -> Bool {
        guard let img = UIImage(data: data)?.cgImage else { return false }
        let w = 96, h = 192
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Int](repeating: 0, count: 64)
        var vals = [Int](); vals.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            let v = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            vals.append(v); hist[min(63, v / 4)] += 1
        }
        let bg = hist.enumerated().max(by: { $0.element < $1.element })!.offset * 4
        let departures = vals.reduce(0) { $0 + (abs($1 - bg) > 24 ? 1 : 0) }
        return departures > 200   // ~1% of an 18k-cell grid; a blank window is 0
    }
}
