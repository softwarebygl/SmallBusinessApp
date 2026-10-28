//
//  IdentifierNamingTests.swift — the person's identifier has ONE name.
//
//  Owner ruling (2026-08-06, applied to My Business 2026-08-23): the
//  identifier a person quotes to support is a "Gold Life ID", never an "Account
//  ID". My Business shipped both names at once — the deletion alert said "type
//  your Gold Life ID" while the row directly above it was labelled "Account ID",
//  one value under two names on a single screen. This scans SOURCE so
//  it catches a reintroduction anywhere, not only on the screens a UI test walks.
//
//  "Account ID" stays legitimate for a BANK account's id — that is a different
//  thing with a different owner — so the scan is scoped to this app's own strings.
//

import Foundation
import Testing

struct IdentifierNamingTests {

    /// Repo root, derived from this file's path so the test needs no bundled resource.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)              // …/GLSmallBusinessTests/ThisFile.swift
            .deletingLastPathComponent()             // …/GLSmallBusinessTests
            .deletingLastPathComponent()             // …/SmallBusinessApp
    }

    private func sources(under folder: String, ext: String) -> [URL] {
        let base = repoRoot.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: base,
                                                          includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }

    @Test func theStringCatalogNeverSaysAccountID() throws {
        let catalog = repoRoot.appendingPathComponent("GLSmallBusiness/Localizable.xcstrings")
        let text = try String(contentsOf: catalog, encoding: .utf8)
        #expect(!text.contains("Account ID"),
                "Localizable.xcstrings reintroduced \"Account ID\" — the person's identifier is a Gold Life ID.")
        // The Spanish half drifted independently once, so it gets its own claim.
        #expect(!text.contains("ID de cuenta"),
                "Localizable.xcstrings reintroduced \"ID de cuenta\" — Gold Life ID is a brand name and stays untranslated.")
    }

    @Test func noSwiftSourceSaysAccountID() throws {
        var offenders: [String] = []
        for file in sources(under: "GLSmallBusiness", ext: "swift") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("Account ID") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty,
                "these files say \"Account ID\": \(offenders.sorted().joined(separator: ", "))")
    }

    /// The sanity check on the check: the scan must actually be reading files.
    /// A typo'd path would make both assertions above pass over an empty list.
    @Test func theScanReadsRealSources() {
        let files = sources(under: "GLSmallBusiness", ext: "swift")
        #expect(files.count > 50, "expected the app's Swift sources, found \(files.count)")
    }
}
