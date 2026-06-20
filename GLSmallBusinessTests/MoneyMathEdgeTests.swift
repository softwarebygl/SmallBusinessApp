//
//  MoneyMathEdgeTests.swift
//  GLSmallBusinessTests
//
//  Boundary behavior of EstimateTotals beyond the happy-path cases in MoneyMathTests:
//  caps, the never-negative floor, credits, and tax scaling under discount.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct MoneyMathEdgeTests {
    private func totals(_ lines: [(Double, Bool)], tax: Double = 0,
                        discount: AdjustmentType = .none, discountValue: Double = 0,
                        deposit: AdjustmentType = .none, depositValue: Double = 0) -> EstimateTotals {
        EstimateTotals(
            lines: lines.map { (lineTotal: $0.0, isTaxable: $0.1) },
            taxRatePercent: tax,
            discountType: discount, discountValue: discountValue,
            depositType: deposit, depositValue: depositValue
        )
    }

    @Test func fixedDiscountIsCappedAtSubtotal() {
        let t = totals([(100, false)], discount: .fixed, discountValue: 500)
        #expect(close(t.discount, 100))
        #expect(close(t.total, 0))
    }

    @Test func totalNeverGoesNegative() {
        let t = totals([(100, false), (-500, false)])   // a credit larger than the charge
        #expect(close(t.subtotal, -400))
        #expect(close(t.total, 0))
    }

    @Test func fixedDepositIsCappedAtTotal() {
        let t = totals([(200, false)], deposit: .fixed, depositValue: 1000)
        #expect(close(t.total, 200))
        #expect(close(t.deposit, 200))
    }

    @Test func hundredPercentDiscountZeroesTotalAndTax() {
        let t = totals([(100, true)], tax: 10, discount: .percentage, discountValue: 100)
        #expect(close(t.discount, 100))
        #expect(close(t.tax, 0))
        #expect(close(t.total, 0))
    }

    @Test func taxScalesWithProportionalDiscount() {
        let t = totals([(1000, true)], tax: 10, discount: .percentage, discountValue: 50)
        #expect(close(t.discount, 500))
        #expect(close(t.tax, 50))      // tax on the discounted taxable base
        #expect(close(t.total, 550))
    }
}
