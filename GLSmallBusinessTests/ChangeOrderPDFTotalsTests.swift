//
//  ChangeOrderPDFTotalsTests.swift
//  GLSmallBusinessTests
//
//  QA fix on ChangeOrderPDFDocument: the "Original invoice total" line must back the change order
//  out of the UNCLAMPED invoice sum — Invoice.totals floors the billed total at $0, so subtracting
//  a big applied credit from the clamped figure fabricated the original ($0 − (−$500) printed $500
//  for a $100 invoice).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct ChangeOrderPDFTotalsTests {

    /// Links an applied change order to the invoice group its items billed into — mirrors what
    /// `addItemsToInvoice` produces, assembled in memory per the TestSupport convention.
    private func applyToInvoice(_ co: ChangeOrder, on invoice: Invoice, lines: [(Double, Bool)]) {
        let group = InvoiceGroup(name: "Change Order", sortIndex: 1)
        group.invoice = invoice
        var items: [InvoiceLineItem] = []
        for (i, (price, taxable)) in lines.enumerated() {
            let item = InvoiceLineItem(name: "CO line \(i)", quantity: 1, unit: .job,
                                       unitPrice: price, isTaxable: taxable, sortIndex: i)
            item.fromChangeOrder = true
            item.group = group
            items.append(item)
        }
        group.lineItems = items
        invoice.groups = (invoice.groups ?? []) + [group]
        co.invoiceGroup = group
        co.appliedToInvoice = true
    }

    @Test func clampedCreditKeepsOriginalHonest() {
        // $100 of original work; an applied −$500 credit clamps the invoice to $0.
        let invoice = TS.invoice(lines: [(100, false)])
        let co = TS.changeOrder(invoice, lines: [(-500, false)])
        applyToInvoice(co, on: invoice, lines: [(-500, false)])
        #expect(close(invoice.total, 0))   // Invoice.totals' max(0, …) floor is active

        let doc = ChangeOrderPDFDocument(changeOrder: co, business: nil)
        #expect(close(doc.billedContribution, -500))
        // Before the fix this printed $500 (0 − (−500)); the invoice was actually $100.
        #expect(close(doc.originalTotal, 100))
        #expect(close(doc.revisedTotal, 0))
        // The PDF's arithmetic matches the invoice's own floor rule.
        #expect(close(doc.revisedTotal, max(0, doc.originalTotal + doc.billedContribution)))
    }

    @Test func unclampedAppliedChargeIsUnchanged() {
        // No floor in play — Original + Change = Revised exactly, as before the fix.
        let invoice = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(invoice, lines: [(250, false)])
        applyToInvoice(co, on: invoice, lines: [(250, false)])

        let doc = ChangeOrderPDFDocument(changeOrder: co, business: nil)
        #expect(close(doc.billedContribution, 250))
        #expect(close(doc.originalTotal, 1000))
        #expect(close(doc.revisedTotal, 1250))
    }

    @Test func anOrderSignedAtAnOlderRateAddsUpOnThePDF() {
        // The order was signed at 6%; the invoice's rate is 7% now. The invoice bills the order at
        // its signed 6% (law 87, QA F82), so the PDF's three figures add up and match the order.
        let invoice = TS.invoice(taxRatePercent: 7, lines: [(1000, true)])
        let co = TS.changeOrder(invoice, status: .approved, taxRatePercent: 6, lines: [(500, true)])
        applyToInvoice(co, on: invoice, lines: [(500, true)])
        co.invoiceGroup?.changeOrder = co

        let doc = ChangeOrderPDFDocument(changeOrder: co, business: nil)
        #expect(close(co.total, 530))
        #expect(close(invoice.total, 1600), "1000 + 7% = 1070, and the order's 500 + 6% = 530")
        #expect(close(doc.billedContribution, co.total))
        #expect(close(doc.originalTotal, 1070))
        #expect(close(doc.revisedTotal, invoice.total))
        #expect(close(doc.originalTotal + co.total, doc.revisedTotal))
    }

    @Test func unappliedOrderStillPreviewsFromCurrentTotal() {
        // Not applied: nothing billed yet, so the original IS the invoice total and the revised
        // figure previews the order on top.
        let invoice = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(invoice, lines: [(-200, false)])

        let doc = ChangeOrderPDFDocument(changeOrder: co, business: nil)
        #expect(close(doc.billedContribution, 0))
        #expect(close(doc.originalTotal, invoice.total))
        #expect(close(doc.revisedTotal, 800))
    }
}
