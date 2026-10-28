//
//  IdentitySourceTests.swift
//  GLSmallBusinessTests
//
//  Law 48 / 48a(4): the person's name, contact, photo and signature live only in the
//  Gold Life ID. `UserProfile` keeps its old identity columns in 3.3.0 (dropping them
//  needs a store migration), but nothing may read or write them except the one-release
//  upload into the Gold Life ID and the clean-up right after it (GLGoldLifeIDSync).
//  Audit 2026-10-03 F19 / F70.
//
//  The scan reads comment-stripped source (GLSource.codeFiles), so a comment that
//  names a field is never mistaken for code.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@Suite("Identity source")
@MainActor
struct IdentitySourceTests {

    /// The legacy identity columns and the helpers that used to read them.
    static let identityMembers = [
        "firstName", "lastName", "email", "phone", "photoData", "signatureData",
        "addressStreet1", "addressStreet2", "addressCity", "addressState", "addressPostalCode",
        "homeAddress", "fullName", "initials", "hasDetails", "hasSignature",
    ]

    /// Files allowed to touch the legacy columns, and why. A closed list (empty now that all
    /// legacy identity columns have been dropped from `UserProfile`).
    static let allowed: [String: String] = [:]

    /// Known readers still to fix. A countdown, not a waiver: once the file stops reading the
    /// columns, `quarantineIsStillNeeded` fails until its entry is removed.
    static let quarantine: [String: String] = [:]

    // MARK: - The scanner

    /// Names bound to a `UserProfile` (or an array / optional of them) in `code`.
    static func bindings(in code: String) -> Set<String> {
        var names: Set<String> = []
        func add(_ pattern: String, _ text: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { names.insert(String(text[r])) }
            }
        }
        // Typed: `let p: UserProfile`, `var rows: [UserProfile]`, `_ p: UserProfile?`.
        add(#"\b(\w+)\s*:\s*\[?\s*UserProfile\b"#, code)
        // `for p in …UserProfile…` loops.
        add(#"\bfor\s+(\w+)\s+in\s+[^\n{]*\bUserProfile\b"#, code)
        // `let x = …UserProfile…` (a fetch, a `UserProfile()`), one declaration at a time.
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: ",;"))
            for part in parts where part.contains("UserProfile") {
                add(#"\b(?:let|var)\s+(\w+)\b[^=]*="#, part)
            }
        }
        // Untyped closure parameters inside `entry(UserProfile.self, …)` (the sync registry).
        for region in registryRegions(in: code) {
            add(#"\{\s*(\w+)(?:\s*,\s*\w+)*\s+in\b"#, region)
        }
        names.remove("_")
        return names
    }

    /// The text of each `entry(UserProfile.self, …)` call, parentheses balanced.
    static func registryRegions(in code: String) -> [String] {
        var regions: [String] = []
        var search = code.startIndex
        while let start = code.range(of: "entry(UserProfile.self", range: search..<code.endIndex) {
            var depth = 0
            var end = start.lowerBound
            var index = start.lowerBound
            while index < code.endIndex {
                let c = code[index]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { end = code.index(after: index); break } }
                index = code.index(after: index)
            }
            if end == start.lowerBound { end = code.endIndex }
            regions.append(String(code[start.lowerBound..<end]))
            search = end
        }
        return regions
    }

    /// The text of each `extension UserProfile …{ … }`, braces balanced: inside one, a member
    /// is reached through implicit `self` (the sync mapper's `firstName = …`).
    static func extensionRegions(in code: String) -> [(firstLine: Int, text: String)] {
        var regions: [(Int, String)] = []
        var search = code.startIndex
        while let start = code.range(of: #"\bextension\s+UserProfile\b"#, options: .regularExpression,
                                     range: search..<code.endIndex) {
            guard let open = code[start.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var end = code.endIndex
            var index = open
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1; if depth == 0 { end = code.index(after: index); break } }
                index = code.index(after: index)
            }
            let firstLine = code[..<start.lowerBound].filter { $0 == "\n" }.count + 1
            regions.append((firstLine, String(code[start.lowerBound..<end])))
            search = end
        }
        return regions
    }

    /// Lines of `code` that read or write a legacy identity member through a UserProfile binding,
    /// or through implicit `self` inside an `extension UserProfile`.
    static func hits(in code: String) -> [String] {
        let members = identityMembers.joined(separator: "|")
        var found: [String] = []
        if let bare = try? NSRegularExpression(pattern: #"(?<![".\w$])(?:"# + members + #")\b(?!")"#) {
            for region in extensionRegions(in: code) {
                for (offset, line) in region.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let text = String(line)
                    if bare.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        found.append("\(region.firstLine + offset): \(text.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        let names = bindings(in: code)
        guard !names.isEmpty else { return found }
        let alternatives = names.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:"# + alternatives + #")\b[^\n;]*?\.\s*(?:"# + members + #")\b"#) else { return [] }
        for (number, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                found.append("\(number + 1): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    // MARK: - The rule

    @Test("Nothing outside the model and the legacy upload reads or writes the identity columns")
    func nothingElseTouchesTheIdentityColumns() {
        let files = GLSource.codeFiles()
        #expect(files.count > 50, "the scan found only \(files.count) source files")
        var offenders: [String] = []
        for file in files where allowedPath(file.path) == nil && quarantinedPath(file.path) == nil {
            for hit in Self.hits(in: file.text) { offenders.append("\(file.path):\(hit)") }
        }
        #expect(offenders.isEmpty, """
            Identity lives in the Gold Life ID (law 48a). Read MBIdentity.shared instead of \
            UserProfile's legacy columns: \(offenders.joined(separator: " | "))
            """)
    }

    @Test("Customer emails sign with the Gold Life ID name, not the legacy copy")
    func emailSignatureReadsTheGoldLifeID() throws {
        let code = try #require(GLSource.code("UIComponents/EmailSignature.swift"))
        #expect(code.contains("MBIdentity.shared.current"), "EmailSignature does not read the Gold Life ID")
        #expect(Self.hits(in: code).isEmpty, "EmailSignature still reads UserProfile: \(Self.hits(in: code))")
    }

    @Test("The retired per-app profile screen and migrator are gone")
    func retiredFilesAreGone() {
        #expect(GLSource.file("Screens/PersonalInfo.swift") == nil,
                "MyPersonalInfoFormScreen is back (law 48a: the Gold Life ID edit screen is the package's)")
        #expect(GLSource.file("Services/GLProfileMigrator.swift") == nil,
                "GLProfileMigrator is back (it uploads to the retired per-app profile API)")
    }

    @Test("Every quarantined file still needs its entry")
    func quarantineIsStillNeeded() {
        for (path, why) in Self.quarantine {
            let code = GLSource.code(path) ?? ""
            #expect(!Self.hits(in: code).isEmpty,
                    "\(path) no longer reads the legacy columns — remove its quarantine entry (\(why))")
        }
    }

    @Test("The scan sees every way a file can reach a UserProfile")
    func scanIsArmed() {
        let sample = """
            struct A { @Query private var userProfiles: [UserProfile]
              var x: String { userProfiles.first?.signatureData == nil ? "" : "" } }
            func b(_ person: UserProfile) { _ = person.firstName }
            func c(ctx: ModelContext) {
              guard let ctx2 = Optional(ctx), let me = try? ctx.fetch(FetchDescriptor<UserProfile>()).first else { return }
              _ = me.fullName
              for row in (try? ctx.fetch(FetchDescriptor<UserProfile>())) ?? [] { row.phone = "" }
              let fresh = UserProfile(); fresh.email = ""
            }
            func d(_ who: UserProfile) { _ = who.addressCity }
            extension UserProfile: GLSyncMappable {
              func payload() -> [String: Any] { ["phone": phone, "useMyNameInEmails": useMyNameInEmails] }
            }
            let table = [entry(UserProfile.self, key: "user_profile",
                               blobs: { profile in ["s": profile.photoData] },
                               setBlob: { profile, field, bytes in profile.signatureData = bytes })]
            """
        let found = Self.hits(in: sample)
        #expect(found.count == 9, "the scan saw \(found.count) of 9 reads/writes: \(found)")
        #expect(Self.hits(in: "let p: BusinessProfile = .init(); _ = p.phone").isEmpty,
                "a BusinessProfile read is not an identity read")
        #expect(Self.hits(in: "let me = UserProfile(); me.useMyNameInEmails = true").isEmpty,
                "the app-only setting is allowed")
    }

    @Test("In sample data the Gold Life ID card shows the same sample person as its rows")
    func goldLifeIDCardFollowsSampleData() throws {
        let code = try #require(GLSource.code("Screens/MenuScreen.swift"))
        #expect(code.contains("GoldLifeIDScreen(isSampleMode: MBIdentity.shared.isSampleData"),
                "the card shows the real (empty) Gold Life ID while the Signature row shows the sample person")
    }

    private func allowedPath(_ path: String) -> String? {
        Self.allowed.first { path.hasSuffix($0.key) }?.value
    }

    private func quarantinedPath(_ path: String) -> String? {
        Self.quarantine.first { path.hasSuffix($0.key) }?.value
    }
}
