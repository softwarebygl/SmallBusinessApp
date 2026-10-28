//
//  FileImportLimitTests.swift
//  GLSmallBusinessTests
//
//  F124 (2026-10-03 audit): every Files importer read the whole picked file on the main thread
//  with no size check. A file over the backup's 25 MB limit attached on the phone, then the
//  sync dropped it without a word, so it was lost on sign-out or on another device. A picked
//  file is now size-checked first, refused over 25 MB with one plain sentence, and read off
//  the main thread.
//

import Foundation
import Testing
@testable import GLSmallBusiness

@Suite(.serialized)
struct FileImportLimitTests {

    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).pdf")
        try Data(count: bytes).write(to: url)
        return url
    }

    /// The limit is the backup's own (the Worker's MAX_BYTES), not a second copy of 25 MB.
    @Test func theLimitIsTheBackupsLimit() {
        #expect(FileImport.byteLimit == GLSyncTransport.attachmentByteLimit)
        #expect(FileImport.byteLimit == 25 * 1024 * 1024)
    }

    /// A 26 MB file is refused before it is read. HEAD attached it.
    @Test func aFileOverTheLimitIsRefused() async throws {
        let url = try tempFile(bytes: 26 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await FileImport.read(url)
        #expect(result == .failure(.tooLarge))
    }

    /// A file right at the limit still attaches, whole.
    @Test func aFileAtTheLimitIsRead() async throws {
        let url = try tempFile(bytes: FileImport.byteLimit)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await FileImport.read(url)
        #expect((try? result.get())?.count == FileImport.byteLimit)
    }

    /// An empty or missing file is "couldn’t read", not "too large".
    @Test func emptyAndMissingFilesAreUnreadable() async throws {
        let empty = try tempFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(await FileImport.read(empty) == .failure(.unreadable))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).pdf")
        #expect(await FileImport.read(missing) == .failure(.unreadable))
    }

    /// The refusal says, in one plain sentence, why the file can't be added (EN + ES).
    @Test func theRefusalSentenceIsInTheCatalog() throws {
        let catalog = try #require(GLSource.file("Localizable.xcstrings"))
        #expect(catalog.contains("\"That file is over 25 MB, so it can’t be backed up.\""))
        #expect(catalog.contains("Ese archivo pesa más de 25 MB, así que no se puede respaldar."))
        #expect(catalog.contains("\"Couldn’t add that file\""))
    }

    /// Every Files importer goes through the size-checked, off-main read and shows the shared
    /// alert; none reads the picked file on the main thread any more.
    @Test func everyImporterUsesTheCheckedRead() throws {
        let sites = ["Screens/CustomerDetailScreen.swift", "Screens/ContractorPackage.swift",
                     "Screens/DocumentDetailScreen.swift", "Screens/InsuranceDocuments.swift",
                     "Screens/InvoiceDetailScreen.swift", "Screens/JobDetailScreen.swift",
                     "Screens/ProjectScreens.swift"]
        for site in sites {
            let code = try #require(GLSource.code(site), "\(site) is missing")
            #expect(code.contains("await FileImport.read("), "\(site) does not size-check its import")
            #expect(code.contains(".fileImportFailureAlert("), "\(site) does not show the shared import alert")
        }
        let syncReaders = GLSource.codeFiles().filter { $0.text.contains("readSecurityScoped()") }.map(\.path)
        #expect(syncReaders.isEmpty, "still reads a picked file on the main thread: \(syncReaders)")
    }
}
