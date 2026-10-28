//
//  StatsPeriodTests.swift
//  GLSmallBusinessTests
//
//  StatsPeriod.contains / label boundaries and StatsSummary derived values (net, average, win rate).
//  Dates and the `contains` checks run on the harness calendar, so a year / month boundary means
//  the same thing on every machine.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct StatsPeriodTests {
    private let cal = TS.calendar

    @Test func allContainsEverything() {
        #expect(StatsPeriod.all.contains(TS.day(2020, 1, 1), calendar: cal))
        #expect(StatsPeriod.all.contains(TS.day(2030, 12, 31), calendar: cal))
    }

    @Test func yearMatchesOnlyThatYear() {
        let p = StatsPeriod.year(2026)
        #expect(p.contains(TS.day(2026, 1, 1), calendar: cal))
        #expect(p.contains(TS.day(2026, 12, 31), calendar: cal))
        #expect(!p.contains(TS.day(2025, 12, 31), calendar: cal))
        #expect(!p.contains(TS.day(2027, 1, 1), calendar: cal))
    }

    @Test func monthMatchesYearAndMonth() {
        let p = StatsPeriod.month(year: 2026, month: 6)
        #expect(p.contains(TS.day(2026, 6, 1), calendar: cal))
        #expect(p.contains(TS.day(2026, 6, 30), calendar: cal))
        #expect(!p.contains(TS.day(2026, 7, 1), calendar: cal))
        #expect(!p.contains(TS.day(2025, 6, 15), calendar: cal))   // right month, wrong year
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
