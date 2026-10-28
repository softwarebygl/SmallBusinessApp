//
//  SourceScan.swift
//  GLSmallBusinessTests — Harness
//
//  Reads the app's own sources off disk, for the tests that pin a fact about CALL SITES
//  ("every delete routes through the sync queue", "every exit from a session stops the
//  engine", "only three surfaces prompt for Face ID"). Those are facts about where a
//  function is called from, not about a value it returns — the defects they guard were
//  all *missing calls*, which no amount of unit-testing the callee can catch. A scan is
//  the honest instrument, not a substitute for one.
//
//  `#filePath` is this file inside `<repo>/GLSmallBusinessTests/Harness/`, so the repo is
//  three levels up and the app target sits beside the test target.
//

import Testing
import Foundation

enum GLSource {

    /// `<repo>` — the folder holding GLSmallBusiness.xcodeproj.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/GLSmallBusinessTests/Harness/SourceScan.swift
            .deletingLastPathComponent()     // …/GLSmallBusinessTests/Harness
            .deletingLastPathComponent()     // …/GLSmallBusinessTests
            .deletingLastPathComponent()     // …/SmallBusinessApp
    }

    /// `<repo>/GLSmallBusiness` — the app target.
    static var appRoot: URL {
        repoRoot.appendingPathComponent("GLSmallBusiness")
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var rawFilesCache: [String: [(path: String, text: String)]] = [:]
    nonisolated(unsafe) private static var codeFilesCache: [String: [(path: String, text: String)]] = [:]

    /// Every `.<ext>` file under `root`, as (root-relative path, contents), sorted by path so
    /// a scan's output is stable run to run. `excluding` lists root-relative PREFIXES to skip:
    /// a folder (`"Sync/"`) or one file (`"AccessControl/DemoMode.swift"`).
    static func files(under root: URL = appRoot,
                      ext: String = "swift",
                      excluding: [String] = []) -> [(path: String, text: String)] {
        let key = "\(root.path)|\(ext)"
        cacheLock.lock()
        let cached = rawFilesCache[key]
        cacheLock.unlock()

        let all: [(path: String, text: String)]
        if let cached {
            all = cached
        } else {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { return [] }
            var out: [(path: String, text: String)] = []
            for case let url as URL in walker where url.pathExtension == ext {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append((relative, text))
            }
            all = out.sorted { $0.path < $1.path }
            cacheLock.lock()
            rawFilesCache[key] = all
            cacheLock.unlock()
        }

        if excluding.isEmpty { return all }
        return all.filter { item in !excluding.contains(where: { item.path.hasPrefix($0) }) }
    }

    /// Every `.swift` under the app target, minus one folder. The original scanner's shape,
    /// kept so its callers read the same. (No default on the argument: with one, a bare
    /// `files()` would be ambiguous with the walk above.)
    static func files(excludingDirectory excluded: String?) -> [(path: String, text: String)] {
        files(excluding: excluded.map { [$0] } ?? [])
    }

    /// One file by root-relative path (app target by default); nil when it is not there.
    static func file(_ relativePath: String, under root: URL = appRoot) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Code only (comments stripped)

    /// `files(under:ext:excluding:)` with every comment taken out of each file. A scan that
    /// asks "does the code do X?" reads THIS, never the raw text: a comment that names the
    /// fixed pattern (or the banned one) is not code, and a raw scan passed on one (F11,
    /// 2026-10-03 audit). Line breaks are kept, so a line number in a scan's message is
    /// still the line in the file.
    static func codeFiles(under root: URL = appRoot,
                          ext: String = "swift",
                          excluding: [String] = []) -> [(path: String, text: String)] {
        let key = "\(root.path)|\(ext)"
        cacheLock.lock()
        let cached = codeFilesCache[key]
        cacheLock.unlock()

        let all: [(path: String, text: String)]
        if let cached {
            all = cached
        } else {
            all = files(under: root, ext: ext, excluding: []).map { ($0.path, strippingComments($0.text)) }
            cacheLock.lock()
            codeFilesCache[key] = all
            cacheLock.unlock()
        }

        if excluding.isEmpty { return all }
        return all.filter { item in !excluding.contains(where: { item.path.hasPrefix($0) }) }
    }

    /// `file(_:under:)` with its comments stripped; nil when the file is not there.
    static func code(_ relativePath: String, under root: URL = appRoot) -> String? {
        if relativePath.hasSuffix(".swift") {
            let all = codeFiles(under: root, ext: "swift")
            if let hit = all.first(where: { $0.path == relativePath }) {
                return hit.text
            }
        }
        return file(relativePath, under: root).map { strippingComments($0) }
    }

    /// Swift source with every `//` and `/* */` comment removed (block comments nest, as in
    /// Swift). String literals are kept whole, so `"https://…"` or a `"/*"` inside a string
    /// is not mistaken for a comment: plain, multi-line (`"""`) and raw (`#"…"#`) strings,
    /// with escapes and `\( )` interpolation (whose code can hold strings of its own).
    /// Every newline is kept, comment or not, so line numbers do not move.
    static func strippingComments(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        // Code frames count open parentheses, so the `)` that closes an interpolation is told
        // apart from one inside it; string frames carry their delimiter.
        enum Frame { case code(parens: Int), string(multiline: Bool, hashes: Int) }
        var stack: [Frame] = [.code(parens: 0)]
        var i = 0
        func at(_ k: Int) -> Unicode.Scalar? { k < s.count ? s[k] : nil }
        func hashes(from k: Int) -> Int { var n = 0; while at(k + n) == "#" { n += 1 }; return n }
        func emit(_ from: Int, _ count: Int) { for k in from..<min(from + count, s.count) { out.append(s[k]) } }

        while i < s.count {
            let c = s[i]
            switch stack.last ?? .code(parens: 0) {
            case .code(let parens):
                if c == "/", at(i + 1) == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }          // the newline itself stays
                } else if c == "/", at(i + 1) == "*" {
                    var depth = 0
                    while i < s.count {
                        if s[i] == "/", at(i + 1) == "*" { depth += 1; i += 2; continue }
                        if s[i] == "*", at(i + 1) == "/" { depth -= 1; i += 2; if depth == 0 { break }; continue }
                        if s[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                } else if c == "#" || c == "\"" {
                    let n = c == "#" ? hashes(from: i) : 0
                    guard at(i + n) == "\"" else { emit(i, max(n, 1)); i += max(n, 1); continue }   // #if, #expect…
                    let multiline = at(i + n + 1) == "\"" && at(i + n + 2) == "\""
                    let open = n + (multiline ? 3 : 1)
                    emit(i, open); i += open
                    stack.append(.string(multiline: multiline, hashes: n))
                } else if c == "(" {
                    stack[stack.count - 1] = .code(parens: parens + 1)
                    emit(i, 1); i += 1
                } else if c == ")" {
                    if parens == 0, stack.count > 1 { stack.removeLast() }       // the interpolation ends
                    else { stack[stack.count - 1] = .code(parens: max(0, parens - 1)) }
                    emit(i, 1); i += 1
                } else {
                    emit(i, 1); i += 1
                }
            case .string(let multiline, let n):
                if c == "\\", hashes(from: i + 1) >= n {
                    let after = i + 1 + n
                    if at(after) == "(" {                                       // \( … ) interpolation
                        emit(i, n + 2); i = after + 1
                        stack.append(.code(parens: 0))
                    } else if n == 0 {                                          // an escape: \" \\ \n
                        emit(i, 2); i += 2
                    } else {
                        emit(i, 1); i += 1
                    }
                } else if c == "\"" {
                    let quotes = multiline ? 3 : 1
                    let closes = (0..<quotes).allSatisfy { at(i + $0) == "\"" } && hashes(from: i + quotes) >= n
                    if closes {
                        emit(i, quotes + n); i += quotes + n
                        stack.removeLast()
                    } else {
                        emit(i, 1); i += 1
                    }
                } else {
                    emit(i, 1); i += 1
                }
            }
        }
        return String(out)
    }

    /// What sits between the bracket that opens at or after `from` and its balancing close
    /// (`(`/`)` or `{`/`}`), plus the index just past that close; nil when none opens or it
    /// never balances. Run it on `strippingComments` output, where a bracket inside a comment
    /// can no longer throw the count.
    static func balanced(_ open: Character, _ close: Character,
                         from: String.Index, in text: String) -> (inner: String, end: String.Index)? {
        guard let start = text[from...].firstIndex(of: open) else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 {
                    return (String(text[text.index(after: start)..<index]), text.index(after: index))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The 1-based line `index` sits on, for a scan's failure message.
    static func line(of index: String.Index, in text: String) -> Int {
        text[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The body of `func <name>` in `text`, by brace balance from its opening `{`.
    static func functionBody(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        guard let open = text.range(of: "{", range: start.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open.upperBound..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// The scanner's original name — GLSyncHardeningTests grew it first. Same type.
typealias GLSyncSource = GLSource

// MARK: - The scanner has to be trustworthy before a scan can prove anything

/// A scan that reads nothing, or reads the wrong tree, passes for the wrong reason: zero
/// offenders in zero files. These pin the instrument itself, so every scan built on it
/// inherits a real denominator.
struct GLSourceSelfTests {

    /// Three levels up from this file IS the repo — the folder holding the project — and
    /// the app target sits beside the test target. Moving this file without updating the
    /// path walk would silently point every scan at nothing.
    @Test func rootsResolveToTheRepoAndTheAppTarget() {
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: GLSource.repoRoot.appendingPathComponent("GLSmallBusiness.xcodeproj").path),
                "repoRoot is not the folder holding the Xcode project: \(GLSource.repoRoot.path)")
        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: GLSource.appRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "appRoot is not a directory: \(GLSource.appRoot.path)")
        #expect(GLSource.appRoot.lastPathComponent == "GLSmallBusiness")
    }

    /// The default walk reads the whole app target: a real number of Swift files, every path
    /// relative to the app root, every file non-empty, no duplicates, sorted.
    @Test func filesReadsTheWholeAppTargetDeterministically() {
        let scanned = GLSource.files()
        #expect(scanned.count > 50, "the app sources were not readable — \(scanned.count) file(s)")
        #expect(scanned.allSatisfy { $0.path.hasSuffix(".swift") })
        #expect(scanned.allSatisfy { !$0.path.hasPrefix("/") }, "paths must be root-relative")
        #expect(scanned.allSatisfy { !$0.text.isEmpty })
        #expect(Set(scanned.map(\.path)).count == scanned.count, "a file was read twice")
        #expect(scanned.map(\.path) == scanned.map(\.path).sorted(), "output is not in path order")
        #expect(scanned.contains { $0.path == "Models/Customer.swift" })
    }

    /// `excluding` drops exactly the files under the prefix — no more, no fewer — and the
    /// original `excludingDirectory:` shape does the same thing.
    @Test func excludingDropsExactlyThePrefixedFiles() {
        let all = GLSource.files()
        let syncFiles = all.filter { $0.path.hasPrefix("Sync/") }
        #expect(!syncFiles.isEmpty, "the Sync/ folder has moved — this exclusion test proves nothing")

        let withoutSync = GLSource.files(excluding: ["Sync/"])
        #expect(withoutSync.count == all.count - syncFiles.count)
        #expect(!withoutSync.contains { $0.path.hasPrefix("Sync/") })

        let legacy = GLSource.files(excludingDirectory: "Sync/")
        #expect(legacy.map(\.path) == withoutSync.map(\.path))
        #expect(GLSource.files(excludingDirectory: nil).count == all.count)

        let oneFile = GLSource.files(excluding: ["Models/Customer.swift"])
        #expect(oneFile.count == all.count - 1)
        #expect(!oneFile.contains { $0.path == "Models/Customer.swift" })
    }

    /// `under:` and `ext:` re-aim the walk: the test target itself, and a non-Swift extension.
    @Test func filesCanWalkAnotherRootAndAnotherExtension() {
        let tests = GLSource.files(under: GLSource.repoRoot.appendingPathComponent("GLSmallBusinessTests"))
        #expect(tests.contains { $0.path == "Harness/SourceScan.swift" },
                "a walk of the test target did not find this very file")
        #expect(tests.allSatisfy { !$0.path.hasPrefix("/") })

        let strings = GLSource.files(ext: "xcstrings")
        #expect(strings.map(\.path) == ["InfoPlist.xcstrings", "Localizable.xcstrings"],
                "the app target's string catalogs were not the only .xcstrings found")
    }

    /// `file(_:)` reads one file relative to the app root and is nil — not empty — when it
    /// is missing, so a `#require` around it fails loudly instead of scanning "".
    @Test func fileReadsOneSourceOrReturnsNil() throws {
        let customer = try #require(GLSource.file("Models/Customer.swift"))
        #expect(customer.contains("final class Customer"))
        #expect(GLSource.file("Models/DoesNotExist.swift") == nil)
        let plan = try #require(GLSource.file("UnitTests.xctestplan", under: GLSource.repoRoot))
        #expect(!plan.isEmpty)
    }

    /// Brace balance, on a fixture that has every shape that could fool it: nested closures,
    /// a sibling function AFTER the target, and a name that is a prefix of another name.
    @Test func functionBodyIsBraceBalancedAndNameExact() throws {
        let fixture = """
        struct S {
            func signOutAll() { never() }
            func signOut() {
                let done = { [weak self] in
                    if let self { self.finish(); }
                }
                stopSync()
                done()
            }
            func stopSync() { engine.signedOut() }
        }
        """
        let body = try #require(GLSource.functionBody("signOut", in: fixture))
        #expect(body.contains("stopSync()"))
        #expect(body.contains("[weak self]"), "the nested closure was cut off")
        #expect(!body.contains("engine.signedOut()"), "the body ran into the NEXT function")
        #expect(!body.contains("never()"), "matched `signOutAll` instead of `signOut`")

        let teardown = try #require(GLSource.functionBody("stopSync", in: fixture))
        #expect(teardown.trimmingCharacters(in: .whitespaces) == "engine.signedOut()")

        #expect(GLSource.functionBody("missing", in: fixture) == nil)
        #expect(GLSource.functionBody("broken", in: "func broken() { if x {") == nil,
                "an unbalanced body must be nil, not a partial string")
    }

    /// The comment-stripped read: every comment shape goes, every string shape stays, and the
    /// line count does not move. Each case here is one that would fool a naive stripper — a
    /// URL's `//`, a `/*` inside a string, an interpolation holding its own quotes, a raw
    /// string with a bare `"` in it, a nested block comment.
    @Test func strippingCommentsRemovesCommentsAndKeepsStrings() {
        let fixture = #"""
        let url = "https://example.com/*not a comment*/" // trailing .onDelete
        /// a doc comment naming allowsFullSwipe: true
        /* outer /* nested */ still .onDelete */ let kept = 1
        let label = "\(isOn ? "a // b" : "c")" // gone
        let raw = #"a " quote // and /* this */ stay"#
        let multi = """
            // inside a multi-line string stays
            """
        #if DEBUG
        let escaped = "say \"hi\" // still a string" /* gone */
        #endif
        """#
        let code = GLSource.strippingComments(fixture)
        #expect(code.components(separatedBy: "\n").count == fixture.components(separatedBy: "\n").count,
                "a stripped comment moved the line numbers")
        #expect(!code.contains("trailing"))
        #expect(!code.contains("doc comment"))
        #expect(!code.contains(".onDelete"), "a comment's .onDelete survived the strip")
        #expect(!code.contains("allowsFullSwipe"), "a doc comment's code survived the strip")
        #expect(!code.contains("gone"))
        #expect(code.contains("let kept = 1"), "code after a nested block comment was eaten")
        #expect(code.contains(#""https://example.com/*not a comment*/""#), "a URL in a string was cut")
        #expect(code.contains(#""\(isOn ? "a // b" : "c")""#), "an interpolated string was cut")
        #expect(code.contains(##"#"a " quote // and /* this */ stay"#"##), "a raw string was cut")
        #expect(code.contains("// inside a multi-line string stays"), "a multi-line string was cut")
        #expect(code.contains(#""say \"hi\" // still a string""#), "an escaped quote ended the string early")
        #expect(code.contains("#if DEBUG") && code.contains("#endif"), "a # directive was mistaken for a raw string")
    }

    /// `codeFiles` is `files` with comments stripped, file for file; `code(_:)` is `file(_:)`.
    @Test func codeReadsAreTheStrippedFiles() throws {
        let raw = GLSource.files()
        let code = GLSource.codeFiles()
        #expect(code.map(\.path) == raw.map(\.path))
        #expect(zip(code, raw).allSatisfy { $0.text == GLSource.strippingComments($1.text) })
        let customer = try #require(GLSource.code("Models/Customer.swift"))
        #expect(customer == GLSource.strippingComments(try #require(GLSource.file("Models/Customer.swift"))))
        #expect(GLSource.code("Models/DoesNotExist.swift") == nil)
    }

    /// `balanced` returns the inside of the first bracket pair at or after `from`, nested
    /// pairs included, and nil when the pair never closes.
    @Test func balancedFindsTheMatchingBracket() throws {
        let text = "a.swipeActions(edge: .trailing, f(x)) { Button { go() } label: { L() } } tail"
        let args = try #require(GLSource.balanced("(", ")", from: text.startIndex, in: text))
        #expect(args.inner == "edge: .trailing, f(x)")
        let body = try #require(GLSource.balanced("{", "}", from: args.end, in: text))
        #expect(body.inner == " Button { go() } label: { L() } ")
        #expect(text[body.end...] == " tail")
        #expect(GLSource.balanced("{", "}", from: text.startIndex, in: "x { y") == nil)
        #expect(GLSource.line(of: try #require("a\nb\nc".firstIndex(of: "c")), in: "a\nb\nc") == 3)
    }

    /// The original name still names the same type, so a caller written against
    /// `GLSyncSource` reads the same tree.
    @Test func legacyNameIsTheSameScanner() {
        #expect(GLSyncSource.appRoot == GLSource.appRoot)
        #expect(GLSyncSource.files(excludingDirectory: "Sync/").count == GLSource.files(excluding: ["Sync/"]).count)
    }
}
