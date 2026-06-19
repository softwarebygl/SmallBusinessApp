//
//  ContractorPackageTests.swift
//  GLSmallBusinessTests
//
//  Covers the Contractor Package engine: building a PDFDocument from PDF/image data, merging the
//  package's documents into one PDF, the per-customer COI flag, and the share message.
//

import Testing
import Foundation
import PDFKit
import UIKit
@testable import GLSmallBusiness

@MainActor
struct ContractorPackageTests {

    // MARK: Fixtures

    private func blankPDFData(size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
    }

    private func imageData(size: CGSize = CGSize(width: 300, height: 200)) -> Data {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
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

    // MARK: Per-customer COI

    @Test func customerHasCOIReflectsUploadedData() {
        let c = Customer(firstName: "Dana", lastName: "Reed")
        #expect(!c.hasCOI)                          // nothing uploaded yet
        c.coiData = Data([0x25, 0x50])              // pretend a certificate on file
        c.coiName = "acme-coi.pdf"
        #expect(c.hasCOI)
    }

    // MARK: General docs on the business

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
