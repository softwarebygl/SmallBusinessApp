//
//  RecurrenceTests.swift
//  GLSmallBusinessTests
//
//  Recurring-job occurrence expansion: the biweekly stride, a weekly series on several weekdays, and
//  the INCLUSIVE end-date condition. The weekly / monthly walks, "after N visits", the end-of-month
//  and leap-day clamps and the one-off pass-through live in CalendarJobsEstimatesCoverageTests
//  (Recurrence date math). Anchored to 2026 (June 1 = Monday) on the harness calendar.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct RecurrenceTests {
    private func range(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> DateInterval {
        DateInterval(start: TS.day(a.0, a.1, a.2), end: TS.day(b.0, b.1, b.2))
    }
    private func count(_ job: ScheduledJob, _ r: DateInterval) -> Int {
        job.occurrenceStartDates(in: r, calendar: TS.calendar).count
    }

    @Test func biweekly() {
        let j = TS.job(start: TS.day(2026, 6, 1), recurrence: .biweekly)          // Jun 1,15,29
        #expect(count(j, range((2026, 6, 1), (2026, 7, 1))) == 3)
    }

    @Test func weeklyMultipleWeekdays() {
        let monWed = (1 << (2 - 1)) | (1 << (4 - 1))            // Mon + Wed
        let j = TS.job(start: TS.day(2026, 6, 1), recurrence: .weekly, weekdayMask: monWed)
        // Jun 1(Mon),3(Wed),8,10,15 within [Jun 1, Jun 16]
        #expect(count(j, range((2026, 6, 1), (2026, 6, 16))) == 5)
    }

    @Test func endsOnDate() {
        // The end date is inclusive: a series ending ON Jun 15 still visits that day.
        let j = TS.job(start: TS.day(2026, 6, 1), recurrence: .weekly, recurrenceEnd: TS.day(2026, 6, 15))  // Jun 1,8,15
        #expect(count(j, range((2026, 6, 1), (2026, 12, 1))) == 3)
    }
}
