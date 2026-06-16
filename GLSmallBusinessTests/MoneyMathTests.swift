//
//  MoneyMathTests.swift
//  GLSmallBusinessTests
//
//  EstimateTotals is the single source of truth for subtotal/discount/tax/total/deposit.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct MoneyMathTests {
    private func totals(_ lines: [(Double, Bool)], tax: Double = 0,
                        discountType: AdjustmentType = .none, discountValue: Double = 0,
                        depositType: AdjustmentType = .none, depositValue: Double = 0) -> EstimateTotals {
        EstimateTotals(
            lines: lines.map { (lineTotal: $0.0, isTaxable: $0.1) },
            taxRatePercent: tax,
            discountType: discountType, discountValue: discountValue,
            depositType: depositType, depositValue: depositValue
        )
    }

    @Test func emptyLinesAreAllZero() {
        let t = totals([])
        #expect(t.subtotal == 0 && t.discount == 0 && t.tax == 0 && t.total == 0 && t.deposit == 0)
    }

    @Test func subtotalAndTaxOnTaxableLine() {
        let t = totals([(100, true)], tax: 10)
        #expect(close(t.subtotal, 100))
        #expect(close(t.tax, 10))
        #expect(close(t.total, 110))
    }

    @Test func taxOnlyAppliesToTaxableLines() {
        let t = totals([(100, true), (100, false)], tax: 10)
        #expect(close(t.subtotal, 200))
        #expect(close(t.tax, 10))   // only the $100 taxable line
        #expect(close(t.total, 210))
    }

    @Test func noTaxWhenRateIsZero() {
        let t = totals([(100, true)], tax: 0)
        #expect(t.tax == 0)
        #expect(close(t.total, 100))
    }

    @Test func percentageDiscountReducesTaxProportionally() {
        // 20% off $100 taxable → discount 20, discounted 80, tax = 100 * (80/100) * 10% = 8
        let t = totals([(100, true)], tax: 10, discountType: .percentage, discountValue: 20)
        #expect(close(t.discount, 20))
        #expect(close(t.tax, 8))
        #expect(close(t.total, 88))
    }

    @Test func fixedDiscountIsCappedAtSubtotal() {
        let t = totals([(50, false)], discountType: .fixed, discountValue: 100)
        #expect(close(t.discount, 50))   // capped at subtotal, not 100
        #expect(close(t.total, 0))       // clamped at zero, never negative
    }

    @Test func percentageDepositOfTotal() {
        let t = totals([(200, false)], depositType: .percentage, depositValue: 25)
        #expect(close(t.deposit, 50))
    }

    @Test func fixedDepositCappedAtTotal() {
        let t = totals([(80, false)], depositType: .fixed, depositValue: 1000)
        #expect(close(t.deposit, 80))
    }

    @Test func zeroSubtotalProducesNoTax() {
        let t = totals([(0, true)], tax: 10)
        #expect(t.tax == 0)
        #expect(t.total == 0)
    }
}
