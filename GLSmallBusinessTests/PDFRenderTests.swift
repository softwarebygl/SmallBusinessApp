//
//  PDFRenderTests.swift
//  GLSmallBusinessTests
//
//  Render every document to a PDF — this both verifies generation works end-to-end and exercises
//  the document layouts. Each renderer returns a temp-file URL that should be a valid PDF.
//  (The 1099-NEC generation path — render + preview, missing data, Box 1a formatting, per-generation
//  clean-up — lives in SubcontractorCoverageTests; only its auto-shrink / untyped-TIN branch is here.)
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

    @Test func w9RenderCleansPriorGenerationAndCleanUpRemovesFile() throws {
        let p = business()
        p.w9TaxClassificationRaw = W9TaxClassification.sCorporation.rawValue
        p.w9TINTypeRaw = W9TINType.ein.rawValue
        p.w9TIN = "123456789"
        let first = try #require(W9PDF.render(p, signatureImage: nil, signedDate: nil))
        let second = try #require(W9PDF.render(p, signatureImage: nil, signedDate: nil))
        #expect(first != second)                                        // unique per-generation folders
        #expect(!FileManager.default.fileExists(atPath: first.path))    // prior TIN file wiped by render
        #expect(FileManager.default.fileExists(atPath: second.path))
        W9PDF.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: second.path))   // nothing TIN-bearing left behind
    }

    @Test func invoicePDFRendersWithLongMultilineContent() {
        let b = business()
        b.businessName = "Gold Life Luxury Custom Tile & Hardwood Flooring Architectural Services LLC"
        b.address = Address(street1: "12345 North West Sunshine Boulevard Suite 400B Building C",
                            street2: "Floor 3 Department of Project Operations & Accounting",
                            city: "Saint Petersburg Greater Metropolitan Area",
                            state: "FL",
                            postalCode: "33701-9999")
        b.phone = "(813) 555-0199 ext 4421"
        b.email = "very-long-lead-contractor-inquiries-department@softwarebygl.com"
        b.licenseNumber = "CGC1529999-SPECIALTY-RESIDENTIAL-COMMERCIAL"

        let inv = TS.invoice(taxRatePercent: 7.5, discountType: .fixed, discountValue: 250, lines: [
            (3500, true),
            (1200, false)
        ])
        inv.jobTitle = "Complete Master Bathroom Historic Restoration & Custom Italian Marble Shower Enclosure Waterproofing"
        inv.customerFirstName = "Alexander Montgomery"
        inv.customerLastName = "Fitzgerald-Livingston III"
        inv.customerBusinessName = "Fitzgerald & Associates Wealth Asset Management Development Holding Corporation"
        inv.customerEmail = "alexander.fitzgerald.third@fitzgerald-wealth-partners-llc.com"
        inv.customerPhone = "(813) 555-9876 ext 102"
        inv.serviceAddress = Address(street1: "9876 Grand Estate Palmetto Point Boulevard West",
                                     street2: "Guest Carriage House & Private Swimming Pool Cabana",
                                     city: "Apollo Beach Coastal Harbor",
                                     state: "FL",
                                     postalCode: "33572-1234")

        if let group = inv.groups?.first {
            group.name = "Demolition, Structural Floor Reinforcement, & Subfloor Preparation Phase 1A"
            group.note = "All debris removed to off-site licensed disposal facility in accordance with county environmental standards."
            if let item = group.lineItems?.first {
                item.name = "Custom Waterjet-Cut Carrara Marble Hexagonal Mosaic Tile Installation with Epoxy Grout"
                item.details = "Includes mechanical grinding of existing concrete substrate, installation of Schluter-DITRA waterproofing uncoupling membrane, application of premium modified thin-set mortar, and anti-fracture crack isolation treatment."
                item.quantity = 450.75
                item.unit = .squareFoot
            }
        }

        inv.customerNotes = "All work performed strictly during approved homeowner association construction hours (8:00 AM to 5:00 PM Monday through Friday). Contractor to maintain protective drop cloths throughout main foyer and hardwood stairwells."
        inv.terms = "A 50% mobilization deposit is required prior to material acquisition and scheduling. Progress payment due upon waterproofing inspection approval. Final balance due immediately upon substantial completion and punch list sign-off. Past due invoices accrue interest at 1.5% per month."
        inv.amountDueNow = 2000
        inv.paymentTerms = .net15

        let p1 = TS.pay(inv, 1000)
        p1.note = "Initial bank wire transfer received from Chase Premier Corporate account ending in 4492."

        #expect(isValidPDF(InvoicePDF.render(inv, business: b)))
    }

    @Test func estimatePDFRendersWithLongMultilineContent() {
        let b = business()
        b.businessName = "Gold Life Luxury Custom Tile & Hardwood Flooring Architectural Services LLC"
        let est = TS.estimate(taxRatePercent: 8.25, lines: [(4500, true), (1800, false)])
        est.jobTitle = "Full Kitchen Remodel, Solid Quartzite Countertop Fabrication, and Handcrafted Moroccan Zellige Tile Backsplash"
        est.customerFirstName = "Christopher & Gwendolyn"
        est.customerLastName = "Vanderbilt-Holloway"
        est.customerBusinessName = "Vanderbilt Heritage Properties & Coastal Land Acquisitions Group LLC"
        est.serviceAddress = Address(street1: "742 Evergreen Terrace Presidential Boulevard South",
                                     street2: "Penthouse Suite 1400 Private Residence",
                                     city: "Clearwater Beach Waterfront District",
                                     state: "FL",
                                     postalCode: "33767-4321")
        if let group = est.groups?.first {
            group.name = "Architectural Tile Setting, Custom Mitred Edges, & Epoxy Grouting"
            group.note = "Materials sourced directly from certified boutique Italian stone distributors."
            if let item = group.lineItems?.first {
                item.name = "Handcrafted Zellige Glazed Ceramic Subway Tile Backsplash"
                item.details = "Precision laser leveling, handmade imperfect joint layout, stain-proof urethane resin grout, and continuous color-matched silicone caulking at all countertop junctions."
            }
        }
        est.depositType = .percentage
        est.depositValue = 40
        est.customerNotes = "Project timeline estimated at 3-4 consecutive weeks subject to material delivery confirmations."
        est.terms = "Proposal valid for 30 calendar days from issuance. Changes in scope of work will be executed through written change orders prior to commencement."

        #expect(isValidPDF(EstimatePDF.render(est, business: b)))
    }

    @Test func changeOrderPDFRendersWithLongMultilineContent() {
        let inv = TS.invoice(lines: [(5000, false)])
        inv.jobTitle = "Historic Residence Master Bath Spa & Sauna Renovation"
        inv.customerFirstName = "Montgomery"; inv.customerLastName = "Brewster"
        let co = TS.changeOrder(inv, status: .approved, taxRatePercent: 7, lines: [(1850, true), (320, false)])
        co.note = "Owner requested upgrade from standard ceramic subway tile to hand-selected Calacatta Gold marble slabs including bookmatched shower niche surround and heated bench slab installation."
        if let item = co.lineItems?.first {
            item.name = "Calacatta Gold Honed Marble Slab Fabrication & Wall Panel Mechanical Anchoring"
            item.details = "Full vertical slab handling, stainless steel clip stabilization, and perimeter waterproofing tie-in."
        }
        #expect(isValidPDF(ChangeOrderPDF.render(co, business: business())))
    }

    @Test func paymentReceiptPDFRendersWithLongMultilineContent() {
        let b = business()
        b.businessName = "Gold Life Luxury Custom Tile & Hardwood Flooring Architectural Services LLC"
        b.reviewsURL = "https://g.page/r/CYX1234567890-gold-life-luxury-custom-tile-saint-petersburg-fl/review"
        b.includeReviewLinkOnReceipts = true
        let inv = TS.invoice(lines: [(3500, false)])
        inv.jobTitle = "Historic Craftsman Bungalow Bathroom Restoration & Period Hex Mosaic Flooring"
        inv.customerFirstName = "Penelope"; inv.customerLastName = "Worthington-Smythe"
        inv.customerBusinessName = "Worthington Heritage Foundation for Architectural Preservation Inc."
        inv.customerEmail = "penelope.worthington@preservation-foundation-tampa.org"

        let p = TS.pay(inv, 3500)
        p.note = "Full and final settlement via certified cashier check #908123 from Suncoast Credit Union Main Branch."

        #expect(isValidPDF(PaymentReceiptPDF.render(inv, payment: p, business: b)))
    }

    @Test func completionPackagePDFRendersWithLongMultilineContent() throws {
        let b = business()
        b.businessName = "Gold Standard Tile & Architectural Stone LLC"
        b.licenseNumber = "CBC-0987654321-FLORIDA-STATE-LICENSED"
        b.warrantyText = """
            Gold Standard Tile warranties all tile and stone installation workmanship for a period of two (2) full calendar years from the date of final completion.
            This warranty covers adhesion failure, grout cracking or deterioration under normal residential usage, and failure of waterproofing membranes installed by our technicians.
            This warranty explicitly excludes damage caused by structural foundation movement, substrate settling, seismic activity, misuse of abrasive or acid-based chemical cleaners, or physical impact damage caused by third parties.
            For warranty claims, contact support@softwarebygl.com with your original completion certificate number.
            """
        let job = ScheduledJob(title: "Luxury Waterfront Estate Master Suite Steam Shower, Curbless Wet Room & Heated Marble Flooring",
                               serviceAddress: Address(street1: "10000 Royal Palm Island Drive", street2: "Private Dock Slip B-4", city: "Boca Grande", state: "FL", postalCode: "33921"),
                               agreedPrice: 28500,
                               status: .completed)
        job.customerName = "Lord & Lady Percival Harrington-Montague of Grand Palms Manor"
        let url = try #require(CompletionPackagePDF.render(job: job, business: b))
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount >= 3)
    }

    @Test func form1099NECShrinksLongTextAndHandlesUntypedTIN() {
        let payer = business()
        payer.businessName = String(repeating: "Very Long Business Name ", count: 6)  // forces auto-shrink
        let sub = TS.subcontractor(first: "No", last: "Type")
        sub.updateTIN("123456789")    // 9 digits but no TIN type → the unformatted fallback branch
        let url = Form1099NECPDF.render(payer: payer, recipient: sub, amount: 1_234_567.89, year: 2026)
        #expect(isValidPDF(url))
        sub.clearSecureTIN()
    }
}

// MARK: - One language per customer PDF (F21)

/// Every customer PDF is drawn in the app's chosen language — labels AND dates — never a Spanish
/// header over English totals or an English month (README "customer documents render in ONE
/// language"; laws 2 and 25). The PDFs are pictures of the page, so the test reads them back
/// with Vision. The app is set to Español here; the device stays English, the mixed case.
/// Dates are in January: English "Jan" / "January" vs Spanish "ene" / "enero".
/// ("Subtotal" and "Total" are the same word in both languages, so they can't prove anything.)
@Suite(.serialized)
@MainActor
struct PDFSpanishRenderTests {
    private static let january: Date = {
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.year = 2026; c.month = 1; c.day = 15; c.hour = 12
        return c.date ?? .now
    }()

    private func business() -> BusinessProfile {
        let b = BusinessProfile()
        b.businessName = "Gold Life LLC"
        b.address = Address(street1: "1 A St", city: "Tampa", state: "FL", postalCode: "33601")
        return b
    }

    /// Renders with the app in Spanish and returns what Vision reads off every page.
    private func spanishText(_ render: () -> URL?) throws -> String {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        let url = try #require(render())
        let document = try #require(PDFDocument(url: url))
        var text: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
            let cg = try #require(image.cgImage)
            text.append(try DrawnText.read(cg, languages: ["es-ES", "en-US"]))
        }
        return text.joined(separator: "\n")
    }

    private func expectNone(_ english: [String], in text: String, _ what: String) {
        for word in english {
            #expect(!text.contains(word), "\(what) in Spanish still shows “\(word)”; read: \(text)")
        }
    }

    private func expectAll(_ spanish: [String], in text: String, _ what: String) {
        let folded = text.lowercased()
        for word in spanish {
            #expect(folded.contains(word.lowercased()), "\(what) in Spanish is missing “\(word)”; read: \(text)")
        }
    }

    @Test func invoicePDFIsAllSpanish() throws {
        let inv = TS.invoice(createdAt: Self.january, taxRatePercent: 7, discountType: .percentage,
                             discountValue: 10, lines: [(2400, true)])
        inv.dueDate = Self.january
        TS.pay(inv, 384, date: Self.january)
        let text = try spanishText { InvoicePDF.render(inv, business: business()) }
        expectNone(["Paid", "Balance", "Discount", "Tax (", "Jan "], in: text, "Invoice PDF")
        expectAll(["Pagado", "Saldo", "Descuento", "Impuesto", "ene"], in: text, "Invoice PDF")
    }

    @Test func changeOrderPDFIsAllSpanish() throws {
        let inv = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(inv, status: .approved, taxRatePercent: 7, lines: [(480, true)])
        co.createdAt = Self.january
        let text = try spanishText { ChangeOrderPDF.render(co, business: business()) }
        expectNone(["Original invoice total", "Change subtotal", "This change order", "Revised total",
                    "Approved by", "Jan "], in: text, "Change order PDF")
        expectAll(["Total original de la factura", "Esta orden de cambio", "Total revisado",
                   "Aprobado por", "ene"], in: text, "Change order PDF")
    }

    @Test func paymentReceiptPDFIsAllSpanish() throws {
        let inv = TS.invoice(lines: [(1920, false)])
        let p = TS.pay(inv, 384, date: Self.january)
        let text = try spanishText { PaymentReceiptPDF.render(inv, payment: p, business: business()) }
        expectNone(["Invoice total", "Paid to date", "Jan "], in: text, "Receipt PDF")
        expectAll(["Total de la factura", "Pagado a la fecha", "ene"], in: text, "Receipt PDF")
    }

    @Test func paidInFullReceiptPDFIsAllSpanish() throws {
        let inv = TS.invoice(lines: [(1000, false)])
        let p = TS.pay(inv, 1000, date: Self.january)
        let text = try spanishText { PaymentReceiptPDF.render(inv, payment: p, business: business()) }
        expectNone(["PAID IN FULL", "Thank you", "Jan "], in: text, "Paid-in-full receipt PDF")
        expectAll(["PAGADO POR COMPLETO", "Gracias"], in: text, "Paid-in-full receipt PDF")
    }

    @Test func completionPackagePDFIsAllSpanish() throws {
        let b = business()
        b.warrantyText = "Un año de garantía."
        let job = ScheduledJob(title: "Baño", agreedPrice: 1200, status: .completed)
        job.customerName = "Ana Pérez"
        job.completedAt = Self.january
        let text = try spanishText { CompletionPackagePDF.render(job: job, business: b) }
        expectNone(["COMPLETION", "CERTIFICATE", "COMPLETED", "JOB", "CUSTOMER", "WARRANTY", "PAID IN FULL",
                    "January"], in: text, "Completion package PDF")
        expectAll(["CERTIFICADO", "TRABAJO", "CLIENTE", "GARANT", "enero"], in: text, "Completion package PDF")
    }
}
