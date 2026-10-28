//
//  GLTestHostSelfTests.swift
//  GLSmallBusinessTests
//
//  The shared harness has to be trustworthy before other suites lean on it.
//
//  It is deliberately NOT tested for reading screen content, because it cannot do that
//  and neither can anything else in a unit test: SwiftUI renders no UILabels and builds
//  no accessibility tree without a live accessibility client. Four extraction routes
//  were measured and all returned zero strings (label scrape, accessibilityElementCount
//  traversal, recursiveDescription, and a retry after forcing a draw). An earlier
//  version of this file asserted on text and failed for exactly that reason — which is
//  the useful part: had the harness silently returned empty text instead, every content
//  assertion written against it would have passed while checking nothing.
//
//  What hosting DOES prove is below, and it is real: bodies evaluate, both colour
//  schemes and accessibility text sizes lay out, environment objects are present (a
//  missing one SIGTRAPs the whole process), windows are torn down, and every suite that
//  hosts runs one test at a time.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct GLTestHostSelfTests {

    /// The harness evaluates a body at all. If `render` silently did nothing, every
    /// smoke test in every suite would be vacuous.
    @Test func renderActuallyEvaluatesTheBody() throws {
        let container = try TestStore.makeContainer()
        var evaluated = false
        GLTestHost.render(
            Color.clear.onAppear { evaluated = true },
            container: container, inNavigationStack: false)
        #expect(evaluated, "the hosted body never ran — hosting is not doing anything")
    }

    /// Both environment objects reach the view. A screen reading a missing
    /// `@Environment` object traps and takes the test process with it, so this is the
    /// harness's most load-bearing guarantee.
    @Test func injectsBothEnvironmentObjects() throws {
        let container = try TestStore.makeContainer()
        var sawSubscription = false
        var sawAuth = false
        struct Probe: View {
            @Environment(SubscriptionManager.self) private var subscription
            @Environment(GoldLifeAuth.self) private var auth
            let onSee: (Bool, Bool) -> Void
            var body: some View {
                Color.clear.onAppear { onSee(subscription.isSubscribed || !subscription.isSubscribed, auth.state == auth.state) }
            }
        }
        GLTestHost.render(Probe { s, a in sawSubscription = s; sawAuth = a },
                          container: container, inNavigationStack: false)
        #expect(sawSubscription)
        #expect(sawAuth)
    }

    /// A caller-supplied auth is used rather than a fresh one — suites depend on this
    /// to render signed-out vs busy vs error states.
    @Test func usesTheSuppliedAuth() throws {
        let container = try TestStore.makeContainer()
        let auth = GoldLifeAuth()
        auth.errorMessage = "sentinel"
        GLTestHost.render(GoldLifeEmailSignInSheet(auth: auth), container: container)
        #expect(auth.errorMessage == "sentinel", "the harness replaced the caller's auth")
    }

    /// Every scheme and text-size combination the suites use must lay out without
    /// trapping — this is the matrix other suites rely on.
    @Test func rendersEveryScreenVariantWithoutTrapping() throws {
        let world = try TestStore.demoWorld()
        for scheme in [UIUserInterfaceStyle.dark, .light] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                GLTestHost.render(CustomersScreen(), container: world.container,
                                  scheme: scheme, typeSize: size)
            }
        }
        GLTestHost.render(CustomersScreen(), container: world.container, size: GLTestHost.pad)
    }

    /// The window is torn down before `render` returns — detached from its controller,
    /// hidden, no longer key — and the hosted view is off screen. A leaked hosted window
    /// keeps SwiftData observers alive and traps on a later test's save.
    ///
    /// The live window and controller are captured through `probe` (the only moment they
    /// are reachable) and judged after the call returns. An earlier version filtered the
    /// scene's windows for `UIHostingController<AnyView>`, a type the harness never
    /// creates, and so passed on an empty list.
    @Test func releasesTheWindowAfterRendering() throws {
        let container = try TestStore.makeContainer()
        weak var hostedWindow: UIWindow?
        weak var hostedController: UIViewController?
        var wasOnScreenWhileLive = false
        GLTestHost.render(Text("x"), container: container, inNavigationStack: false) { controller in
            hostedController = controller
            hostedWindow = controller.view.window
            wasOnScreenWhileLive = controller.view.window.map { !$0.isHidden } ?? false
        }
        #expect(wasOnScreenWhileLive,
                "the probe never saw the view in a visible window — the teardown checks below would judge nothing")
        #expect(hostedController?.view.window == nil,
                "the hosted view is still attached to a window after render returned")
        if let window = hostedWindow {
            #expect(window.rootViewController == nil, "the window still holds the hosting controller")
            #expect(window.isHidden, "the window is still visible after render returned")
            #expect(!window.isKeyWindow, "a hosted window stayed key after render")
        }
    }

    /// Every suite that hosts a screen runs `.serialized`. `RunLoop.run` inside `render`
    /// drains the main queue, so two parallel @MainActor tests interleave INSIDE a render:
    /// one test's still-live `@Query` view receives another test's save and SwiftData traps
    /// (SIGTRAP — the whole process, not one test). A suite that hosts without the trait
    /// passes alone and dies in the full run, which is the failure the harness exists to
    /// end — so the trait is checked in source, for every suite, here.
    @Test func everyHostingSuiteIsSerialized() {
        let testRoot = GLSource.repoRoot.appendingPathComponent("GLSmallBusinessTests")
        var hosting: [String] = []
        var unserialized: [String] = []
        for file in GLSource.files(under: testRoot, excluding: ["Harness/"])
        where file.text.contains("GLTestHost.render") {
            let lines = file.text.components(separatedBy: "\n")
            let suites = topLevelTypes(lines).filter(\.hasTests)
            // A helper OUTSIDE every suite — a top-level enum with its own `host` — hosts on
            // behalf of every suite in the file.
            let hostsOutsideSuites = lines.indices.contains { index in
                lines[index].contains("GLTestHost.render")
                    && !suites.contains { $0.start <= index && index < $0.end }
            }
            for suite in suites where suite.hosts || hostsOutsideSuites {
                hosting.append(suite.name)
                if !suite.isSerialized { unserialized.append("\(file.path) :: \(suite.name)") }
            }
        }
        #expect(hosting.contains("GLTestHostSelfTests"),
                "the scan did not find this very suite — it is reading the wrong tree")
        #expect(hosting.count >= 3, "only \(hosting.count) hosting suite(s) found; the walk is not reaching the suites")
        #expect(unserialized.isEmpty,
                "these suites host screens without @Suite(.serialized) — they will trap in the full run: \(unserialized.joined(separator: ", "))")
    }
}

// MARK: - Reading the test target the way it is written

/// One top-level type: its declaration line, the line after its closing brace, the attribute
/// lines directly above it, and its lines.
private struct TopLevelType {
    let name: String
    let start: Int
    let end: Int
    let attributes: String
    let body: [String]
    /// A `@Test` at the START of a line — not the two words inside a string literal in this
    /// file, which is how this scanner's own helper type once flagged itself as a suite.
    var hasTests: Bool { body.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@Test") } }
    var hosts: Bool { body.contains { $0.contains("GLTestHost.render") } }
    var isSerialized: Bool { attributes.contains("@Suite(") && attributes.contains(".serialized") }
}

/// Top-level declarations only: this target writes them at column 0 with their attributes on
/// the lines directly above, and closes them with a `}` at column 0. Nested types are indented
/// and so never match.
private func topLevelTypes(_ lines: [String]) -> [TopLevelType] {
    var out: [TopLevelType] = []
    for (index, line) in lines.enumerated() {
        guard let name = declaredTypeName(atColumnZero: line) else { continue }
        let close = lines[(index + 1)...].firstIndex {
            $0.hasPrefix("}") && $0.trimmingCharacters(in: .whitespaces) == "}"
        } ?? (lines.count - 1)
        var attributeLines = [line]
        var above = index - 1
        while above >= 0, lines[above].hasPrefix("@") {
            attributeLines.append(lines[above])
            above -= 1
        }
        out.append(TopLevelType(name: name, start: index, end: close + 1,
                                attributes: attributeLines.joined(separator: "\n"),
                                body: Array(lines[index...close])))
    }
    return out
}

/// The type declared on a column-0 line, whatever attributes and modifiers precede it —
/// `@MainActor @Suite(.serialized, .enabled(if: x)) private final class Foo`. Attributes are
/// skipped by paren balance so a trait list with spaces in it does not hide the keyword.
private func declaredTypeName(atColumnZero line: String) -> String? {
    guard let first = line.first, first != " ", first != "\t", first != "/" else { return nil }
    var rest = Substring(line)
    while rest.first == "@" {
        var depth = 0
        var cut = rest.startIndex
        while cut < rest.endIndex {
            let character = rest[cut]
            if character == "(" { depth += 1 }
            else if character == ")" { depth -= 1 }
            else if character == " ", depth == 0 { break }
            cut = rest.index(after: cut)
        }
        rest = rest[cut...].drop { $0 == " " }
    }
    var words = rest.split(separator: " ").map(String.init)
    let modifiers: Set<String> = ["public", "internal", "private", "fileprivate", "final",
                                  "open", "package", "indirect"]
    while let word = words.first, modifiers.contains(word) { words.removeFirst() }
    guard let keyword = words.first, ["struct", "class", "enum", "actor"].contains(keyword),
          words.count > 1 else { return nil }
    let name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? nil : String(name)
}
