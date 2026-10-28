//
//  WebAddressTests.swift
//  GLSmallBusinessTests
//
//  No app source force-unwraps an address it builds (anti-crash mandate): `URL(string: …)!`
//  traps the whole app the day its text stops being an address. Found 2026-09-27 and fixed: the
//  paywall's two unused policy addresses (removed — its policy links open the in-app sheets), the
//  "More from Gold Life" catalog address (optional; without it the carousel keeps the bundled
//  lineup) and the backup Worker's address (optional; without it a call fails as `.offline`, the
//  backup's ordinary "can't reach it right now").
//

import Testing
import Foundation
import GoldLifeUI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct WebAddressTests {

    /// The App Store lookup address is optional, never force-unwrapped (anti-crash mandate).
    @Test func theAppCatalogAddressIsNotForceUnwrapped() {
        #expect(GLAppCatalog.lookupURL(appStoreIDs: ["6778954606"])?.absoluteString.contains("itunes.apple.com/lookup") == true)
    }

    /// The backup Worker's address is optional, never force-unwrapped; every call reads it through
    /// a `guard` that fails as `.offline` instead of trapping.
    @Test func theBackupAddressIsNotForceUnwrapped() throws {
        #expect(GLSyncTransport.baseURL?.absoluteString == "https://backend.softwarebygl.com/cloud")
        // Code only (comments stripped, audit 2026-10-03 F11): a comment quoting the guard is not the guard.
        let transport = try #require(GLSource.code("Sync/GLSyncTransport.swift"))
        #expect(transport.contains("guard let baseURL = Self.baseURL else { throw GLSyncTransportError.offline }"))
    }

    /// No app source force-unwraps an address it builds (`URL(…)!`, `URLComponents(…)!` or
    /// `…?.url!`, `URLRequest(…)!`). The scan reads each file the way the compiler does
    /// (`AddressScan`), so an address built by interpolation or written over several lines is
    /// caught too. App sources only: the test target has bare regex literals the scan can't read,
    /// and a test that traps fails a test, not a customer. LocalSecrets.swift is skipped: it is
    /// git-ignored, kept by hand on the owner's machine, and not this repo's to change.
    @Test func noAppSourceForceUnwrapsAnAddress() {
        var offenders: [String] = []
        var unread: [String] = []
        let sources = GLSource.files(excluding: ["Services/LocalSecrets.swift"])
        for file in sources {
            if !AddressScan.read(file.text).isWhole { unread.append(file.path) }
            offenders += AddressScan.forceUnwrappedAddressLines(in: file.text).map { "\(file.path):\($0)" }
        }
        #expect(sources.count > 50, "the scan has to actually see the app's sources")
        #expect(unread.isEmpty, "the scan lost its place in these files (syntax it can't read yet, such as a regex literal with a lone parenthesis); teach AddressScan.read before trusting it: \(unread)")
        #expect(offenders.isEmpty, "a force-unwrapped address (anti-crash mandate): \(offenders)")
    }

    /// The scan above can't quietly stop working: it catches the force-unwraps this repo actually
    /// had (the paywall's, the catalog's and the Worker's literal addresses) and the other shapes of
    /// the bug, passes safe code and the bug quoted in comments or text, and says so when it can't
    /// read a file.
    @Test func theAddressScanCatchesEveryShapeOfTheBug() {
        let mustFlag = [
            #"private let privacyURL = URL(string: "https://apps.softwarebygl.com/my-business/privacy")!"#,
            #"static let catalogURL = URL(string: "https://apps.softwarebygl.com/apps.json")!"#,
            #"static let baseURL = URL(string: "https://backend.softwarebygl.com/cloud")!"#,
            #"let u = URL(string: "https://\(website)")!"#,
            "let u = URL(\n    string: \"https://a.com\"\n)!",
            #"let u = URL(string: "https://a.com/:)")!"#,
            ##"let u = URL(string: #"https://a.com/\#(path)"#)!"##,
            "let u = URL(string: \"\"\"\n    https://a.com/)\n    \"\"\")!",
            #"let u = URLComponents(string: base)?.url!"#,
            #"let u = URLComponents(string: base)!.url"#,
            #"let u = URL.init(string: s)!"#,
            #"let t = "\(URL(string: s)!)""#,
            #"let r = URLRequest(url: URL(string: "https://a.com/\(id)")!)"#,
        ]
        let mustPass = [
            #"let u = URL(string: "https://a.com")"#,
            #"let u = URL(string: s) ?? fallback"#,
            #"if URL(string: s) != nil {}"#,
            #"// URL(string: "x")!"#,
            #"/* URL(string: "x")! */"#,
            #"/* a /* b */ URL(string: "x")! */"#,
            #"let t = "URL(string: x)! is how it crashes""#,
            #"let t = "a \"URL(string: x)!\" b""#,
            ##"let r = #"URL\(string: "x"\)!"#"##,
            #"let t = "\\"; let u = URL(string: t)"#,
            #"guard let baseURL = Self.baseURL else { throw GLSyncTransportError.offline }"#,
        ]
        for sample in mustFlag {
            #expect(AddressScan.forceUnwrappedAddressLines(in: sample) == [1], "missed: \(sample)")
        }
        for sample in mustPass {
            #expect(AddressScan.forceUnwrappedAddressLines(in: sample).isEmpty, "flagged safe code: \(sample)")
            #expect(AddressScan.read(sample).isWhole, "lost its place in: \(sample)")
        }
        // All in one file: nothing a comment, string or raw string opens leaks past it, and each
        // finding names the line its address starts on.
        let lineCount: (String) -> Int = { $0.components(separatedBy: "\n").count }
        var expected: [Int] = []
        var line = mustPass.map(lineCount).reduce(1, +)
        for sample in mustFlag { expected.append(line); line += lineCount(sample) }
        let file = (mustPass + mustFlag).joined(separator: "\n")
        #expect(AddressScan.forceUnwrappedAddressLines(in: file) == expected)
        #expect(AddressScan.read(file).isWhole)
        // Syntax it can't read is reported, not silently misread.
        #expect(!AddressScan.read(#"let r = /\(/"#).isWhole)
        #expect(!AddressScan.read(#"let t = "never closed"#).isWhole)
    }
}

/// Finds where Swift source force-unwraps an address it builds. A per-line pattern can't: the `)`
/// of an interpolation such as `"\(base)"` ends a `[^)]*` match early, and a call can span lines.
/// So this blanks comments and string text (keeping the code inside each `\(…)`), then walks from
/// each `URL(`, `URLComponents(` or `URLRequest(` to its matching `)` by depth and looks at what
/// follows it.
private nonisolated enum AddressScan {

    /// The line each flagged call starts on.
    static func forceUnwrappedAddressLines(in source: String) -> [Int] {
        let code = read(source).code
        func at(_ i: Int) -> Unicode.Scalar? { i >= 0 && i < code.count ? code[i] : nil }
        func isName(_ c: Unicode.Scalar?) -> Bool {
            guard let c else { return false }
            return c == "_" || CharacterSet.alphanumerics.contains(c)
        }
        func starts(_ word: String, at i: Int) -> Bool {
            word.unicodeScalars.enumerated().allSatisfy { at(i + $0.offset) == $0.element }
        }
        // `!` right after the call, never the `!=` of a comparison.
        func bang(at i: Int) -> Bool { at(i) == "!" && at(i + 1) != "=" }

        var lines: [Int] = []
        var line = 1
        var i = 0
        while i < code.count {
            if code[i] == "\n" { line += 1; i += 1; continue }
            guard isName(code[i]), !isName(at(i - 1)) else { i += 1; continue }
            var end = i
            while isName(at(end)) { end += 1 }
            let name = String(String.UnicodeScalarView(code[i..<end]))
            i = end
            guard ["URL", "URLComponents", "URLRequest"].contains(name) else { continue }
            var open = end
            if starts(".init", at: open), !isName(at(open + 5)) { open += 5 }
            while at(open) == " " || at(open) == "\t" { open += 1 }
            guard at(open) == "(" else { continue }
            var depth = 0
            var close = open
            while close < code.count {
                if code[close] == "(" { depth += 1 }
                if code[close] == ")" { depth -= 1; if depth == 0 { break } }
                close += 1
            }
            guard depth == 0 else { continue }
            var after = close + 1
            if at(after) == "?" { after += 1 }
            if bang(at: after) || (starts(".url", at: after) && bang(at: after + 4)) {
                lines.append(line)
            }
        }
        return lines
    }

    /// The source with comments and string text blanked (line breaks kept) and the code inside
    /// each `\(…)` kept with its parentheses. `isWhole` is false when the walk loses its place: a
    /// string or comment left open, or parentheses or braces that don't pair.
    static func read(_ source: String) -> (code: [Unicode.Scalar], isWhole: Bool) {
        enum Frame { case code(depth: Int, interpolation: Bool), text(hashes: Int, multiline: Bool) }
        let s = Array(source.unicodeScalars)
        var out = s
        var stack: [Frame] = [.code(depth: 0, interpolation: false)]
        var commentOpen = false
        func at(_ i: Int) -> Unicode.Scalar? { i >= 0 && i < s.count ? s[i] : nil }
        func blank(_ i: Int) { if i < s.count, s[i] != "\n" { out[i] = " " } }
        func hashes(from i: Int) -> Int { var n = 0; while at(i + n) == "#" { n += 1 }; return n }
        var i = 0
        while i < s.count, let frame = stack.last {
            switch frame {
            case .code(let depth, let interpolation):
                if at(i) == "/", at(i + 1) == "/" {
                    while i < s.count, s[i] != "\n" { blank(i); i += 1 }
                } else if at(i) == "/", at(i + 1) == "*" {
                    // Block comments nest in Swift.
                    var nesting = 0
                    repeat {
                        if at(i) == "/", at(i + 1) == "*" { nesting += 1; blank(i); blank(i + 1); i += 2 }
                        else if at(i) == "*", at(i + 1) == "/" { nesting -= 1; blank(i); blank(i + 1); i += 2 }
                        else { blank(i); i += 1 }
                    } while nesting > 0 && i < s.count
                    commentOpen = nesting > 0
                } else if at(i) == "#" || at(i) == "\"", at(i + hashes(from: i)) == "\"" {
                    // A string opens: `"`, `"""`, or raw `#"` / `#"""` with any number of `#`.
                    let n = hashes(from: i)
                    let multiline = at(i + n + 1) == "\"" && at(i + n + 2) == "\""
                    let width = n + (multiline ? 3 : 1)
                    for k in i..<(i + width) { blank(k) }
                    i += width
                    stack.append(.text(hashes: n, multiline: multiline))
                } else if at(i) == "(", interpolation {
                    stack[stack.count - 1] = .code(depth: depth + 1, interpolation: true)
                    i += 1
                } else if at(i) == ")", interpolation {
                    // The `)` that closes `\(` returns to the string's text.
                    if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .code(depth: depth - 1, interpolation: true) }
                    i += 1
                } else {
                    i += 1
                }
            case .text(let n, let multiline):
                if at(i) == "\\", hashes(from: i + 1) >= n {
                    // `\(` (`\#(` in a `#"` string) opens code; any other `\` escapes one character.
                    let next = i + 1 + n
                    if at(next) == "(" {
                        for k in i..<next { blank(k) }
                        stack.append(.code(depth: 0, interpolation: true))
                    } else {
                        for k in i...next { blank(k) }
                    }
                    i = next + 1
                } else if at(i) == "\"", !multiline || (at(i + 1) == "\"" && at(i + 2) == "\""),
                          hashes(from: i + (multiline ? 3 : 1)) >= n {
                    let width = (multiline ? 3 : 1) + n
                    for k in i..<(i + width) { blank(k) }
                    i += width
                    stack.removeLast()
                } else {
                    blank(i)
                    i += 1
                }
            }
        }
        let count: (Unicode.Scalar) -> Int = { c in out.reduce(0) { $0 + ($1 == c ? 1 : 0) } }
        let isWhole = stack.count == 1 && !commentOpen
            && count("(") == count(")") && count("{") == count("}")
        return (out, isWhole)
    }
}
