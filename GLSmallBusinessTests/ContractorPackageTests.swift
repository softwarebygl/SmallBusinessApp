//
//  ContractorPackageTests.swift
//  GLSmallBusinessTests
//
//  Covers the Contractor Package engine: holder-line composition, certificate-holder box detection
//  (and its fallback), COI stamping, document merging, and the BusinessProfile helpers behind it.
//

import Testing
import Foundation
import PDFKit
import UIKit
@testable import GLSmallBusiness

@MainActor
struct ContractorPackageTests {

    // MARK: Fixtures

    /// A one-page PDF with the given text drawn at a UIKit point (origin top-left), so the embedded
    /// text is real/selectable — what `findString` reads.
    private func pdfData(text: String, at point: CGPoint,
                         size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            (text as NSString).draw(at: point, withAttributes: [
                .font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
        }
    }

    private func blankPDFData(size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
    }

    private func imageData(size: CGSize = CGSize(width: 300, height: 200)) -> Data {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    // MARK: holderLines

    @Test func holderLinesOrdersCompanyOwnerAddressDetails() {
        let lines = ContractorPackagePDF.holderLines(
            company: "GC Builders LLC", owner: "Dana Reed",
            address: "100 Main St\nTampa, FL 33601", details: "Job #42")
        #expect(lines == ["GC Builders LLC", "Dana Reed", "100 Main St", "Tampa, FL 33601", "Job #42"])
    }

    @Test func holderLinesTrimsAndDropsBlankLines() {
        let lines = ContractorPackagePDF.holderLines(
            company: "  GC  ", owner: "", address: "\n 1 A St \n\n Tampa \n", details: "  ")
        #expect(lines == ["GC", "1 A St", "Tampa"])
    }

    @Test func holderLinesEmptyWhenNothingEntered() {
        #expect(ContractorPackagePDF.holderLines(company: " ", owner: "", address: "", details: "\n").isEmpty)
    }

    // MARK: chooseLabelRect

    @Test func chooseLabelRectPrefersBottomMatch() {
        // PDF coords: high y = near the top. The disclaimer match sits high; the box header sits low.
        let disclaimer = CGRect(x: 400, y: 740, width: 110, height: 8)
        let boxHeader = CGRect(x: 36, y: 150, width: 110, height: 9)
        #expect(ContractorPackagePDF.chooseLabelRect([disclaimer, boxHeader], pageHeight: 792) == boxHeader)
    }

    @Test func chooseLabelRectPicksLowestOfSeveral() {
        let higher = CGRect(x: 36, y: 200, width: 110, height: 9)
        let lower = CGRect(x: 36, y: 120, width: 110, height: 9)
        #expect(ContractorPackagePDF.chooseLabelRect([higher, lower], pageHeight: 792) == lower)
    }

    @Test func chooseLabelRectNilWhenOnlyTopMatches() {
        let topOnly = CGRect(x: 400, y: 700, width: 110, height: 8)
        #expect(ContractorPackagePDF.chooseLabelRect([topOnly], pageHeight: 792) == nil)
    }

    // MARK: document(from:)

    @Test func documentFromPDFData() {
        let doc = ContractorPackagePDF.document(from: blankPDFData())
        #expect(doc?.pageCount == 1)
    }

    @Test func documentFromImageDataWrapsOnePage() {
        let doc = ContractorPackagePDF.document(from: imageData())
        #expect(doc?.pageCount == 1)
    }

    @Test func documentFromGarbageIsNil() {
        #expect(ContractorPackagePDF.document(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    // MARK: locateHolder

    @Test func locateHolderAutoDetectsLabel() throws {
        // Draw the label near the bottom of the page (UIKit y large → PDF y small).
        let data = pdfData(text: "CERTIFICATE HOLDER", at: CGPoint(x: 36, y: 690))
        let doc = try #require(ContractorPackagePDF.document(from: data))
        let placement = try #require(ContractorPackagePDF.locateHolder(in: doc))
        #expect(placement.autoDetected)
        #expect(placement.pageSize.width == 612)
        #expect(placement.width >= 120)
    }

    @Test func locateHolderFallsBackWhenNoLabel() throws {
        let doc = try #require(ContractorPackagePDF.document(from: blankPDFData()))
        let placement = try #require(ContractorPackagePDF.locateHolder(in: doc))
        #expect(!placement.autoDetected)
        // Fallback sits in the lower-left quadrant.
        #expect(placement.anchor.x < placement.pageSize.width / 2)
        #expect(placement.anchor.y < placement.pageSize.height / 2)
    }

    // MARK: stampedCOIData

    @Test func stampedCOIProducesValidPDF() throws {
        let coi = pdfData(text: "CERTIFICATE HOLDER", at: CGPoint(x: 36, y: 690))
        let stamped = ContractorPackagePDF.stampedCOIData(
            coiData: coi, lines: ["GC Builders LLC", "100 Main St", "Tampa, FL 33601"],
            offset: .zero, coverExisting: true)
        let out = try #require(stamped.flatMap { PDFDocument(data: $0) })
        #expect(out.pageCount == 1)
    }

    @Test func stampedCOIWorksOnImageCOI() {
        // An image COI has no text to auto-detect, but stamping must still succeed via the fallback.
        let stamped = ContractorPackagePDF.stampedCOIData(
            coiData: imageData(), lines: ["GC", "1 A St"],
            offset: CGSize(width: 5, height: -5), coverExisting: false)
        #expect(stamped.flatMap { PDFDocument(data: $0) } != nil)
    }

    @Test func stampedCOISucceedsWithNoHolderLines() {
        // Nothing is required — a blank holder still yields a valid (unstamped) COI page.
        let coi = pdfData(text: "CERTIFICATE HOLDER", at: CGPoint(x: 36, y: 690))
        let stamped = ContractorPackagePDF.stampedCOIData(
            coiData: coi, lines: [], offset: .zero, coverExisting: false)
        #expect(stamped.flatMap { PDFDocument(data: $0) } != nil)
    }

    @Test func stampedCOINilForGarbage() {
        #expect(ContractorPackagePDF.stampedCOIData(
            coiData: Data([0x01]), lines: ["X"], offset: .zero, coverExisting: false) == nil)
    }

    @Test func stampedCOIWidthOverrideHandlesLongLines() {
        // Long holder lines + a narrow box must still produce a valid PDF — they shrink to fit, never
        // truncate, and the block grows in height to show every line.
        let coi = pdfData(text: "CERTIFICATE HOLDER", at: CGPoint(x: 36, y: 690))
        let longLines = [
            "A Very Long General Contractor Company Name LLC & Associates",
            "1234 Exceptionally Long Street Address Boulevard, Suite 5600",
            "Tallahassee, Florida 32301-0000",
            "Attn: Accounts Payable / Reference PO-2026-0042",
        ]
        let narrow = ContractorPackagePDF.stampedCOIData(
            coiData: coi, lines: longLines, offset: .zero, coverExisting: true, width: 90)
        #expect(narrow.flatMap { PDFDocument(data: $0) } != nil)
        let wide = ContractorPackagePDF.stampedCOIData(
            coiData: coi, lines: longLines, offset: .zero, coverExisting: false, width: 420)
        #expect(wide.flatMap { PDFDocument(data: $0) } != nil)
    }

    // MARK: merge

    @Test func mergeConcatenatesPageCounts() {
        let url = ContractorPackagePDF.merge([blankPDFData(), blankPDFData(), imageData()],
                                             fileName: "Test-Package.pdf")
        let merged = url.flatMap { PDFDocument(url: $0) }
        #expect(merged?.pageCount == 3)
    }

    @Test func mergeSkipsUnreadableSources() {
        let url = ContractorPackagePDF.merge([blankPDFData(), Data([0x00])], fileName: "Test.pdf")
        #expect((url.flatMap { PDFDocument(url: $0) })?.pageCount == 1)
    }

    @Test func mergeNilWhenNothingReadable() {
        #expect(ContractorPackagePDF.merge([Data([0x00]), Data()], fileName: "Empty.pdf") == nil)
    }

    // MARK: BusinessProfile helpers

    @Test func coiHolderOffsetRoundTrips() {
        let p = BusinessProfile()
        p.coiHolderOffset = CGSize(width: 12, height: -7)
        #expect(p.coiHolderOffsetX == 12)
        #expect(p.coiHolderOffsetY == -7)
        #expect(p.coiHolderOffset == CGSize(width: 12, height: -7))
    }

    @Test func contractorPackageReadyNeedsCOIAndW9() {
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.w9TaxClassificationRaw = W9TaxClassification.llc.rawValue
        p.w9TINTypeRaw = W9TINType.ein.rawValue
        p.w9TIN = "123456789"
        #expect(p.w9IsComplete)
        #expect(!p.contractorPackageReady)          // no COI yet
        p.proofOfInsuranceData = Data([0x25, 0x50]) // pretend COI on file
        #expect(p.hasCOI)
        #expect(p.contractorPackageReady)
    }

    @Test func licenseDocumentFlowsThroughComplianceKind() {
        let p = BusinessProfile()
        ComplianceKind.license.store(p, data: imageData(), name: "license.png")
        #expect(p.hasLicenseDocument)
        #expect(ComplianceKind.license.data(p) != nil)
        #expect(ComplianceKind.license.fileName(p) == "license.png")
        #expect(p.hasComplianceDocuments)
    }

    // MARK: - ContractorPackageMessage

    @Test func packageMessageDefaultSubjectNamesBusiness() {
        let p = BusinessProfile(); p.businessName = "Gold Life LLC"
        #expect(ContractorPackageMessage.subject(business: p) == "Contractor package from Gold Life LLC")
        #expect(ContractorPackageMessage.subject(business: nil) == "Contractor package")
    }

    @Test func packageMessageBodyHasIntroClosingAndSignoff() {
        let p = BusinessProfile(); p.businessName = "Gold Life LLC"
        let body = ContractorPackageMessage.body(business: p)
        #expect(body.contains(ContractorPackageMessage.defaultIntro))
        #expect(body.contains(ContractorPackageMessage.defaultClosing))
        #expect(body.contains("— Gold Life LLC"))
    }

    @Test func packageMessageCustomOverridesApply() {
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.packageMessageSubject = "Our docs for you"
        p.packageMessageIntro = "Everything you asked for is attached."
        p.packageMessageClosing = "Thanks!"
        #expect(ContractorPackageMessage.subject(business: p) == "Our docs for you")
        let body = ContractorPackageMessage.body(business: p)
        #expect(body.contains("Everything you asked for is attached."))
        #expect(body.contains("Thanks!"))
        #expect(body.contains("— Gold Life LLC"))
    }
}
