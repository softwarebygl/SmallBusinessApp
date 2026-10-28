//
//  ReadableColumnTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 C66: on a wide screen the standing-notice card, the lists and the detail
//  cards share the fleet's one 640 pt column. Source scan, comments stripped; the on-screen
//  proof is ReadableWidthUITests.
//

import Testing
import Foundation

struct ReadableColumnTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness")

    /// Full-width surfaces that keep the banner slot but not the cap, with the reason. Shrink-only.
    private static let fullWidth: [String: String] = [
        "IPadRootSplitView.swift": "the split view's panes are the iPad layout itself",
        "CalendarScreen.swift": "the month grid uses the whole width",
        "StatsScreen.swift": "charts use the whole width",
    ]

    private static func code(_ path: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    @Test func theBannerSlotCapsItsContentByDefault() throws {
        let source = try Self.code("UIComponents/MBSystemBanners.swift")
        #expect(source.contains("func mbSystemBanners(capsContent: Bool = true)"))
        #expect(source.contains("glReadableWidth()"))
    }

    @Test func onlyTheFullWidthSurfacesOptOutOfTheCap() throws {
        let screens = Self.root.appendingPathComponent("Screens")
        let files = try FileManager.default.contentsOfDirectory(at: screens, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for file in files {
            let source = try Self.code("Screens/" + file.lastPathComponent)
            if source.contains("capsContent: false"), Self.fullWidth[file.lastPathComponent] == nil {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "screens that opted out of the readable column without a reason:\n\(offenders.joined(separator: "\n"))")
        for name in Self.fullWidth.keys {
            #expect(try Self.code("Screens/" + name).contains("capsContent: false"),
                    "\(name) no longer opts out; drop it from the exempt list")
        }
    }

    @Test func theDetailScreensHoldTheirCardsToTheColumn() throws {
        for name in ["CustomerDetailScreen", "EstimateDetailScreen", "InvoiceDetailScreen", "JobDetailScreen",
                     "ReceiptDetailScreen", "ProjectScreens", "ChangeOrderScreens"] {
            #expect(try Self.code("Screens/\(name).swift").contains(".glReadableWidth()"),
                    "\(name) lets its cards run edge to edge on a wide screen")
        }
    }
}
