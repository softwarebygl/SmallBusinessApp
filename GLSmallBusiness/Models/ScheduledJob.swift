//
//  ScheduledJob.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Scheduling for the Calendar tab. A ScheduledJob is always created from an accepted estimate or an
//  invoice (never free-form) — it carries a snapshot of the job title + customer plus a link to its
//  source. The SchedulingEngine answers the two things the owner asked for: the next available date
//  and the open gaps between booked work, both computed over the owner's chosen workdays.
//

import Foundation
import SwiftData

// MARK: - Scheduling preferences (device-local, like the appearance settings)

// Pure prefs + calendar math; safe off any actor (SchedulingEngine, already nonisolated, calls in).
nonisolated enum SchedulingPrefs {
    static let workdaysMaskKey = "scheduleWorkdaysMask"
    static let oneJobAtATimeKey = "scheduleOneJobAtATime"

    /// Bit `weekday-1` set = that weekday is a workday (Calendar weekdays are 1=Sun … 7=Sat).
    /// Default is Mon–Fri (weekdays 2–6).
    static let defaultWorkdaysMask = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)   // 62

    static func isWorkday(_ date: Date, mask: Int, calendar: Calendar = .current) -> Bool {
        // A mask of 0 would mean "no workdays" and stall every walk — treat it as the default.
        let m = mask == 0 ? defaultWorkdaysMask : mask
        let weekday = calendar.component(.weekday, from: date)
        return m & (1 << (weekday - 1)) != 0
    }
}

// MARK: - ScheduledJob

@Model
final class ScheduledJob {
    var title: String = ""
    var customerName: String = ""
    var startDate: Date = Date.now
    /// Number of workdays the job occupies (weekends/off-days are skipped per the workdays setting).
    var durationDays: Int = 1
    var notes: String = ""
    var createdAt: Date = Date.now

    // Source — exactly one of these is set (an accepted estimate or an invoice). Nullify on delete so
    // the booking survives on the calendar (with its snapshot) even if the source doc is removed.
    var estimate: Estimate?
    var invoice: Invoice?

    init(title: String = "", customerName: String = "", startDate: Date = .now,
         durationDays: Int = 1, notes: String = "", estimate: Estimate? = nil, invoice: Invoice? = nil) {
        self.title = title
        self.customerName = customerName
        self.startDate = startDate
        self.durationDays = max(1, durationDays)
        self.notes = notes
        self.estimate = estimate
        self.invoice = invoice
    }
}

nonisolated extension ScheduledJob {
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Job") : t
    }

    /// The day-starts this job occupies: the first `durationDays` workdays on or after `startDate`.
    func occupiedDays(mask: Int, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: startDate)
        var guardCount = 0
        while days.count < max(1, durationDays), guardCount < 3650 {
            if SchedulingPrefs.isWorkday(day, mask: mask, calendar: calendar) { days.append(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return days
    }

    /// Last occupied day (for display), or the start day if none.
    func endDay(mask: Int, calendar: Calendar = .current) -> Date {
        occupiedDays(mask: mask, calendar: calendar).last ?? calendar.startOfDay(for: startDate)
    }
}

// MARK: - Scheduling engine (pure logic — next available date + gaps)

/// One open stretch of workdays with no job booked.
nonisolated struct ScheduleGap: Identifiable, Equatable {
    let start: Date
    let end: Date
    let workdays: Int
    var id: Date { start }
}

nonisolated enum SchedulingEngine {
    /// All day-starts occupied by any job.
    static func occupiedDays(_ jobs: [ScheduledJob], mask: Int, calendar: Calendar = .current) -> Set<Date> {
        var set = Set<Date>()
        for job in jobs { set.formUnion(job.occupiedDays(mask: mask, calendar: calendar)) }
        return set
    }

    /// The earliest workday on or after `from` that no job occupies.
    static func nextAvailable(_ jobs: [ScheduledJob], from: Date = .now, mask: Int,
                              calendar: Calendar = .current) -> Date {
        let occupied = occupiedDays(jobs, mask: mask, calendar: calendar)
        var day = calendar.startOfDay(for: from)
        var guardCount = 0
        while guardCount < 3650 {
            if SchedulingPrefs.isWorkday(day, mask: mask, calendar: calendar), !occupied.contains(day) {
                return day
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return calendar.startOfDay(for: from)
    }

    /// Open workday stretches between `from` and `from + horizonDays`, each bounded by booked work that
    /// follows it (the open-ended tail after the last job is availability, not a gap, so it's excluded).
    static func gaps(_ jobs: [ScheduledJob], from: Date = .now, horizonDays: Int = 90, mask: Int,
                     calendar: Calendar = .current) -> [ScheduleGap] {
        let occupied = occupiedDays(jobs, mask: mask, calendar: calendar)
        let start = calendar.startOfDay(for: from)
        guard let limit = calendar.date(byAdding: .day, value: horizonDays, to: start) else { return [] }

        var gaps: [ScheduleGap] = []
        var runDays: [Date] = []
        var day = start
        while day < limit {
            if SchedulingPrefs.isWorkday(day, mask: mask, calendar: calendar) {
                if occupied.contains(day) {
                    // A booked day closes any open run before it → that's a real gap.
                    if let first = runDays.first, let last = runDays.last {
                        gaps.append(ScheduleGap(start: first, end: last, workdays: runDays.count))
                    }
                    runDays.removeAll()
                } else {
                    runDays.append(day)
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        // A trailing open run (no job after it within the horizon) is left out by design.
        return gaps
    }
}
