//
//  ScriptTitleClearanceTests.swift — the STRUCTURAL half of the title net.
//
//  GLScriptMetricsTests (in GoldLifeUI) proves the mechanism is correct. This
//  proves it is actually APPLIED. The 2026-08-31 report ("the g's hang too
//  close to the content below" on Language) was not a wrong value — that
//  screen had no clearance modifier at all, because the margin is opt-in per
//  call site and 7 screens never got one. A source walk is the only thing that
//  catches a screen someone forgets, which is exactly how this kept getting
//  missed by spot-checking a handful of screens by eye.
//
//  The walk is the shared scanner (Harness/SourceScan.swift).
//

import Testing
import Foundation

struct ScriptTitleClearanceTests {

    /// Every titled screen renders a LARGE script title (law 57), so every one
    /// must claim per-string descender clearance. No exemptions.
    @Test func everyLargeTitleScreenClaimsPerStringClearance() {
        var offenders: [String] = []
        for file in GLSource.files() {
            let text = file.text
            guard text.contains(".navigationTitle(") else { continue }
            if !text.contains("GLScript.titleClearance(for:") {
                offenders.append((file.path as NSString).lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these screens render a large script title with no descender clearance: \(offenders.joined(separator: ", "))")
    }

    /// Law 57: every screen with a bar wears a large title — sheets included.
    /// Pinning a title inline is the shape this rule retired.
    @Test func noScreenPinsItsTitleInline() {
        var offenders: [String] = []
        for file in GLSource.files() {
            for line in file.text.split(separator: "\n")
            where line.contains("TitleDisplayMode(.inline") {
                offenders.append("\((file.path as NSString).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "titles pinned inline (law 57 — large everywhere): \(offenders)")
    }

    /// Nobody may reintroduce a fleet-wide clearance constant. The whole defect
    /// class was one number standing in for a per-string measurement.
    @Test func noFleetWideClearanceConstantSurvives() {
        var offenders: [String] = []
        for file in GLSource.files() {
            // `titleClearance` NOT followed by `(for:` is the banned constant form.
            for line in file.text.split(separator: "\n") where line.contains("titleClearance") {
                if !line.contains("titleClearance(for:") {
                    offenders.append("\((file.path as NSString).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "fleet-wide clearance constant reintroduced: \(offenders)")
    }

    /// Law 57's recipe is three lines at EVERY call site: `.navigationTitle(GLScript.padded(…))`,
    /// `.toolbarTitleDisplayMode(.large)` and `.contentMargins(.top, GLScript.titleClearance(for: …))`
    /// on the same view (audit 2026-10-03 F137: three screens had only two, so a pushed screen
    /// inherits an inline parent's mode). Checked per call site, on the modifier chain the title
    /// sits in, not per file: a file with two screens can't lend one's line to the other.
    @Test func everyNavigationTitleSiteHasAllThreeRecipeLines() {
        var offenders: [String] = []
        var stale: [String] = []
        var checked = 0
        for file in GLSource.codeFiles() {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".navigationTitle(") {
                checked += 1
                let chain = TitleRecipeScan.chain(around: index, in: lines)
                var missing: [String] = []
                if !chain.contains(where: { $0.contains(".toolbarTitleDisplayMode(.large)") }) {
                    missing.append(".toolbarTitleDisplayMode(.large)")
                }
                // A title set on a host (titled before its content exists) may leave the clearance
                // to the scrolling content it hosts: the same file then measures the SAME string.
                let hostedClearance = TitleRecipeScan.titleArgument(of: line).map {
                    file.text.contains("titleClearance(for: \($0))")
                } ?? false
                if !chain.contains(where: { $0.contains("GLScript.titleClearance(for:") }) && !hostedClearance {
                    missing.append(".contentMargins(.top, GLScript.titleClearance(for:))")
                }
                let name = (file.path as NSString).lastPathComponent
                let key = "\(name): \(line.trimmingCharacters(in: .whitespaces))"
                if Self.recipePending.contains(key) {
                    if missing.isEmpty { stale.append(key) }
                    continue
                }
                if !missing.isEmpty { offenders.append("\(name):\(index + 1) lacks \(missing)") }
            }
        }
        #expect(checked > 50, "the scan found only \(checked) title sites, so it is not reading the app")
        #expect(offenders.isEmpty, "title sites missing a law 57 recipe line: \(offenders)")
        #expect(stale.isEmpty, "these now carry the full recipe; take them off recipePending: \(stale)")
    }

    /// Root screens (the first screen of their own stack, where `.automatic` already draws large)
    /// still missing `.toolbarTitleDisplayMode(.large)`. Their files are outside the 2026-10-03
    /// G1 fix (reported to the lead as out of scope). The test fails once one is fixed, so the list
    /// can only shrink.
    static let recipePending: Set<String> = [
        "CalendarScreen.swift: .navigationTitle(GLScript.padded(mbLoc(\"Calendar\")))",
        "CustomersScreen.swift: .navigationTitle(GLScript.padded(mbLoc(\"Customers\")))",
        "IPadRootSplitView.swift: .navigationTitle(GLScript.padded(mbLoc(\"Customers\")))",
        "IPadRootSplitView.swift: .navigationTitle(GLScript.padded(mbLoc(\"Employees\")))",
        "IPadRootSplitView.swift: .navigationTitle(GLScript.padded(mbLoc(\"Subcontractors\")))",
    ]

    /// The chain scan on the shapes it has to read: a closure modifier and a wrapped argument
    /// between the title and its partners, and a second screen in the same file.
    @Test func recipeChainScanReadsOneViewAtATime() {
        let source = """
        var body: some View {
            List {
                Text("Row")
            }
            .contentMargins(.top,
                            GLScript.titleClearance(for: GLScript.padded(mbLoc("A"))), for: .scrollContent)
            .toolbar {
                ToolbarItem { Button("X") { } }
            }
            .navigationTitle(GLScript.padded(mbLoc("A")))
            .overlay {
                Text("Y")
            }
            .toolbarTitleDisplayMode(.large)
        }
        var other: some View {
            Form { }
            .navigationTitle(GLScript.padded(mbLoc("B")))
        }
        """.components(separatedBy: "\n")
        let first = TitleRecipeScan.chain(around: 9, in: source)
        #expect(first.contains { $0.contains("titleClearance(for:") })
        #expect(first.contains { $0.contains(".toolbarTitleDisplayMode(.large)") })
        let second = TitleRecipeScan.chain(around: 17, in: source)
        #expect(!second.contains { $0.contains(".toolbarTitleDisplayMode(.large)") })
        #expect(!second.contains { $0.contains("titleClearance(for:") })
    }

    /// Bar titles must go through `GLScript.padded`, which is what buys the
    /// trailing swash its room (per-string). A raw `.navigationTitle(mbLoc(...))`
    /// is the shape that shipped the clipped D.
    @Test func everyBarTitleGoesThroughPadded() {
        var offenders: [String] = []
        for file in GLSource.files() {
            for line in file.text.split(separator: "\n") where line.contains(".navigationTitle(") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // No empty-title exemption: the principal-atom stand-in is retired (law 57).
                if !trimmed.contains("GLScript.padded(") {
                    offenders.append("\((file.path as NSString).lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "bar titles bypassing GLScript.padded: \(offenders)")
    }
}

/// The modifier chain a `.navigationTitle(` line sits in, read from the source: walking up and
/// down from the title through `.modifier` lines, stepping over a modifier's closure body or
/// wrapped arguments as one unit, and stopping at the view the chain hangs off.
enum TitleRecipeScan {
    static func chain(around row: Int, in lines: [String]) -> [String] {
        var chain = [lines[row]]
        // Up: a line that closes more than it opens belongs to a modifier opened above it.
        var index = row - 1
        while index >= 0 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index -= 1; continue }
            if net(lines[index]) < 0, let opener = opener(closingAt: index, in: lines) {
                guard lines[opener].trimmingCharacters(in: .whitespaces).hasPrefix(".") else { break }
                chain += lines[opener...index]
                index = opener - 1
                continue
            }
            guard trimmed.hasPrefix(".") else { break }
            chain.append(lines[index])
            index -= 1
        }
        // Down: top-level `.modifier` lines, each followed through its closure or wrapped arguments.
        index = row + 1
        var depth = net(lines[row])
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
                guard trimmed.hasPrefix(".") else { break }
            }
            chain.append(lines[index])
            depth += net(lines[index])
            if depth < 0 { break }
            index += 1
        }
        return chain
    }

    /// `GLScript.padded(mbLoc("A"))` from `.navigationTitle(GLScript.padded(mbLoc("A")))`.
    static func titleArgument(of line: String) -> String? {
        guard let start = line.range(of: ".navigationTitle(") else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < line.endIndex {
            switch line[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(line[start.upperBound..<index]) }
            default: break
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Opening minus closing braces and parentheses on a line, outside string literals.
    private static func net(_ line: String) -> Int {
        var count = 0
        var inString = false
        var previous: Character = " "
        for char in line {
            if char == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                switch char {
                case "{", "(": count += 1
                case "}", ")": count -= 1
                default: break
                }
            }
            previous = char
        }
        return count
    }

    /// The line that opens what `line` closes (walking up until the running count balances).
    private static func opener(closingAt line: Int, in lines: [String]) -> Int? {
        var balance = 0
        var index = line
        while index >= 0 {
            balance += net(lines[index])
            if balance >= 0 { return index }
            index -= 1
        }
        return nil
    }
}
