//
//  DocumentSharingCoverageTests.swift
//
//  THE home of `CompliancePDF.tempURL` — the temp-file layer every "share this
//  document" flow goes through (readability sniffing, naming, fallbacks, extension
//  correction, collisions, write failures). Three defects were found here and fixed;
//  these are the regression tests.
//
//    1. Two different documents that happened to share a filename resolved to the
//       SAME temp path when no subdirectory was passed — which is what sharing a
//       single document does — so the second write replaced the first, and the
//       owner shared the wrong file.
//    2. The shared fallback names are all "….pdf", so an unnamed PHOTO of a
//       certificate went out named ".pdf" with image bytes inside — a file no PDF
//       reader on the receiving end could open.
//    3. A whitespace-only name was taken literally and shared a file called " .pdf"
//       while the screen above it displayed the fallback name.
//

import Testing
import Foundation
import UIKit
import PDFKit
@testable import GLSmallBusiness

@MainActor
struct DocumentSharingCoverageTests {

    // MARK: - Fixtures

    private var pdfBytes: Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .pdfData { $0.beginPage() }
    }

    private func pngBytes(_ color: UIColor = .darkGray) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.pngData() ?? Data()
    }

    private func jpegBytes() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.brown.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// Bytes that are neither a PDF nor a decodable image — a truncated upload,
    /// or a file that failed to download from iCloud.
    private var garbage: Data { Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]) }

    private func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    // MARK: - Readability sniffing

    /// The sniff must recognise everything a person can legitimately upload, and
    /// reject what it can't render. A false "readable" puts an unopenable file in
    /// a package; a false "unreadable" scares the owner off a good document.
    @Test func readabilityRecognisesRealUploadsAndRejectsJunk() {
        #expect(CompliancePDF.looksReadable(pdfBytes))
        #expect(CompliancePDF.looksReadable(pngBytes()))
        #expect(CompliancePDF.looksReadable(jpegBytes()))

        #expect(!CompliancePDF.looksReadable(garbage))
        #expect(!CompliancePDF.looksReadable(Data()))
        #expect(!CompliancePDF.looksReadable(Data([0x25])))          // one byte of "%PDF"
        #expect(!CompliancePDF.looksReadable(Data("hello".utf8)))
    }

    /// HEIC is what an iPhone camera produces by default, so a photographed
    /// certificate MUST sniff as readable — this is the most likely upload of all.
    @Test func heicIsRecognised() {
        // ftyp box with a "heic" brand — the real signature of a camera roll photo.
        var heic = Data([0x00, 0x00, 0x00, 0x18])
        heic.append(contentsOf: Array("ftypheic".utf8))
        heic.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        #expect(CompliancePDF.looksReadable(heic))
    }

    /// The sniff is asked while a row is being drawn, so it must not depend on
    /// parsing the whole document — a huge file is answered from its first bytes.
    @Test func readabilityDoesNotDependOnDocumentSize() {
        var big = pdfBytes
        big.append(Data(repeating: 0x41, count: 2_000_000))
        #expect(CompliancePDF.looksReadable(big))
    }

    // MARK: - Temp URL: the collision fix

    /// THE REGRESSION TEST. Two different documents under one filename — a
    /// customer's "Scan.pdf" and the license's "Scan.pdf" — must not overwrite
    /// each other. Before the fix these resolved to one path and the first
    /// document's bytes were replaced by the second's.
    @Test func differentDocumentsWithTheSameNameDoNotCollide() throws {
        let name = "Scan.pdf"
        let first = pdfBytes
        var second = pdfBytes
        second.append(Data(repeating: 0x20, count: 64))     // same format, different bytes

        let urlA = try #require(CompliancePDF.tempURL(first, name: name, fallback: "F.pdf"))
        let urlB = try #require(CompliancePDF.tempURL(second, name: name, fallback: "F.pdf"))

        #expect(urlA != urlB, "two different documents still share one temp path")
        #expect(try Data(contentsOf: urlA) == first, "the first document was overwritten")
        #expect(try Data(contentsOf: urlB) == second)
        #expect(urlA.lastPathComponent == name, "the shared file must keep its name")
        #expect(urlB.lastPathComponent == name)
        cleanUp(urlA, urlB)
    }

    /// The SAME document written twice reuses one file rather than piling up a
    /// new copy per share — the folder is content-addressed, so this is stable.
    @Test func theSameDocumentReusesOneTempFile() throws {
        let data = pdfBytes
        let a = try #require(CompliancePDF.tempURL(data, name: "COI.pdf", fallback: "F.pdf"))
        let b = try #require(CompliancePDF.tempURL(data, name: "COI.pdf", fallback: "F.pdf"))
        #expect(a == b)
        #expect(try Data(contentsOf: a) == data)
        cleanUp(a)
    }

    /// An explicitly passed subdirectory still wins — the "share all" bundle
    /// depends on one folder per slot so its files sit side by side. The whole
    /// reason `subdirectory` exists: two slots uploaded under the identical
    /// filename (a common scanner default) must land at distinct URLs, each in
    /// its own slot folder, with their own bytes intact.
    @Test func explicitSubdirectoryIsStillHonoured() throws {
        let url = try #require(CompliancePDF.tempURL(pdfBytes, name: "Cert.pdf",
                                                     fallback: "F.pdf", subdirectory: "wcCoi"))
        #expect(url.deletingLastPathComponent().lastPathComponent == "wcCoi")
        #expect(url.lastPathComponent == "Cert.pdf")
        cleanUp(url)

        let wc = Data("workers-comp-exemption".utf8)
        let license = Data("contractor-license".utf8)
        let urlA = try #require(CompliancePDF.tempURL(
            wc, name: "Scan.pdf", fallback: "F.pdf", subdirectory: ComplianceKind.wcExemption.rawValue))
        let urlB = try #require(CompliancePDF.tempURL(
            license, name: "Scan.pdf", fallback: "F.pdf", subdirectory: ComplianceKind.license.rawValue))
        #expect(urlA != urlB)
        #expect(urlA.lastPathComponent == "Scan.pdf" && urlB.lastPathComponent == "Scan.pdf")
        #expect(urlA.deletingLastPathComponent().lastPathComponent == ComplianceKind.wcExemption.rawValue)
        #expect(urlB.deletingLastPathComponent().lastPathComponent == ComplianceKind.license.rawValue)
        #expect(try Data(contentsOf: urlA) == wc)
        #expect(try Data(contentsOf: urlB) == license)
        cleanUp(urlA, urlB)
    }

    /// A filename containing a path separator points into a directory that
    /// doesn't exist, so the write fails and the caller gets nil (no Share
    /// button) rather than a crash.
    @Test func nameEscapingIntoAMissingDirectoryReturnsNil() {
        let badName = "gl-no-such-dir-\(UUID().uuidString)/Cert.pdf"
        #expect(CompliancePDF.tempURL(Data("x".utf8), name: badName, fallback: "fb.pdf") == nil)
        #expect(CompliancePDF.tempURL(pdfBytes, name: badName, fallback: "F.pdf") == nil)
    }

    // MARK: - Temp URL: names and fallbacks

    /// A blank name — empty OR whitespace-only — falls back, so the shared file is
    /// named exactly what the screen above it displays. Whitespace used to be taken
    /// literally and shared a file called " .pdf" while `displayName` in
    /// DocumentDetailScreen, which does trim, showed the fallback.
    @Test func blankNamesFallBackToTheFallbackName() throws {
        for blank in ["", " ", "   ", "\n", "\t "] {
            let url = try #require(CompliancePDF.tempURL(pdfBytes, name: blank,
                                                         fallback: "Contractor-License.pdf"))
            #expect(url.lastPathComponent == "Contractor-License.pdf",
                    "\(blank.debugDescription) was taken literally")
            cleanUp(url)
        }
    }

    /// Unicode filenames round-trip untouched.
    @Test func unicodeFileNamesRoundTrip() throws {
        let name = "Licencia–Contratista–2026–✓.pdf"
        let url = try #require(CompliancePDF.tempURL(pdfBytes, name: name, fallback: "F.pdf"))
        #expect(url.lastPathComponent == name)
        #expect(FileManager.default.fileExists(atPath: url.path))
        cleanUp(url)
    }

    /// Nothing to build a base name from — empty name AND empty fallback — gives
    /// "Document" plus the sniffed extension, never a file whose whole name is an
    /// extension.
    @Test func noNameAtAllFallsBackToDocument() throws {
        let url = try #require(CompliancePDF.tempURL(pngBytes(), name: "", fallback: ""))
        #expect(url.lastPathComponent == "Document.png")
        cleanUp(url)
    }

    // MARK: - Temp URL: the extension fix

    /// THE REGRESSION TEST. An unnamed photo used to be shared as "Document.pdf"
    /// with PNG bytes inside. The extension now follows the CONTENT, so what
    /// arrives on the other end opens.
    @Test func unnamedImageIsSharedWithAnImageExtension() throws {
        let url = try #require(CompliancePDF.tempURL(pngBytes(), name: "",
                                                     fallback: "Document.pdf"))
        #expect(url.pathExtension == "png", "still mislabelled as .\(url.pathExtension)")
        #expect(PDFDocument(url: url) == nil)
        #expect(UIImage(data: try Data(contentsOf: url)) != nil)
        cleanUp(url)
    }

    /// A JPEG named ".pdf" by whatever produced it is corrected too — the name a
    /// file arrives under can't be trusted, only its bytes. And a PDF misnamed as
    /// an image is corrected the other way.
    @Test func misnamedJPEGIsCorrected() throws {
        let url = try #require(CompliancePDF.tempURL(jpegBytes(), name: "certificate.pdf",
                                                     fallback: "Document.pdf"))
        #expect(url.pathExtension == "jpg")
        #expect(url.deletingPathExtension().lastPathComponent == "certificate",
                "the owner's chosen name must survive the correction")
        cleanUp(url)

        let mislabelled = try #require(CompliancePDF.tempURL(pdfBytes, name: "Scan.png",
                                                             fallback: "F.pdf"))
        #expect(mislabelled.lastPathComponent == "Scan.pdf")
        cleanUp(mislabelled)
    }

    /// A real PDF named ".pdf" is left completely alone — the common case must
    /// not be churned by the correction — and the exact bytes land under that name.
    @Test func correctlyNamedPDFIsUntouched() throws {
        let data = pdfBytes
        let url = try #require(CompliancePDF.tempURL(data, name: "W-9.pdf", fallback: "F.pdf"))
        #expect(url.lastPathComponent == "W-9.pdf")
        #expect(try Data(contentsOf: url) == data)
        cleanUp(url)
    }

    /// ".jpeg" and ".jpg" are the same format; the correction must not flip one
    /// spelling into the other and rename the owner's file for no reason.
    @Test func jpegSpellingIsNotRewritten() throws {
        let url = try #require(CompliancePDF.tempURL(jpegBytes(), name: "photo.jpeg", fallback: "F.pdf"))
        #expect(url.lastPathComponent == "photo.jpeg")
        cleanUp(url)
    }

    /// A name with no extension at all gains the right one — for a PDF and for an
    /// image — so the receiving app knows what it is.
    @Test func extensionlessNameGainsTheRightExtension() throws {
        let url = try #require(CompliancePDF.tempURL(pdfBytes, name: "Certificate", fallback: "F.pdf"))
        #expect(url.pathExtension == "pdf")
        #expect(url.lastPathComponent == "Certificate.pdf")
        cleanUp(url)

        let bare = try #require(CompliancePDF.tempURL(pngBytes(), name: "Certificate", fallback: "F.pdf"))
        #expect(bare.lastPathComponent == "Certificate.png")
        cleanUp(bare)
    }

    /// Unrecognisable bytes keep whatever name they had — even a ".pdf" one — the
    /// sniff has no better answer, and inventing one would be a guess.
    @Test func unrecognisedBytesKeepTheirGivenName() throws {
        let url = try #require(CompliancePDF.tempURL(garbage, name: "mystery.dat", fallback: "F.pdf"))
        #expect(url.lastPathComponent == "mystery.dat")
        cleanUp(url)

        let text = try #require(CompliancePDF.tempURL(Data("plain text, no signature".utf8),
                                                      name: "Mystery.pdf", fallback: "F.pdf"))
        #expect(text.lastPathComponent == "Mystery.pdf")
        cleanUp(text)
    }

    /// Empty data still produces a file rather than nil — the caller decides what
    /// an empty document means; this layer just writes what it is given.
    @Test func emptyDataStillWrites() throws {
        let url = try #require(CompliancePDF.tempURL(Data(), name: "empty.pdf", fallback: "F.pdf"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).isEmpty)
        cleanUp(url)
    }
}
