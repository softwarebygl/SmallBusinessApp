//
//  StatsPeriodTests.swift
//  GLSmallBusinessTests
//
//  StatsPeriod.contains / label boundaries and StatsSummary derived values (net, average, win rate).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct StatsPeriodTests {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func allContainsEverything() {
        #expect(StatsPeriod.all.contains(day(2020, 1, 1)))
        #expect(StatsPeriod.all.contains(day(2030, 12, 31)))
    }

    @Test func yearMatchesOnlyThatYear() {
        let p = StatsPeriod.year(2026)
        #expect(p.contains(day(2026, 1, 1)))
        #expect(p.contains(day(2026, 12, 31)))
        #expect(!p.contains(day(2025, 12, 31)))
        #expect(!p.contains(day(2027, 1, 1)))
    }

    @Test func monthMatchesYearAndMonth() {
        let p = StatsPeriod.month(year: 2026, month: 6)
        #expect(p.contains(day(2026, 6, 1)))
        #expect(p.contains(day(2026, 6, 30)))
        #expect(!p.contains(day(2026, 7, 1)))
        #expect(!p.contains(day(2025, 6, 15)))   // right month, wrong year
    }

    @Test func labels() {
        #expect(StatsPeriod.all.label == "All time")
        #expect(StatsPeriod.year(2026).label == "2026")
        #expect(!StatsPeriod.month(year: 2026, month: 6).label.isEmpty)
    }
}

@MainActor
struct StatsSummaryTests {
    @Test func netIsCollectedMinusExpenses() {
        var s = StatsSummary()
        s.collected = 1000
        s.expenses = 300
        #expect(close(s.net, 700))
    }

    @Test func invoiceAverageGuardsZeroCount() {
        var s = StatsSummary()
        #expect(close(s.invoiceAverage, 0))   // no invoices → no divide-by-zero
        s.invoiceCount = 4
        s.invoiceTotal = 1000
        #expect(close(s.invoiceAverage, 250))
    }

    @Test func winRateNilUntilDecided() {
        var s = StatsSummary()
        #expect(s.winRate == nil)             // nothing decided yet
        s.estimatesAccepted = 3
        s.estimatesDeclined = 1
        #expect(close(s.winRate ?? -1, 0.75))
    }
}
