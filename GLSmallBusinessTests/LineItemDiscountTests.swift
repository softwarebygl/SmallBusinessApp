//
//  LineItemDiscountTests.swift
//  GLSmallBusinessTests
//
//  Per-line-item discounts (#6) — the math, how a discounted line flows into the document total, how it
//  stacks with the whole-document discount + tax, that it never goes negative, that change-order lines
//  stay exempt (the #1 regression area), and that the discount carries through estimate→invoice.
//

import Testing
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct LineItemDiscountTests {

    // MARK: LineDiscount math

    @Test func noneIsZero() {
        #expect(LineDiscount.amount(type: .none, value: 50, gross: 100) == 0)
    }

    @Test func percentageIsAPercentOfGross() {
        #expect(close(LineDiscount.amount(type: .percentage, value: 10, gross: 200), 20))
        #expect(close(LineDiscount.amount(type: .percentage, value: 100, gross: 100), 100))
        #expect(close(LineDiscount.amount(type: .percentage, value: 150, gross: 100), 150))  // raw; capped by lineTotal
    }

    @Test func fixedIsCappedAtGross() {
        #expect(close(LineDiscount.amount(type: .fixed, value: 30, gross: 100), 30))
        #expect(close(LineDiscount.amount(type: .fixed, value: 150, gross: 100), 100))  // never more than the line
    }

    // MARK: Line item computed values

    @Test func lineTotalIsNetOfDiscount() {
        let item = EstimateLineItem(name: "X", quantity: 2, unitPrice: 100,
                                    discountType: .percentage, discountValue: 10)
        #expect(close(item.grossLineTotal, 200))
        #expect(close(item.lineDiscount, 20))
        #expect(close(item.lineTotal, 180))
    }

    @Test func lineTotalNeverGoesNegative() {
        let pct = EstimateLineItem(name: "X", quantity: 1, unitPrice: 100,
                                   discountType: .percentage, discountValue: 150)
        #expect(pct.lineTotal == 0)
        let flat = InvoiceLineItem(name: "Y", quantity: 1, unitPrice: 50,
                                   discountType: .fixed, discountValue: 999)
        #expect(flat.lineTotal == 0)
    }

    // MARK: Integration with the document total

    @Test func perLineDiscountReducesTheEstimateTotal() {
        let est = TS.estimate(taxRatePercent: 0, lines: [(100, false), (200, false)])
        let line0 = est.sortedGroups[0].sortedLineItems[0]
        line0.discountType = .percentage
        line0.discountValue = 50                       // 50% off the $100 line → $50
        #expect(close(est.subtotal, 250))              // 50 + 200
        #expect(close(est.total, 250))
    }

    @Test func perLineAndWholeDocumentDiscountStackWithTax() {
        let est = TS.estimate(taxRatePercent: 10, lines: [(100, true)])
        est.discountType = .percentage; est.discountValue = 10      // 10% off the whole estimate
        let line = est.sortedGroups[0].sortedLineItems[0]
        line.discountType = .fixed; line.discountValue = 20         // $20 off this line
        // line net 80; whole-doc 10% off → discount 8 → discounted 72; tax 80·(72/80)·10% = 7.2; total 79.2
        #expect(close(est.subtotal, 80))
        #expect(close(est.discountAmount, 8))
        #expect(close(est.taxAmount, 7.2))
        #expect(close(est.total, 79.2))
    }

    // MARK: Change-order exemption still holds with per-line discounts (the #1 area)

    @Test func changeOrderLinesIgnorePerLineAndWholeDocumentDiscounts() {
        let inv = TS.invoice(taxRatePercent: 10, discountType: .percentage, discountValue: 20,
                             lines: [(1000, true)])
        let group = inv.sortedGroups[0]
        let co = InvoiceLineItem(name: "CO", quantity: 1, unitPrice: 500, isTaxable: true, sortIndex: 1)
        co.fromChangeOrder = true
        co.group = group
        group.lineItems = (group.lineItems ?? []) + [co]
        #expect(close(inv.total, 1430))   // baseline from ChangeOrderDiscountTests

        // Discount the ORIGINAL line by $100 → net 900; CO line stays full price.
        let original = group.sortedLineItems.first { !$0.fromChangeOrder }!
        original.discountType = .fixed; original.discountValue = 100
        // original: 900 net, −20% = 180 → 720; tax 900·(720/900)·10% = 72 → 792
        // CO: 500 + 50 tax = 550 (NOT discounted)
        #expect(close(inv.total, 1342))
    }

    // MARK: Carry-through estimate → invoice

    @Test func invoiceMadeFromEstimateKeepsPerLineDiscount() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let est = Estimate(number: "EST-1")
        ctx.insert(est)
        let g = EstimateGroup(name: "G"); g.estimate = est; ctx.insert(g)
        let item = EstimateLineItem(name: "X", quantity: 1, unitPrice: 100, sortIndex: 0,
                                    discountType: .percentage, discountValue: 25)
        item.group = g; ctx.insert(item)

        let inv = Invoice.make(from: est, number: "INV-1", in: ctx)
        let invItem = inv.sortedGroups.first?.sortedLineItems.first
        #expect(invItem?.discountType == .percentage)
        #expect(close(invItem?.discountValue ?? -1, 25))
        #expect(close(invItem?.lineTotal ?? -1, 75))   // 100 − 25%
    }
}
