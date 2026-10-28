//
//  SearchGutterTests.swift
//  GLSmallBusinessTests
//
//  Law 55 (search alignment parity): the search field, banners and cards share the same
//  leading and trailing edges. Where the 8 pt gutter comes from depends on the List the
//  search row sits in, so the right search row does too (GoldLifeUI `GLInListSearchHeader`):
//  - a plain list (`.listStyle(.plain)`) has no content margins and each card carries the
//    gutter itself, so its search row is `.asPlainListRow` (the package adds the gutter);
//  - the grouped skin (`.glFormBackground()` / `.glGroupedFormSkin()`) already puts every row
//    on the gutter through its content margins, so its search row is `.asListRow`.
//  Either one with `.glScreenGutter()` on top is the gutter twice (the Price Sheet at 16 pt
//  while its cards sat at 8 pt, audit 2026-10-03 F28); a row with no gutter in a plain list is
//  the owner's 2026-10-03 report ("The textfield stretches from edge to edge").
//

import Testing
import Foundation

@Suite struct SearchGutterTests {

    @Test func everyInListSearchRowMatchesItsListContainer() {
        var wrong: [String] = []
        var checked = 0
        for file in GLSource.files() {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("GLInListSearchHeader(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                checked += 1
                let place = "\(file.path):\(index + 1)"
                guard let container = SearchRowContainer.of(lineAt: index, in: lines) else {
                    wrong.append("\(place) (no enclosing List found)")
                    continue
                }
                if let problem = SearchRowContainer.problem(with: line, in: container) {
                    wrong.append("\(place) (\(problem))")
                }
            }
        }
        #expect(checked > 0, "the scan found no search rows at all, so it checked nothing")
        #expect(wrong.isEmpty, "search rows on the wrong gutter for their list: \(wrong)")
    }

    /// The scanner itself, on the shapes it has to tell apart, so a scan that misreads a
    /// container can't pass the test above.
    @Test func containerScanTellsPlainFromGrouped() {
        let plain = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
            ForEach(rows) { row in
                Text(row.name)
            }
        }
        .listStyle(.plain)
        .overlay { Text("x") }
        """.components(separatedBy: "\n")
        let grouped = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asListRow
            Section("A") {
                Text("Row { not a brace }")
            }
        }
        .glFormBackground()
        """.components(separatedBy: "\n")
        let inSection = """
        List(selection: $picked) {
            Section {
                GLInListSearchHeader(text: $q, prompt: "Search").asListRow
            }
        }
        .listStyle(.plain)
        """.components(separatedBy: "\n")
        let viaChrome = """
        var body: some View {
            List {
                GLInListSearchHeader(text: $q, prompt: "Search").asListRow
            }
            .modifier(Chrome())
        }
        private struct Chrome: ViewModifier {
            func body(content: Content) -> some View {
                content.glFormBackground()
            }
        }
        """.components(separatedBy: "\n")
        let wrapped = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asListRow
        }
        .swipeDeleteConfirmation($pending, title: "Delete?",
                                 message: "Gone for good.") {
            delete($0)
        }
        .glFormBackground()
        """.components(separatedBy: "\n")
        #expect(SearchRowContainer.of(lineAt: 1, in: wrapped) == .grouped)
        #expect(SearchRowContainer.of(lineAt: 1, in: plain) == .plain)
        #expect(SearchRowContainer.of(lineAt: 1, in: grouped) == .grouped)
        #expect(SearchRowContainer.of(lineAt: 2, in: inSection) == .plain)
        #expect(SearchRowContainer.of(lineAt: 2, in: viaChrome) == .grouped)
        #expect(SearchRowContainer.problem(with: plain[1], in: .plain) == nil)
        #expect(SearchRowContainer.problem(with: grouped[1], in: .grouped) == nil)
        #expect(SearchRowContainer.problem(with: plain[1], in: .grouped) != nil)
        #expect(SearchRowContainer.problem(with: grouped[1], in: .plain) != nil)
        let doubled = #"GLInListSearchHeader(text: $q, prompt: "S").asListRow.glScreenGutter()"#
        #expect(SearchRowContainer.problem(with: doubled, in: .grouped) != nil)
        #expect(SearchRowContainer.problem(with: doubled, in: .plain) != nil)
    }

    @Test func everySearchFilterBarSitsOnTheScreenGutter() {
        var missing: [String] = []
        for file in GLSource.files() {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("GLSearchFilterBar(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let following = lines[index..<min(index + 3, lines.count)].joined()
                if !following.contains("GLLayout.rowCardInset") && !following.contains(".glScreenGutter()") {
                    missing.append("\(file.path):\(index + 1)")
                }
            }
        }
        #expect(missing.isEmpty, "search + filter rows without the 8 pt gutter: \(missing)")
    }

    /// Law 55 for the ROWS, not only the search row (audit 2026-10-03 F49/F118): in a plain list
    /// that hosts an in-list search, every other row and every section footer sits at zero
    /// insets on the same 8 pt gutter as the search capsule. A row that keeps the system inset
    /// starts at 16-20 pt under a capsule that starts at 8 pt (View all hours, the orphan notice).
    @Test func everyRowOfAPlainSearchListSitsOnTheGutter() {
        var wrong: [String] = []
        var checked = 0
        let structs = SearchRowContainer.viewStructs(in: GLSource.files().map { $0.text.components(separatedBy: "\n") })
        for file in GLSource.files() {
            let lines = file.text.components(separatedBy: "\n")
            var seenBlocks = Set<Int>()
            for (index, line) in lines.enumerated()
            where line.contains("GLInListSearchHeader(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                guard SearchRowContainer.of(lineAt: index, in: lines) == .plain,
                      let block = SearchRowContainer.listBlock(forRowAt: index, in: lines),
                      seenBlocks.insert(block.lowerBound).inserted else { continue }
                for problem in SearchRowContainer.rowProblems(inListBlock: block, of: lines, structs: structs) {
                    checked += 1
                    if let what = problem.what { wrong.append("\(file.path):\(problem.line + 1) (\(what))") }
                }
            }
        }
        #expect(checked > 0, "the scan found no rows in plain search lists, so it checked nothing")
        #expect(wrong.isEmpty, "rows of plain search lists off the 8 pt gutter: \(wrong)")
    }

    /// The row scanner on the shapes it has to tell apart.
    @Test func rowScanTellsGutteredRowsFromSystemInsetRows() {
        let source = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
            if rows.isEmpty {
                ContentUnavailableView("None", systemImage: "tray")
                    .listRowBackground(Color.clear)
            } else {
                Text("A notice")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                Text("A guttered notice")
                    .padding(.horizontal, GLLayout.rowCardInset)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Section {
                    ForEach(rows) { row in
                        Button { open(row) } label: { card(row) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                } footer: {
                    Text("Total")
                }
            }
        }
        .listStyle(.plain)
        private func card(_ row: Row) -> some View {
            Text(row.name)
                .padding(.horizontal, GLLayout.rowCardInset)
        }
        """.components(separatedBy: "\n")
        guard let block = SearchRowContainer.listBlock(forRowAt: 1, in: source) else {
            Issue.record("no List block found")
            return
        }
        let problems = SearchRowContainer.rowProblems(inListBlock: block, of: source)
        // The empty state is skipped; the bare notice and the footer are flagged; the guttered
        // notice and the card rows pass.
        #expect(problems.count == 4)
        #expect(problems.filter { $0.what != nil }.map(\.line) == [7, 19])
    }
}

/// Which kind of List a search row sits in, read from the source: the innermost `List` whose
/// block is still open at the row, then the modifiers chained on that List's closing brace
/// (a `.modifier(Name())` declared in the same file counts as what its body applies).
enum SearchRowContainer: Equatable {
    case plain, grouped

    /// What is wrong with `line` for `container`, or nil when it is right.
    static func problem(with line: String, in container: SearchRowContainer) -> String? {
        let doubled = line.contains(".glScreenGutter()")
        switch container {
        case .plain:
            guard line.contains(".asPlainListRow") else {
                return "plain list: use .asPlainListRow, which carries the gutter, with no padding of its own"
            }
            return doubled ? "plain list: .asPlainListRow already has the gutter, drop .glScreenGutter()" : nil
        case .grouped:
            if doubled || line.contains(".asPlainListRow") {
                return "grouped skin: its margins already hold the gutter, so this adds it twice; use .asListRow alone"
            }
            return line.contains(".asListRow") ? nil : "grouped skin: use .asListRow"
        }
    }

    /// The container of the row on line `row`, or nil when no enclosing `List` is found.
    static func of(lineAt row: Int, in lines: [String]) -> SearchRowContainer? {
        guard let chain = listModifiers(forRowAt: row, in: lines) else { return nil }
        let plain = chain.contains { $0.contains(".listStyle(.plain)") }
        let skinned = chain.contains { $0.contains(".glFormBackground()") || $0.contains(".glGroupedFormSkin()") }
        // Only the grouped skin puts rows on the gutter; any other List needs the row to carry it.
        return skinned && !plain ? .grouped : .plain
    }

    /// The lines of the `List` block enclosing the row on line `row` (opener through closing
    /// brace), or nil when no enclosing `List` is found.
    static func listBlock(forRowAt row: Int, in lines: [String]) -> ClosedRange<Int>? {
        guard let opener = enclosingListLine(above: row, in: lines),
              let closer = closingLine(ofBlockOpenedAt: opener, in: lines) else { return nil }
        return opener...closer
    }

    /// One row (or footer) of a plain search list: the line it was found on, and what is wrong
    /// with it (nil when it sits on the gutter).
    struct RowFinding { let line: Int; let what: String? }

    /// Every row of a plain search list inside `block`, checked for the gutter. A row is the
    /// modifier chain holding `.listRowBackground(`; its unit is every line since the previous
    /// row, so the view it modifies is in it. An empty state (`ContentUnavailableView`) is
    /// centered and skipped. A row passes when its chain sets `.listRowInsets(EdgeInsets())`
    /// and its unit carries the gutter (`GLLayout.rowCardInset`, directly or in what the unit
    /// calls: a function in the same file or a struct in `structs`). A `footer:` block
    /// needs the same two.
    static func rowProblems(inListBlock block: ClosedRange<Int>, of lines: [String],
                            structs: [String: [String]] = [:]) -> [RowFinding] {
        let check = { (chain: [String], unit: [String], label: String) in
            gutterProblem(chain: chain, unit: unit, in: lines, structs: structs, label: label)
        }
        var findings: [RowFinding] = []
        var unitStart = block.lowerBound + 1
        var index = block.lowerBound + 1
        while index < block.upperBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { index += 1; continue }
            if lines[index].contains("GLInListSearchHeader(") {
                unitStart = index + 1
            } else if stripped(lines[index]).contains("footer:"),
                      let end = closingLine(ofFooterOpenedAt: index, in: lines) {
                let footer = Array(lines[index...end])
                findings.append(RowFinding(line: index, what: check(footer, footer, "footer")))
                unitStart = end + 1
                index = end + 1
                continue
            } else if trimmed.hasPrefix(".") && trimmed.contains(".listRowBackground(") {
                var chainStart = index
                while chainStart > unitStart, lines[chainStart - 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                    chainStart -= 1
                }
                var chainEnd = index
                while chainEnd + 1 < block.upperBound,
                      lines[chainEnd + 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                    chainEnd += 1
                }
                let unit = Array(lines[unitStart...chainEnd])
                if !unit.contains(where: { $0.contains("ContentUnavailableView") }) {
                    let chain = Array(lines[chainStart...chainEnd])
                    findings.append(RowFinding(line: chainStart, what: check(chain, unit, "row")))
                }
                unitStart = chainEnd + 1
                index = chainEnd + 1
                continue
            }
            index += 1
        }
        return findings
    }

    private static func gutterProblem(chain: [String], unit: [String], in lines: [String],
                                      structs: [String: [String]], label: String) -> String? {
        let zeroInsets = chain.contains { $0.contains(".listRowInsets(EdgeInsets())") }
        let guttered = carriesGutter(unit, in: lines, structs: structs, depth: 3)
        switch (zeroInsets, guttered) {
        case (true, true): return nil
        case (false, _): return "\(label) keeps the system inset: add .listRowInsets(EdgeInsets())"
        case (true, false): return "\(label) at zero insets with no gutter: pad it by GLLayout.rowCardInset"
        }
    }

    /// The line closing the `footer: {` block that starts on `line` (`} footer: {` closes the
    /// section body first, so counting starts after `footer:`).
    private static func closingLine(ofFooterOpenedAt line: Int, in lines: [String]) -> Int? {
        var depth = 0
        var opened = false
        for index in line..<lines.count {
            var text = stripped(lines[index])
            if index == line, let range = text.range(of: "footer:") { text = String(text[range.upperBound...]) }
            for char in text where char == "{" || char == "}" {
                if char == "{" { depth += 1; opened = true } else { depth -= 1 }
                if opened && depth == 0 { return index }
            }
        }
        return nil
    }

    /// Whether the lines pad by `GLLayout.rowCardInset` themselves, or call something that does:
    /// a function declared in the same file, or a `struct` declared in any app file (a
    /// shared row card such as `PersonRowCard`), followed `depth` calls deep.
    private static func carriesGutter(_ unit: [String], in lines: [String], structs: [String: [String]], depth: Int) -> Bool {
        if unit.contains(where: { $0.contains("GLLayout.rowCardInset") }) { return true }
        guard depth > 0 else { return false }
        for name in calledNames(in: unit) {
            let body: [String]
            if name.first?.isUppercase == true {
                body = structs[name] ?? []
            } else {
                body = declaration(of: "func", name, in: lines)
            }
            if !body.isEmpty, carriesGutter(Array(body.dropFirst()), in: lines, structs: structs, depth: depth - 1) {
                return true
            }
        }
        return false
    }

    /// Every `struct Name` declared in the files, by name, with its lines.
    static func viewStructs(in files: [[String]]) -> [String: [String]] {
        var structs: [String: [String]] = [:]
        for lines in files {
            for (index, line) in lines.enumerated() {
                guard let match = stripped(line).firstMatch(of: #/\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)/#),
                      let end = closingLine(ofBlockOpenedAt: index, in: lines) else { continue }
                structs[String(match.1)] = Array(lines[index...end])
            }
        }
        return structs
    }

    /// Names called as `name(` or `Name(` in the unit.
    private static func calledNames(in unit: [String]) -> Set<String> {
        var names = Set<String>()
        for line in unit {
            for match in stripped(line).matches(of: #/(?:^|[^A-Za-z0-9_.])([A-Za-z][A-Za-z0-9_]*)\(/#) {
                names.insert(String(match.1))
            }
        }
        return names
    }

    /// The lines of `func name(` in `lines` (empty when it is not declared there).
    private static func declaration(of keyword: String, _ name: String, in lines: [String]) -> [String] {
        let pattern = #"\bfunc\s+\#(name)\s*\("#
        guard let start = lines.firstIndex(where: {
            stripped($0).range(of: pattern, options: .regularExpression) != nil
        }), let end = closingLine(ofBlockOpenedAt: start, in: lines) else { return [] }
        return Array(lines[start...end])
    }

    /// The modifiers on the List enclosing the row on line `row` (a `.modifier(Name())` declared
    /// in the same file contributes its body's lines), or nil when no enclosing `List` is found.
    /// Shared with SearchKeyboardDismissTests, so both scans read a List the same way.
    static func listModifiers(forRowAt row: Int, in lines: [String]) -> [String]? {
        guard let opener = enclosingListLine(above: row, in: lines),
              let closer = closingLine(ofBlockOpenedAt: opener, in: lines) else { return nil }
        var chain = modifierChain(after: closer, in: lines)
        for line in chain {
            if let name = modifierTypeName(line) { chain += body(ofType: name, in: lines) }
        }
        return chain
    }

    /// Walks up from the row, block by block, to the innermost open block that is a `List`.
    private static func enclosingListLine(above row: Int, in lines: [String]) -> Int? {
        var depth = 0
        var index = row - 1
        while index >= 0 {
            for char in braces(in: lines[index]).reversed() {
                depth += char == "}" ? 1 : -1
                if depth < 0 { break }
            }
            if depth < 0 {
                if isListOpener(lines[index]) { return index }
                depth = 0
            }
            index -= 1
        }
        return nil
    }

    private static func isListOpener(_ line: String) -> Bool {
        stripped(line).range(of: #"(^|[^A-Za-z0-9_.])List\s*[\{\(]"#, options: .regularExpression) != nil
    }

    /// The line holding the brace that closes the block opened on `opener`.
    private static func closingLine(ofBlockOpenedAt opener: Int, in lines: [String]) -> Int? {
        var depth = 0
        var opened = false
        for index in opener..<lines.count {
            for char in braces(in: lines[index]) {
                if char == "{" { depth += 1; opened = true } else { depth -= 1 }
                if opened && depth == 0 { return index }
            }
        }
        return nil
    }

    /// The top-level modifier lines chained after a closing brace (`.listStyle(.plain)`,
    /// `.modifier(…)`, …), skipping the bodies of modifiers that take a closure.
    /// A modifier whose arguments wrap onto more lines (`.swipeDeleteConfirmation($x, title: …,`
    /// then `message: …) {`) is followed through its open parentheses, so the chain doesn't stop
    /// at the wrapped line.
    private static func modifierChain(after closer: Int, in lines: [String]) -> [String] {
        var chain: [String] = []
        var depth = 0
        var parens = 0
        var index = closer + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if depth == 0 && parens == 0 {
                if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
                    index += 1
                    continue
                }
                guard trimmed.hasPrefix(".") else { break }
                chain.append(trimmed)
            }
            for char in stripped(lines[index]) {
                switch char {
                case "{": depth += 1
                case "}": depth -= 1
                case "(": parens += 1
                case ")": parens -= 1
                default: break
                }
            }
            if depth < 0 || parens < 0 { break }
            index += 1
        }
        return chain
    }

    /// `Chrome` from `.modifier(Chrome())` or `.modifier(Chrome(showsMonogram: false))`.
    private static func modifierTypeName(_ modifierLine: String) -> String? {
        guard let match = modifierLine.firstMatch(of: #/^\.modifier\(([A-Za-z_][A-Za-z0-9_]*)\(/#) else { return nil }
        return String(match.1)
    }

    /// The lines of `struct name` in the same file (empty when it is declared elsewhere).
    private static func body(ofType name: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: {
            stripped($0).range(of: #"\bstruct\s+\#(name)\b"#, options: .regularExpression) != nil
        }), let end = closingLine(ofBlockOpenedAt: start, in: lines) else { return [] }
        return Array(lines[start...end])
    }

    /// The braces on a line outside string literals and `//` comments.
    private static func braces(in line: String) -> [Character] {
        stripped(line).filter { $0 == "{" || $0 == "}" }
    }

    private static func stripped(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character = " "
        for char in line {
            if !inString && char == "/" && previous == "/" {
                out.removeLast()
                break
            }
            if char == "\"" && previous != "\\" {
                inString.toggle()
                previous = char
                continue
            }
            if !inString { out.append(char) }
            previous = char
        }
        return out
    }
}
