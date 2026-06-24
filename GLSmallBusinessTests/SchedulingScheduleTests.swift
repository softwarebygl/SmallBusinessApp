//
//  SchedulingScheduleTests.swift
//  GLSmallBusinessTests
//
//  The schedule-aware scheduling engine (workdays + holidays + vacation): occupied days that skip
//  holidays, the "Next clear date" tail, and the bounded gaps. Anchored to 2026 (June 1 = Monday,
//  Juneteenth = Fri June 19).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct SchedulingScheduleTests {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func occupiedDaysSkipsEnabledHoliday() {
        let job = ScheduledJob(startDate: date(2026, 6, 15), durationDays: 5)   // Mon June 15
        let days = job.occupiedDays(schedule: .standard)
        #expect(days.count == 5)
        #expect(!days.contains { cal.isDate($0, inSameDayAs: date(2026, 6, 19)) })  // Juneteenth skipped
        #expect(days.contains { cal.isDate($0, inSameDayAs: date(2026, 6, 22)) })   // pushed to next Monday
    }

    @Test func nextClearDateIsAfterTheLastBookedDay() {
        let job = ScheduledJob(startDate: date(2026, 6, 15), durationDays: 1)   // Mon
        let clear = SchedulingEngine.nextClearDate([job], from: date(2026, 6, 1), schedule: .standard)
        #expect(cal.isDate(clear, inSameDayAs: date(2026, 6, 16)))              // Tue
    }

    @Test func nextClearDateWithNoJobsIsNextWorkday() {
        let clear = SchedulingEngine.nextClearDate([], from: date(2026, 6, 6), schedule: .standard)  // Sat
        #expect(cal.isDate(clear, inSameDayAs: date(2026, 6, 8)))               // next workday Mon
    }

    @Test func gapsAppearBeforeABookedJob() {
        let job = ScheduledJob(startDate: date(2026, 6, 15), durationDays: 1)
        let gaps = SchedulingEngine.gaps([job], from: date(2026, 6, 1), schedule: .standard)
        #expect(!gaps.isEmpty)
        #expect(cal.isDate(gaps.first!.start, inSameDayAs: date(2026, 6, 1)))
    }

    @Test func maskBridgeDrivesWorkdays() {
        // Saturdays-only mask via the bridge → Saturday works, Monday doesn't.
        let satOnly = 1 << 6   // bit 6 = Saturday
        let schedule = WorkSchedule.standard.applyingWeekdayMask(satOnly)
        #expect(WorkCalendar.isWorkday(date(2026, 6, 6), schedule: schedule))    // Saturday
        #expect(!WorkCalendar.isWorkday(date(2026, 6, 8), schedule: schedule))   // Monday
    }
}
