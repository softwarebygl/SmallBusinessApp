//
//  RecurrenceTests.swift
//  GLSmallBusinessTests
//
//  Recurring-job occurrence expansion: weekly / biweekly / monthly, multiple weekdays, and the
//  end conditions (after N visits / on a date). Anchored to 2026 (June 1 = Monday).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct RecurrenceTests {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
    private func range(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> DateInterval {
        DateInterval(start: date(a.0, a.1, a.2), end: date(b.0, b.1, b.2))
    }
    private func job(_ start: Date, freq: RecurrenceFrequency? = nil, mask: Int = 0, count: Int = 0, end: Date? = nil) -> ScheduledJob {
        let job = ScheduledJob(startDate: start)
        job.recurrenceFrequencyRaw = freq?.rawValue ?? ""
        job.recurrenceWeekdayMask = mask
        job.recurrenceCount = count
        job.recurrenceEndDate = end
        return job
    }
    private func count(_ job: ScheduledJob, _ r: DateInterval) -> Int {
        job.occurrenceStartDates(in: r, calendar: cal).count
    }

    @Test func oneOffReturnsItselfInRangeOnly() {
        let j = job(date(2026, 6, 1))
        #expect(count(j, range((2026, 6, 1), (2026, 7, 1))) == 1)
        #expect(count(j, range((2026, 7, 1), (2026, 8, 1))) == 0)
    }

    @Test func weeklySingleWeekday() {
        let j = job(date(2026, 6, 1), freq: .weekly)            // Mondays: Jun 1,8,15,22,29
        #expect(count(j, range((2026, 6, 1), (2026, 7, 1))) == 5)
    }

    @Test func biweekly() {
        let j = job(date(2026, 6, 1), freq: .biweekly)          // Jun 1,15,29
        #expect(count(j, range((2026, 6, 1), (2026, 7, 1))) == 3)
    }

    @Test func weeklyMultipleWeekdays() {
        let monWed = (1 << (2 - 1)) | (1 << (4 - 1))            // Mon + Wed
        let j = job(date(2026, 6, 1), freq: .weekly, mask: monWed)
        // Jun 1(Mon),3(Wed),8,10,15 within [Jun 1, Jun 16]
        #expect(count(j, range((2026, 6, 1), (2026, 6, 16))) == 5)
    }

    @Test func monthly() {
        let j = job(date(2026, 6, 15), freq: .monthly)          // Jun 15, Jul 15, Aug 15
        #expect(count(j, range((2026, 6, 1), (2026, 9, 1))) == 3)
    }

    @Test func endsAfterNVisits() {
        let j = job(date(2026, 6, 1), freq: .weekly, count: 3)  // Jun 1,8,15
        #expect(count(j, range((2026, 6, 1), (2026, 12, 1))) == 3)
    }

    @Test func endsOnDate() {
        let j = job(date(2026, 6, 1), freq: .weekly, end: date(2026, 6, 15))  // Jun 1,8,15
        #expect(count(j, range((2026, 6, 1), (2026, 12, 1))) == 3)
    }
}
