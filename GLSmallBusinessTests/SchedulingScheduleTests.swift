//
//  SchedulingScheduleTests.swift
//  GLSmallBusinessTests
//
//  The schedule-aware scheduling engine (workdays + holidays + vacation): occupied days that skip an
//  enabled holiday, the bounded gaps, and the legacy-mask bridge. The "Next clear date" rules live in
//  CalendarJobsEstimatesCoverageTests (Openings / clear date). Anchored to 2026 (June 1 = Monday,
//  Juneteenth = Fri June 19) on the harness calendar.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct SchedulingScheduleTests {
    private let cal = TS.calendar

    @Test func occupiedDaysSkipsEnabledHoliday() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 15), durationDays: 5)   // Mon June 15
        let days = job.occupiedDays(schedule: .standard, calendar: cal)
        #expect(days.count == 5)
        #expect(!days.contains { cal.isDate($0, inSameDayAs: TS.day(2026, 6, 19)) })  // Juneteenth skipped
        #expect(days.contains { cal.isDate($0, inSameDayAs: TS.day(2026, 6, 22)) })   // pushed to next Monday
    }

    @Test func gapsAppearBeforeABookedJob() {
        let job = ScheduledJob(startDate: TS.day(2026, 6, 15), durationDays: 1)
        let gaps = SchedulingEngine.gaps([job], from: TS.day(2026, 6, 1), schedule: .standard, calendar: cal)
        #expect(!gaps.isEmpty)
        #expect(cal.isDate(gaps.first!.start, inSameDayAs: TS.day(2026, 6, 1)))
    }

    @Test func maskBridgeDrivesWorkdays() {
        // Saturdays-only mask via the bridge → Saturday works, Monday doesn't.
        let satOnly = 1 << 6   // bit 6 = Saturday
        let schedule = WorkSchedule.standard.applyingWeekdayMask(satOnly)
        #expect(WorkCalendar.isWorkday(TS.day(2026, 6, 6), schedule: schedule, calendar: cal))    // Saturday
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 6, 8), schedule: schedule, calendar: cal))   // Monday
    }
}
