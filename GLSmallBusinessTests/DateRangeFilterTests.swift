//
//  DateRangeFilterTests.swift
//  GLSmallBusinessTests
//
//  The shared date-range filter behind every "View All" list (employee Hours / Paychecks,
//  subcontractor Activity). Covers the boundary cases that are easy to get wrong: year rollover,
//  a custom range inclusive of BOTH endpoint days (including late in the end day), and leap day.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct DateRangeFilterTests {

    // MARK: - .all

    @Test func allMatchesEverything() {
        let f = DateRangeFilter.all
        #expect(f.matches(TS.day(1999, 1, 1)))
        #expect(f.matches(TS.day(2026, 6, 15)))
        #expect(f.matches(TS.day(2050, 12, 31)))
    }

    // MARK: - .year (rollover)

    @Test func yearMatchesOnlyThatCalendarYear() {
        let f = DateRangeFilter.year(2026)
        #expect(!f.matches(TS.day(2025, 12, 31)))   // last day of prior year — excluded
        #expect(f.matches(TS.day(2026, 1, 1)))       // first day — included
        #expect(f.matches(TS.day(2026, 6, 15)))
        #expect(f.matches(TS.day(2026, 12, 31)))     // last day — included
        #expect(!f.matches(TS.day(2027, 1, 1)))      // first day of next year — excluded
    }

    // MARK: - .custom (inclusive of both endpoint days)

    @Test func customIncludesBothEndpointDays() {
        let f = DateRangeFilter.custom(from: TS.day(2026, 6, 10), to: TS.day(2026, 6, 12))
        #expect(!f.matches(TS.day(2026, 6, 9)))    // day before start
        #expect(f.matches(TS.day(2026, 6, 10)))    // start day (midnight)
        #expect(f.matches(TS.day(2026, 6, 11)))    // middle
        #expect(f.matches(TS.day(2026, 6, 12)))    // end day (midnight)
        #expect(!f.matches(TS.day(2026, 6, 13)))   // day after end
    }

    @Test func customIncludesTheWholeEndDay() {
        // A timestamp late on the end day must still be inside the range (the end is exclusive of
        // the NEXT day's start, not of the end day itself).
        let f = DateRangeFilter.custom(from: TS.day(2026, 6, 10), to: TS.day(2026, 6, 12))
        let lateOnEndDay = TS.day(2026, 6, 12).addingTimeInterval(23 * 3600 + 59 * 60)  // 23:59
        #expect(f.matches(lateOnEndDay))
        let startOfNextDay = TS.day(2026, 6, 13)
        #expect(!f.matches(startOfNextDay))
    }

    @Test func customSingleDayRange() {
        let f = DateRangeFilter.custom(from: TS.day(2026, 6, 10), to: TS.day(2026, 6, 10))
        #expect(f.matches(TS.day(2026, 6, 10)))
        #expect(f.matches(TS.day(2026, 6, 10).addingTimeInterval(12 * 3600)))  // noon same day
        #expect(!f.matches(TS.day(2026, 6, 9)))
        #expect(!f.matches(TS.day(2026, 6, 11)))
    }

    @Test func customRangeIsForgivingOfBackwardsDates() {
        // A user who sets From after To still gets the intended range, not an empty list.
        let backwards = DateRangeFilter.custom(from: TS.day(2026, 6, 12), to: TS.day(2026, 6, 10))
        #expect(!backwards.matches(TS.day(2026, 6, 9)))
        #expect(backwards.matches(TS.day(2026, 6, 10)))
        #expect(backwards.matches(TS.day(2026, 6, 11)))
        #expect(backwards.matches(TS.day(2026, 6, 12)))
        #expect(!backwards.matches(TS.day(2026, 6, 13)))
    }

    @Test func customSpansLeapDay() {
        // 2028 is a leap year — Feb 29 must be included in a range that straddles it.
        let f = DateRangeFilter.custom(from: TS.day(2028, 2, 28), to: TS.day(2028, 3, 1))
        #expect(f.matches(TS.day(2028, 2, 29)))
        #expect(f.matches(TS.day(2028, 2, 28)))
        #expect(f.matches(TS.day(2028, 3, 1)))
        #expect(!f.matches(TS.day(2028, 3, 2)))
    }

    // MARK: - apply(to:date:)

    @Test func applyFiltersAndPreservesOrder() {
        struct Row { let date: Date }
        let rows = [
            Row(date: TS.day(2025, 12, 31)),
            Row(date: TS.day(2026, 1, 2)),
            Row(date: TS.day(2026, 8, 9)),
            Row(date: TS.day(2027, 1, 1)),
        ]
        let kept = DateRangeFilter.year(2026).apply(to: rows, date: \.date)
        #expect(kept.count == 2)
        #expect(kept.map(\.date) == [TS.day(2026, 1, 2), TS.day(2026, 8, 9)])  // order preserved
    }

    @Test func applyOnEmptyIsEmpty() {
        let empty: [Date] = []
        #expect(DateRangeFilter.all.apply(to: empty, date: { $0 }).isEmpty)
        #expect(DateRangeFilter.year(2026).apply(to: empty, date: { $0 }).isEmpty)
    }
}
