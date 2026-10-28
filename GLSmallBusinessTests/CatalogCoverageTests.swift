//
//  CatalogCoverageTests.swift
//  GLSmallBusinessTests
//
//  QA audit 2026-10-03 F42: strings drawn on screen with no catalog entry read English in
//  Español. This sweeps every screen's source for literals handed to the calls that draw
//  or announce text, and fails when one has no Spanish value in the string catalog.
//

import Testing
import Foundation

struct CatalogCoverageTests {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness")

    private static func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("Localizable.xcstrings"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["strings"] as? [String: [String: Any]])
    }

    private static func hasSpanish(_ entry: [String: Any]) -> Bool {
        guard let es = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any] else { return false }
        if let unit = es["stringUnit"] as? [String: Any], let value = unit["value"] as? String, !value.isEmpty { return true }
        return es["variations"] != nil
    }

    /// The calls whose first string argument is drawn or announced as written.
    private static let callPattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:Text|Label|Button|Toggle|TextField|Section|navigationTitle|alert|Picker|Menu|NavigationLink|LabeledContent|ContentUnavailableView|accessibilityLabel|accessibilityHint)|\b[a-z]{0,2}[lL]oc|LocalizedStringKey)\(\s*"((?:[^"\\]|\\.)*)""#)

    /// Turns `\(anything, even nested)` into `%@`, the key shape the compiler records.
    private static func formatKey(_ literal: String, _ spec: String) -> String? {
        var out = "", chars = Array(literal), i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                var depth = 0, j = i + 1
                while j < chars.count {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                guard j < chars.count else { return nil }
                out += spec
                i = j + 1
            } else if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out += "\n"; i += 2
                case "t": out += "\t"; i += 2
                case "u" where i + 2 < chars.count && chars[i + 2] == "{":
                    var j = i + 3, hex = ""
                    while j < chars.count, chars[j] != "}" { hex.append(chars[j]); j += 1 }
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                    i = j + 1
                default: out.append(chars[i + 1]); i += 2
                }
            } else { out.append(chars[i]); i += 1 }
        }
        return out
    }

    private static func sources() -> [URL] {
        let folders = ["Screens", "UIComponents"]
        return folders.flatMap { folder -> [URL] in
            let dir = appRoot.appendingPathComponent(folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "swift" }
        }.sorted { $0.path < $1.path }
    }

    /// Words a person can read: at least one letter. Symbols, numbers and "—" are not catalog text.
    private static func isReadable(_ text: String) -> Bool { text.contains { $0.isLetter } }

    @Test func everySweptLiteralHasEnglishAndSpanish() throws {
        let strings = try Self.catalog()
        var missing: [String] = []
        for file in Self.sources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("verbatim:") || line.contains("systemImage") && !line.contains("Label(") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in Self.callPattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let literal = String(line[r])
                    let keys = literal.contains("\\(")
                        ? ["%@", "%lld", "%d", "%lf"].compactMap { Self.formatKey(literal, $0) }
                        : [Self.formatKey(literal, "%@") ?? literal]
                    guard let first = keys.first, Self.isReadable(first) else { continue }
                    if let hit = keys.first(where: { strings[$0] != nil }) {
                        if !Self.hasSpanish(strings[hit] ?? [:]) { missing.append("no Spanish: \(hit) (\(file.lastPathComponent))") }
                    } else {
                        missing.append("not in catalog: \(first) (\(file.lastPathComponent))")
                    }
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) strings read English in Español:\n\(missing.sorted().joined(separator: "\n"))")
    }

    /// The Price Sheet item form, the Menu sign-out alert and the Catalog row read in Español.
    @Test func theAuditedScreensHaveSpanishValues() throws {
        let strings = try Self.catalog()
        let keys = ["Item Details", "Service or item name", "Category (e.g. Tile, Prep, Plumbing)",
                    "Scope of work / description (optional)", "Pricing & Measurement", "Unit of measure",
                    "Tax & Classification", "Line Discount (Optional)", "Discount type", "Preview Calculation",
                    "Line Total", "Catalog & Pricing", "Options", "Change Status", "From Price Sheet",
                    "Add First Item", "Change Order %@", "%@ · From %@", "Exit Sample Mode",
                    "Are you sure you want to sign out?", "Sign out",
                    "Sample data is discarded when you exit. You can explore it again anytime."]
        for key in keys {
            let entry = try #require(strings[key], "missing key: \(key)")
            #expect(Self.hasSpanish(entry), "no Spanish for: \(key)")
        }
    }

    /// Law 87: a quoted job is a "presupuesto", never a "cotización".
    @Test func spanishSaysPresupuestoNeverCotizacion() throws {
        let strings = try Self.catalog()
        for (key, entry) in strings {
            let es = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = (es?["value"] as? String) ?? ""
            #expect(!value.localizedCaseInsensitiveContains("cotizaci"), "\(key) → \(value)")
        }
    }

    /// A String parameter drawn with `Text(x)` shows the text as written, never translated.
    @Test func noScreenDrawsALiteralThroughAVerbatimStringParameter() throws {
        var hits: [String] = []
        let declaration = try NSRegularExpression(pattern: #"func (\w+)\((?:_ )?(\w+)?:? ?(?:_ )?(\w+): String\b"#)
        for file in Self.sources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in declaration.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source),
                      let paramRange = Range(match.range(at: 3), in: source) else { continue }
                let name = String(source[nameRange]), param = String(source[paramRange])
                guard source.contains("Text(\(param))") else { continue }
                if source.contains("\(name)(\"") || source.contains("\(name)(title: \"") || source.contains("\(name)(label: \"") {
                    hits.append("\(file.lastPathComponent): \(name)(\(param): String)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits.joined(separator: "\n"))")
    }
}
