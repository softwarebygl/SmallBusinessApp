//
//  IntervalSchedulingTests.swift
//  GLSmallBusinessTests
//
//  The timed-aware interval engine: a timed job occupies only its window (so days are shared), and
//  `openings` returns intra-day free windows on partial days plus multi-day runs of free workdays.
//  Anchored to 2026 (June 1 = Monday); .standard schedule is Mon–Fri 8:00–17:00.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct IntervalSchedulingTests {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func timed(_ y: Int, _ m: Int, _ d: Int, hour: Int, minutes: Int, lengthMin: Int) -> ScheduledJob {
        let job = ScheduledJob(startDate: date(y, m, d))
        job.isAllDay = false
        job.startTime = cal.date(bySettingHour: hour, minute: minutes, second: 0, of: date(y, m, d))!
        job.durationMinutes = lengthMin
        return job
    }
    /// Duration of an interval in whole minutes (sidesteps Double/optional comparison noise).
    private func mins(_ interval: DateInterval?) -> Int? { interval.map { Int($0.duration / 60) } }

    @Test func timedJobOccupiesOnlyItsWindow() {
        let job = timed(2026, 6, 1, hour: 10, minutes: 0, lengthMin: 120)   // 10:00–12:00
        let intervals = job.occupiedIntervals(schedule: .standard)
        #expect(intervals.count == 1)
        #expect(mins(intervals.first) == 120)
    }

    @Test func allDayJobOccupiesTheWholeWorkingDay() {
        let job = ScheduledJob(startDate: date(2026, 6, 1), durationDays: 1)   // all-day (default)
        let intervals = job.occupiedIntervals(schedule: .standard)
        #expect(intervals.count == 1)
        #expect(mins(intervals.first) == 9 * 60)                               // 8:00–17:00 = 9 hours
    }

    @Test func timedJobLeavesTwoIntradayWindows() {
        // One 10:00–12:00 job in an 8–5 day → free 8–10 and 12–5.
        let job = timed(2026, 6, 1, hour: 10, minutes: 0, lengthMin: 120)
        let windows = SchedulingEngine.openings([job], from: date(2026, 6, 1), schedule: .standard)
            .compactMap(\.window)
        #expect(windows.count == 2)
        #expect(mins(windows.first) == 120)   // 8–10
        #expect(mins(windows.last) == 300)    // 12–5
    }

    @Test func twoTimedJobsShareADayWithoutBlockingIt() {
        let morning = timed(2026, 6, 1, hour: 9, minutes: 0, lengthMin: 120)    // 9–11
        let afternoon = timed(2026, 6, 1, hour: 13, minutes: 0, lengthMin: 120) // 1–3
        let windows = SchedulingEngine.openings([morning, afternoon], from: date(2026, 6, 1), schedule: .standard)
            .compactMap(\.window)
        #expect(windows.count == 3)   // 8–9, 11–1, 3–5
    }

    @Test func allDayJobYieldsAFullDaysRunBeforeIt() {
        let job = ScheduledJob(startDate: date(2026, 6, 15), durationDays: 1)
        let openings = SchedulingEngine.openings([job], from: date(2026, 6, 1), schedule: .standard)
        #expect(openings.first?.workdays == 10)   // Jun 1–5 + 8–12 (weekends skipped)
        #expect(openings.first?.window == nil)    // it's a full-days run, not a window
    }

    @Test func subtractRemovesOverlappingBlocks() {
        let base = DateInterval(start: date(2026, 6, 1).addingTimeInterval(8 * 3600),
                                end: date(2026, 6, 1).addingTimeInterval(17 * 3600))
        let block = DateInterval(start: date(2026, 6, 1).addingTimeInterval(10 * 3600),
                                 end: date(2026, 6, 1).addingTimeInterval(12 * 3600))
        let free = SchedulingEngine.subtract(base, [block])
        #expect(free.count == 2)
        #expect(mins(free.first) == 120)   // 8–10
        #expect(mins(free.last) == 300)    // 12–17
    }
}
