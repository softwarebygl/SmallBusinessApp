//
//  ChangeOrderTests.swift
//  GLSmallBusinessTests
//
//  Change-order money on the order itself: a charge, a credit, mixed lines, tax on the taxable lines
//  only, and the line-item total. Numbering lives in DocumentNumberingTests; the status round-trip
//  and the zero / offsetting / taxable-credit edges in CalendarJobsEstimatesCoverageTests.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct ChangeOrderTests {
    @Test func chargeSubtotalAndTotal() {
        let inv = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(inv, taxRatePercent: 0, lines: [(120 * 4, false)])
        #expect(close(co.subtotal, 480))
        #expect(close(co.total, 480))
    }

    @Test func creditMakesNegativeTotal() {
        let inv = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(inv, lines: [(-200, false)])
        #expect(close(co.subtotal, -200))
        #expect(close(co.total, -200))
    }

    @Test func mixedChargeAndCredit() {
        let inv = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(inv, lines: [(500, false), (-150, false)])
        #expect(close(co.total, 350))
    }

    @Test func taxAppliesToTaxableChangeLines() {
        let inv = TS.invoice(lines: [(1000, false)])
        let co = TS.changeOrder(inv, taxRatePercent: 10, lines: [(100, true), (100, false)])
        #expect(close(co.subtotal, 200))
        #expect(close(co.taxAmount, 10))
        #expect(close(co.total, 210))
    }

    @Test func lineItemTotalIsQuantityTimesPrice() {
        let item = ChangeOrderLineItem(name: "x", quantity: 3, unit: .squareFoot, unitPrice: 4)
        #expect(close(item.lineTotal, 12))
    }
}
