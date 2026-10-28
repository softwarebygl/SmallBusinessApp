//
//  JobsCalendarQATests.swift
//  GLSmallBusinessTests
//
//  QA-round guards for the jobs/calendar fixes: the schedule-aware end date every surface now shares
//  diverges from raw-mask math across a holiday, and a backwards vacation range is inert (why the
//  editor clamps From ≤ To). The "recurring occurrences count toward double-booking" guard lives in
//  CalendarJobsEstimatesCoverageTests.overlapDetectionMatchesTheSheetsRule. Anchored to 2026 on the
//  harness calendar (Thanksgiving = Thu Nov 26, Black Friday enabled by default).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct JobsCalendarQATests {
    private let cal = TS.calendar

    /// endDay(schedule:) skips the enabled Thanksgiving/Black Friday closures where the legacy
    /// endDay(mask:) doesn't — the divergence that made job rows / the detail / the form footer
    /// disagree with the calendar before every surface unified on the schedule-aware computation.
    @Test func scheduleAwareEndDateSkipsHolidays() {
        let job = ScheduledJob(startDate: TS.day(2026, 11, 25), durationDays: 3)    // Wed Nov 25
        let maskEnd = job.endDay(mask: SchedulingPrefs.defaultWorkdaysMask, calendar: cal)
        let scheduleEnd = job.endDay(schedule: .standard, calendar: cal)
        #expect(cal.isDate(maskEnd, inSameDayAs: TS.day(2026, 11, 27)))             // raw mask: Wed–Fri
        #expect(cal.isDate(scheduleEnd, inSameDayAs: TS.day(2026, 12, 1)))          // skips Thu+Fri → Tue
    }

    /// A backwards vacation range (To < From) matches no days — why the Work Schedule editor now
    /// clamps From ≤ To instead of accepting a silently inert "time off" entry.
    @Test func backwardsVacationRangeBlocksNothing() {
        var schedule = WorkSchedule.standard
        schedule.vacations = [DateRangeRule(start: TS.day(2026, 8, 10), end: TS.day(2026, 8, 3))]
        #expect(WorkCalendar.isWorkday(TS.day(2026, 8, 5), schedule: schedule, calendar: cal))     // Wed inside the "range"
        schedule.vacations = [DateRangeRule(start: TS.day(2026, 8, 3), end: TS.day(2026, 8, 10))]
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 8, 5), schedule: schedule, calendar: cal))    // ordered range blocks it
    }
}
