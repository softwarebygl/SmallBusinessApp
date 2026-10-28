//
//  PaymentProcessorTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct PaymentProcessorTests {

    // MARK: - Fee math

    @Test func processorFeeIsPercentPlusFlat() {
        let p = PaymentProcessor(name: "Stripe", feePercent: 2.9, flatFee: 0.30)
        #expect(close(p.fee(on: 100), 3.20))      // 2.90 + 0.30
        #expect(close(p.fee(on: 0), 0.30))        // the flat fee still applies on a $0 payment
        #expect(close(p.fee(on: 1000), 29.30))    // 29.00 + 0.30
    }

    @Test func feeDescriptionOmitsZeroParts() {
        #expect(PaymentProcessor(feePercent: 0, flatFee: 0).feeDescription.isEmpty)
        #expect(PaymentProcessor(feePercent: 2.5, flatFee: 0).feeDescription.contains("%"))
        #expect(!PaymentProcessor(feePercent: 0, flatFee: 0.25).feeDescription.contains("%"))   // no % when 0
        #expect(PaymentProcessor(feePercent: 2.9, flatFee: 0.30).feeDescription.contains("+"))  // both parts joined
    }

    // MARK: - Snapshot on the payment

    @Test func paymentFeeUsesSnapshotNotLiveProcessor() {
        let inv = TS.invoice(lines: [(1000, false)])
        let pay = TS.pay(inv, 1000, method: .card)
        pay.processorName = "Square"
        pay.processorFeePercentSnapshot = 2.6
        pay.processorFlatFeeSnapshot = 0.10
        #expect(close(pay.processingFee, 26.10))   // 1000 * 2.6% + 0.10
    }

    @Test func noProcessorMeansNoFee() {
        let inv = TS.invoice(lines: [(1000, false)])
        let pay = TS.pay(inv, 1000)
        #expect(pay.processorName.isEmpty)
        #expect(close(pay.processingFee, 0))
    }

    // MARK: - Stats aggregation

    @Test func statsTotalsProcessingFeesAndNetsThemOut() {
        let day = TS.day(2026, 6, 15)
        let inv = TS.invoice(number: "INV-0001", createdAt: day, lines: [(2000, false)])
        let pay = TS.pay(inv, 2000, date: day, method: .card)
        pay.processorName = "Card reader"
        pay.processorFeePercentSnapshot = 2.5
        pay.processorFlatFeeSnapshot = 0.30
        let receipt = TS.receipt(total: 300, category: "Materials", date: day)

        let s = StatsEngine.summary(period: .year(2026), invoices: [inv], estimates: [], receipts: [receipt])
        #expect(close(s.collected, 2000))
        #expect(close(s.expenses, 300))
        #expect(close(s.processingFees, 50.30))    // 2000 * 2.5% + 0.30
        #expect(close(s.net, 1649.70))             // 2000 - 300 - 50.30
    }

    @Test func feesCountAsMoneyOutInTheChart() {
        let day = TS.day(2026, 6, 15)
        let inv = TS.invoice(number: "INV-0001", createdAt: day, lines: [(1000, false)])
        let pay = TS.pay(inv, 1000, date: day, method: .card)
        pay.processorName = "Card reader"
        pay.processorFeePercentSnapshot = 3.0
        pay.processorFlatFeeSnapshot = 0

        let s = StatsEngine.summary(period: .year(2026), invoices: [inv], estimates: [], receipts: [])
        let juneLabel = Calendar.current.shortMonthSymbols[5]   // June
        let june = s.inOut.first { $0.label == juneLabel }
        #expect(june != nil)
        #expect(close(june?.moneyIn ?? 0, 1000))
        #expect(close(june?.moneyOut ?? 0, 30))    // the $30 processing fee shows as money out
    }
}
