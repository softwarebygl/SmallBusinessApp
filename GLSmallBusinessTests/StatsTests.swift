//
//  StatsTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct StatsTests {
    @Test func yearSummaryAddsUpEveryField() {
        let day = TS.day(2026, 6, 15)
        let inv1 = TS.invoice(number: "INV-0001", createdAt: day, taxRatePercent: 10, lines: [(1000, true)])
        TS.pay(inv1, 400, date: day)
        let inv2 = TS.invoice(number: "INV-0002", createdAt: day, lines: [(2000, false)])
        let receipt = TS.receipt(total: 300, category: "Materials", date: day)
        let estA = TS.estimate(number: "EST-0001", createdAt: day, status: .accepted, lines: [(5000, false)])
        let estD = TS.estimate(number: "EST-0002", createdAt: day, status: .declined, lines: [(1000, false)])

        let s = StatsEngine.summary(period: .year(2026),
                                    invoices: [inv1, inv2], estimates: [estA, estD], receipts: [receipt])
        #expect(close(s.collected, 400))
        #expect(close(s.expenses, 300))
        #expect(close(s.net, 100))
        #expect(close(s.salesTax, 100))              // 10% of the $1000 taxable invoice
        #expect(s.invoiceCount == 2)
        #expect(close(s.invoiced, 3100))             // 1100 (taxed) + 2000
        #expect(close(s.outstanding, 2700))          // (1100-400) + 2000
        #expect(s.estimatesAccepted == 1)
        #expect(s.estimatesDeclined == 1)
        #expect(s.estimatesTotal == 2)
        #expect(s.winRate == 0.5)
        #expect(close(s.invoiceAverage, 1550))       // 3100 / 2
        #expect(s.expensesByCategory.count == 1)
        #expect(s.expensesByCategory.first?.category == "Materials")
    }

    @Test func periodExcludesOtherYears() {
        let i2025 = TS.invoice(number: "INV-0001", createdAt: TS.day(2025, 6, 1), lines: [(1000, false)])
        let i2026 = TS.invoice(number: "INV-0002", createdAt: TS.day(2026, 6, 1), lines: [(2000, false)])
        let s = StatsEngine.summary(period: .year(2026), invoices: [i2025, i2026], estimates: [], receipts: [])
        #expect(s.invoiceCount == 1)
        #expect(close(s.invoiced, 2000))
    }

    @Test func monthPeriodFiltersByMonth() {
        let jun = TS.invoice(number: "INV-0001", createdAt: TS.day(2026, 6, 10), lines: [(1000, false)])
        let jul = TS.invoice(number: "INV-0002", createdAt: TS.day(2026, 7, 10), lines: [(2000, false)])
        let s = StatsEngine.summary(period: .month(year: 2026, month: 6), invoices: [jun, jul], estimates: [], receipts: [])
        #expect(s.invoiceCount == 1)
        #expect(close(s.invoiced, 1000))
    }

    @Test func allTimeIncludesEverything() {
        let a = TS.invoice(number: "INV-0001", createdAt: TS.day(2024, 1, 1), lines: [(1000, false)])
        let b = TS.invoice(number: "INV-0002", createdAt: TS.day(2026, 1, 1), lines: [(2000, false)])
        let s = StatsEngine.summary(period: .all, invoices: [a, b], estimates: [], receipts: [])
        #expect(s.invoiceCount == 2)
        #expect(close(s.invoiced, 3000))
    }

    @Test func collectedCountsPaymentByPaymentDateNotInvoiceDate() {
        // Invoice created in 2025, but paid in 2026 → the 2026 collected total includes it.
        let inv = TS.invoice(createdAt: TS.day(2025, 12, 1), lines: [(1000, false)])
        TS.pay(inv, 1000, date: TS.day(2026, 1, 5))
        let s2026 = StatsEngine.summary(period: .year(2026), invoices: [inv], estimates: [], receipts: [])
        #expect(close(s2026.collected, 1000))
        #expect(s2026.invoiceCount == 0)             // invoice was created in 2025
    }

    @Test func winRateNilWhenNothingDecided() {
        let est = TS.estimate(createdAt: TS.day(2026, 1, 1), status: .sent, lines: [(1000, false)])
        let s = StatsEngine.summary(period: .year(2026), invoices: [], estimates: [est], receipts: [])
        #expect(s.winRate == nil)
        #expect(s.estimatesPending == 1)
    }

    @Test func invoiceAverageIsZeroWithNoInvoices() {
        let s = StatsEngine.summary(period: .year(2026), invoices: [], estimates: [], receipts: [])
        #expect(s.invoiceAverage == 0)
        #expect(s.net == 0)
    }

    @Test func availableYearsCollectsEveryYearWithActivity() {
        let inv = TS.invoice(createdAt: TS.day(2024, 5, 1), lines: [(100, false)])
        TS.pay(inv, 100, date: TS.day(2026, 1, 1))
        let receipt = TS.receipt(total: 50, category: "Fuel", date: TS.day(2025, 3, 1))
        let years = StatsEngine.availableYears(invoices: [inv], estimates: [], receipts: [receipt])
        #expect(years.contains(2024))   // invoice created
        #expect(years.contains(2025))   // receipt
        #expect(years.contains(2026))   // payment
        #expect(years == years.sorted(by: >))   // newest first
    }

    @Test func inOutBucketsByMonthForAYear() {
        let inv = TS.invoice(createdAt: TS.day(2026, 6, 1), lines: [(1000, false)])
        TS.pay(inv, 600, date: TS.day(2026, 6, 15))
        let receipt = TS.receipt(total: 200, category: "Tools", date: TS.day(2026, 6, 20))
        let s = StatsEngine.summary(period: .year(2026), invoices: [inv], estimates: [], receipts: [receipt])
        #expect(s.inOut.count == 12)
        let june = s.inOut.first { $0.sortKey == 6 }
        #expect(close(june?.moneyIn ?? -1, 600))
        #expect(close(june?.moneyOut ?? -1, 200))
    }

    // Covers the single-pass bucketing's all-time (by year) branch.
    @Test func inOutBucketsByYearForAllTime() {
        let inv = TS.invoice(createdAt: TS.day(2025, 1, 1), lines: [(1000, false)])
        TS.pay(inv, 300, date: TS.day(2025, 7, 1))
        TS.pay(inv, 400, date: TS.day(2026, 2, 1))
        let r2025 = TS.receipt(total: 100, category: "Tools", date: TS.day(2025, 5, 1))
        let r2026 = TS.receipt(total: 150, category: "Fuel", date: TS.day(2026, 3, 1))
        let s = StatsEngine.summary(period: .all, invoices: [inv], estimates: [], receipts: [r2025, r2026])
        let y2025 = s.inOut.first { $0.sortKey == 2025 }
        let y2026 = s.inOut.first { $0.sortKey == 2026 }
        #expect(close(y2025?.moneyIn ?? -1, 300))
        #expect(close(y2025?.moneyOut ?? -1, 100))
        #expect(close(y2026?.moneyIn ?? -1, 400))
        #expect(close(y2026?.moneyOut ?? -1, 150))
    }

    // Covers the single-pass bucketing's single-month branch — items in other months are excluded.
    @Test func inOutBucketForSpecificMonth() {
        let inv = TS.invoice(createdAt: TS.day(2026, 6, 1), lines: [(2000, false)])
        TS.pay(inv, 500, date: TS.day(2026, 6, 10))
        TS.pay(inv, 999, date: TS.day(2026, 7, 10))   // different month — must be excluded
        let rJune = TS.receipt(total: 80, category: "Tools", date: TS.day(2026, 6, 12))
        let rJuly = TS.receipt(total: 70, category: "Fuel", date: TS.day(2026, 7, 12))   // excluded
        let s = StatsEngine.summary(period: .month(year: 2026, month: 6), invoices: [inv], estimates: [], receipts: [rJune, rJuly])
        #expect(s.inOut.count == 1)
        #expect(close(s.inOut.first?.moneyIn ?? -1, 500))
        #expect(close(s.inOut.first?.moneyOut ?? -1, 80))
    }
}
