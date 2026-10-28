//
//  ScreenNameParityTests.swift
//  GLSmallBusinessTests
//
//  Law 22: a screen's NAME is one atom. The row that opens a screen and the screen's own title
//  say the same words (audit 2026-10-03 F110 / L12: Menu "Income & Expenses" opened
//  "Statistics", "Get Paid by Card" opened "Payments", "Documents" opened "All Documents", and
//  All Documents' "Employee Wages (Year-End)" opened plain "Employees"). Owner's pick: each
//  screen takes its row's name (that row is now "Employee Wages" on both: the year-end
//  wording overflowed the large title).
//
//  Read from the source: every NavigationLink (and every Button routed through an
//  `activeDocument` case) on the Menu and All Documents, the screen it opens, and the literal
//  titles that screen's `.navigationTitle(` can show.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@Suite struct ScreenNameParityTests {

    static let hubs = ["Screens/MenuScreen.swift", "Screens/AllDocumentsScreen.swift"]

    /// Rows that still name their screen differently, in files outside the 2026-10-03 G1 fix
    /// (reported to the lead as out of scope). A row listed here that matches fails the test,
    /// so the list can only shrink.
    static let pending: Set<String> = [
        "AllDocumentsScreen.swift: Insurance & Licensing",
        "AllDocumentsScreen.swift: Income & Expenses (Year-End)",
        "AllDocumentsScreen.swift: Subcontractor 1099s (Year-End)",
    ]

    @Test func everyHubRowNamesTheScreenItOpens() {
        let files = GLSource.codeFiles()
        var wrong: [String] = []
        var stale: [String] = []
        var checked: [String] = []
        for hub in Self.hubs {
            guard let text = files.first(where: { $0.path == hub })?.text else {
                Issue.record("\(hub) not found")
                continue
            }
            let name = (hub as NSString).lastPathComponent
            for link in ScreenNameScan.rows(in: text.components(separatedBy: "\n")) {
                let titles = ScreenNameScan.titles(ofScreen: link.destination, in: files)
                guard !titles.isEmpty else { continue }   // a package screen: its title isn't here
                let key = "\(name): \(link.label)"
                checked.append(key)
                let matches = titles.contains(link.label)
                if Self.pending.contains(key) {
                    if matches { stale.append(key) }
                } else if !matches {
                    wrong.append("\(key) opens \(link.destination), titled \(titles.sorted())")
                }
            }
        }
        for key in ["MenuScreen.swift: Documents", "MenuScreen.swift: Income & Expenses",
                    "MenuScreen.swift: Connect Stripe", "MenuScreen.swift: Connect Zelle", "AllDocumentsScreen.swift: Employee Wages"] {
            #expect(checked.contains(key), "the scan never reached \(key); checked \(checked)")
        }
        #expect(wrong.isEmpty, "rows whose screen has another name (law 22): \(wrong)")
        #expect(stale.isEmpty, "these match now; take them off pending: \(stale)")
    }

    /// The wage door passes its flag, so the Employees list it opens wears the row's name.
    @Test func employeeWagesDoorOpensTheWageTitledList() {
        let documents = GLSource.code("Screens/AllDocumentsScreen.swift") ?? ""
        #expect(documents.contains("EmployeesScreen(isWageDoor: true)"))
        #expect(EmployeesScreen.title(isWageDoor: true) == mbLoc("Employee Wages"))
        #expect(EmployeesScreen.title(isWageDoor: false) == mbLoc("Employees"))
    }

    /// The scanner on the shapes it has to read.
    @Test func scanReadsLinksAndRoutedButtons() {
        let source = """
        NavigationLink {
            Host(placeholderTitle: mbLoc("Wrong")) { profile in
                TargetScreen(profile: profile)
            }
        } label: {
            GLMenuRow("Target", systemImage: "doc")
        }
        Button {
            activeDocument = .w9
        } label: {
            row("Generate a W-9", systemImage: "doc")
        }
        .navigationDestination(item: $activeDocument) { document in
            switch document {
            case .w9:
                W9Sheet(profile: profile)
            }
        }
        """.components(separatedBy: "\n")
        let rows = ScreenNameScan.rows(in: source)
        #expect(rows.map(\.label) == ["Target", "Generate a W-9"])
        #expect(rows.map(\.destination) == ["TargetScreen", "W9Sheet"])
        let screen = """
        struct TargetScreen: View {
            var body: some View {
                List { }
                .navigationTitle(GLScript.padded(flag ? mbLoc("Target") : mbLoc("Other")))
            }
        }
        """
        #expect(ScreenNameScan.titles(ofScreen: "TargetScreen", in: [("T.swift", screen)]) == ["Target", "Other"])
    }
}

enum ScreenNameScan {
    struct Row: Equatable { let label: String; let destination: String }

    /// Every `NavigationLink { Destination } label: { "Label" }` and every
    /// `Button { activeDocument = .case } label: { "Label" }` in the lines.
    static func rows(in lines: [String]) -> [Row] {
        let routes = documentRoutes(in: lines)
        var rows: [Row] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isLink = trimmed.hasPrefix("NavigationLink {")
            let isButton = trimmed.hasPrefix("Button {")
            guard isLink || isButton,
                  let split = (index..<lines.count).first(where: { lines[$0].contains("} label: {") }),
                  let end = closing(from: split, in: lines),
                  let label = lines[split...end].lazy.compactMap(firstLiteral).first else { continue }
            let action = lines[index..<split]
            var destination: String?
            if isLink {
                destination = action.flatMap(typeCalls).last
            } else if let route = action.lazy.compactMap({ $0.firstMatch(of: #/activeDocument = \.([A-Za-z0-9_]+)/#) }).first {
                destination = routes[String(route.1)]
            }
            if let destination { rows.append(Row(label: label, destination: destination)) }
        }
        return rows
    }

    /// The literal titles a screen's `.navigationTitle(` can show (`mbLoc("…")` literals on that
    /// line), or a `title: "…"` it hands the list it wraps when it sets no title of its own.
    static func titles(ofScreen name: String, in files: [(path: String, text: String)]) -> Set<String> {
        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: {
                $0.range(of: #"\bstruct\s+\#(name)\s*:"#, options: .regularExpression) != nil
            }), let end = closing(from: start, in: lines) else { continue }
            let body = lines[start...end]
            var titles = Set<String>()
            for line in body where line.contains(".navigationTitle(") {
                for match in line.matches(of: #/mbLoc\("([^"\\]*)"\)/#) { titles.insert(String(match.1)) }
                // A title computed by the screen's own `Self.title(…)`: the literals it returns.
                for call in line.matches(of: #/Self\.([a-zA-Z_][A-Za-z0-9_]*)\(/#) {
                    let function = Array(body)
                    guard let open = function.firstIndex(where: { $0.contains("func \(call.1)(") }),
                          let close = closing(from: open, in: function) else { continue }
                    for inner in function[open...close] {
                        for match in inner.matches(of: #/mbLoc\("([^"\\]*)"\)/#) { titles.insert(String(match.1)) }
                    }
                }
            }
            if titles.isEmpty {
                for line in body {
                    for match in line.matches(of: #/title: "([^"\\]*)"/#) { titles.insert(String(match.1)) }
                }
            }
            return titles
        }
        return []
    }

    /// `case .w9:` → the screen on the next line, from the hub's `navigationDestination` switch.
    private static func documentRoutes(in lines: [String]) -> [String: String] {
        var routes: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            guard let match = line.firstMatch(of: #/^\s*case \.([A-Za-z0-9_]+):\s*$/#),
                  index + 1 < lines.count, let type = typeCalls(lines[index + 1]).first else { continue }
            routes[String(match.1)] = type
        }
        return routes
    }

    /// `TypeName(` calls on a line (an upper-case first letter), in order.
    nonisolated private static func typeCalls(_ line: String) -> [String] {
        line.matches(of: #/(?:^|[^A-Za-z0-9_.])([A-Z][A-Za-z0-9_]*)\(/#).map { String($0.1) }
    }

    nonisolated private static func firstLiteral(_ line: String) -> String? {
        line.firstMatch(of: #/"([^"\\]*)"/#).map { String($0.1) }
    }

    /// The line where the block opened on `line` closes (counting from its LAST `{`, so
    /// `} label: {` opens the label block).
    private static func closing(from line: Int, in lines: [String]) -> Int? {
        var depth = 0
        for index in line..<lines.count {
            var text = Substring(lines[index])
            if index == line, let last = text.lastIndex(of: "{") { text = text[last...] }
            for char in text where char == "{" || char == "}" {
                depth += char == "{" ? 1 : -1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
