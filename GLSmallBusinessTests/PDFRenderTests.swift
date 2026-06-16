//
//  PDFRenderTests.swift
//  GLSmallBusinessTests
//
//  Render every document to a PDF — this both verifies generation works end-to-end and exercises
//  the document layouts. Each renderer returns a temp-file URL that should be a valid PDF.
//

import Testing
import Foundation
import PDFKit
@testable import GLSmallBusiness

@MainActor
struct PDFRenderTests {
    private func business() -> BusinessProfile {
        let b = BusinessProfile()
        b.businessName = "Gold Life LLC"
        b.phone = "555-1212"
        b.email = "a@b.com"
        b.licenseNumber = "FL-123"
        b.address = Address(street1: "1 A St", city: "Tampa", state: "FL", postalCode: "33601")
        return b
    }

    private func isValidPDF(_ url: URL?) -> Bool {
        guard let url else { return false }
        return PDFDocument(url: url) != nil
    }

    @Test func invoicePDFRenders() {
        let inv = TS.invoice(taxRatePercent: 7, discountType: .percentage, discountValue: 10, lines: [(2400, true)])
        inv.customerFirstName = "Devin"; inv.customerLastName = "Odom"
        inv.serviceAddress = Address(street1: "1501 Belmont", city: "Tampa", state: "FL", postalCode: "33601")
        inv.customerNotes = "Referral discount applied"
        inv.terms = "Deposit required"
        TS.pay(inv, 384)
        inv.amountDueNow = 100
        #expect(isValidPDF(InvoicePDF.render(inv, business: business())))
    }

    @Test func estimatePDFRenders() {
        let est = TS.estimate(taxRatePercent: 7, lines: [(1000, true), (500, false)])
        est.customerFirstName = "Devin"
        est.depositType = .percentage
        est.depositValue = 30
        est.customerNotes = "Notes"
        est.terms = "Terms"
        #expect(isValidPDF(EstimatePDF.render(est, business: business())))
    }

    @Test func paymentReceiptPDFRenders() {
        let inv = TS.invoice(lines: [(1920, false)])
        inv.customerFirstName = "Devin"; inv.jobTitle = "Deck build"
        let p = TS.pay(inv, 384)
        #expect(isValidPDF(PaymentReceiptPDF.render(inv, payment: p, business: business())))
    }

    @Test func paymentReceiptPaidInFullRenders() {
        let inv = TS.invoice(lines: [(1000, false)])
        let p = TS.pay(inv, 1000)   // paid in full → the "PAID IN FULL" branch
        #expect(isValidPDF(PaymentReceiptPDF.render(inv, payment: p, business: business())))
    }

    @Test func changeOrderPDFRenders() {
        let inv = TS.invoice(lines: [(1000, false)])
        inv.customerFirstName = "Devin"
        let co = TS.changeOrder(inv, status: .approved, taxRatePercent: 7, lines: [(480, true), (-50, false)])
        co.note = "Customer requested membrane"
        #expect(isValidPDF(ChangeOrderPDF.render(co, business: business())))
    }

    @Test func w9PDFRenders() {
        let p = business()
        p.w9TaxClassificationRaw = W9TaxClassification.sCorporation.rawValue
        p.w9TINTypeRaw = W9TINType.ein.rawValue
        p.w9TIN = "123456789"
        // The bundled W-9 template lives in the app bundle (the test host).
        #expect(isValidPDF(W9PDF.render(p, signatureImage: nil, signedDate: nil)))
    }

    @Test func w9StillRendersWithIncompleteTIN() {
        // A short TIN must not be stamped (and must not crash) — the form renders blank in Part I.
        let p = business()
        p.w9TaxClassificationRaw = W9TaxClassification.individual.rawValue
        p.w9TINTypeRaw = W9TINType.ssn.rawValue
        p.w9TIN = "123"   // too short
        #expect(isValidPDF(W9PDF.render(p, signatureImage: nil, signedDate: nil)))
    }
}
