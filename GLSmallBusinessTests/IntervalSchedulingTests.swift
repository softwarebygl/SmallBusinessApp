//
//  IntervalSchedulingTests.swift
//  GLSmallBusinessTests
//
//  The timed-aware interval engine: a timed job occupies only its window (so days are shared), an
//  all-day job the whole working day, and two timed jobs share a day without blocking it. The
//  window / full-day-run shapes `openings` returns and `subtract`'s edge cases live in
//  CalendarJobsEstimatesCoverageTests (Openings / clear date). Anchored to 2026 (June 1 = Monday)
//  on the harness calendar; .standard schedule is Mon–Fri 8:00–17:00.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct IntervalSchedulingTests {
    private let cal = TS.calendar

    /// Duration of an interval in whole minutes (sidesteps Double/optional comparison noise).
    private func mins(_ interval: DateInterval?) -> Int? { interval.map { Int($0.duration / 60) } }

    @Test func timedJobOccupiesOnlyItsWindow() {
        let job = TS.job(start: TS.day(2026, 6, 1), hour: 10, minutes: 120)   // 10:00–12:00
        let intervals = job.occupiedIntervals(schedule: .standard, calendar: cal)
        #expect(intervals.count == 1)
        #expect(mins(intervals.first) == 120)
    }

    @Test func allDayJobOccupiesTheWholeWorkingDay() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 1), durationDays: 1)   // all-day (default)
        let intervals = job.occupiedIntervals(schedule: .standard, calendar: cal)
        #expect(intervals.count == 1)
        #expect(mins(intervals.first) == 9 * 60)                                  // 8:00–17:00 = 9 hours
    }

    @Test func twoTimedJobsShareADayWithoutBlockingIt() {
        let morning = TS.job(start: TS.day(2026, 6, 1), hour: 9, minutes: 120)    // 9–11
        let afternoon = TS.job(start: TS.day(2026, 6, 1), hour: 13, minutes: 120) // 1–3
        let windows = SchedulingEngine.openings([morning, afternoon], from: TS.day(2026, 6, 1),
                                                schedule: .standard, calendar: cal)
            .compactMap(\.window)
        #expect(windows.count == 3)   // 8–9, 11–1, 3–5
    }
}
