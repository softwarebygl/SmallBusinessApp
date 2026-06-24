//
//  ScheduledJob.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  A ScheduledJob is the app's first-class Job: the schedulable blueprint of a piece of work. It can be
//  created from scratch (a verbal price / standing approval) or from an accepted estimate or an invoice,
//  which it then links back to. It carries a snapshot of the title + customer, an optional Customer
//  link, a status, and (once finished) a completion date. The SchedulingEngine answers the next
//  available date and the open gaps between booked work, computed over the owner's chosen workdays.
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

// MARK: - Job status

/// The lifecycle of a job. Marking `.completed` stamps `completedAt`, which starts the warranty clock
/// and (in a later phase) unlocks the completion package. Stored as a raw string for CloudKit-safe
/// additive migration.
nonisolated enum JobStatus: String, CaseIterable, Identifiable, Sendable {
    case scheduled
    case inProgress
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scheduled: String(localized: "Scheduled")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Completed")
        }
    }
}

// MARK: - ScheduledJob (the Job)

@Model
final class ScheduledJob {
    var title: String = ""
    var customerName: String = ""
    var startDate: Date = Date.now
    /// Number of workdays the job occupies (weekends/off-days are skipped per the workdays setting).
    var durationDays: Int = 1
    var notes: String = ""
    var createdAt: Date = Date.now

    /// Lifecycle (scheduled / in progress / completed). Read/write via `status`.
    var statusRaw: String = JobStatus.scheduled.rawValue
    /// Set when the job is marked complete — the app's canonical completion date (starts the warranty).
    var completedAt: Date?

    /// Where the work happens. Auto-filled from the customer (or source doc) but editable.
    var serviceAddress: Address = Address()
    /// A single agreed amount for from-scratch jobs that have no line-item breakdown. Optional.
    var agreedPrice: Double?

    /// All-day (project work, day-based via `durationDays`) vs timed (service work, a window on
    /// `startDate`). Defaults to all-day — every legacy booking is day-based. When timed, `startTime`
    /// and `durationMinutes` define the window; the scheduling engine reads those instead of `durationDays`.
    var isAllDay: Bool = true
    var startTime: Date?
    var durationMinutes: Int?

    /// The customer this job is for. Optional + nullify on delete so the `customerName` snapshot below
    /// keeps the booking intact even if the customer is removed (matching the estimate/invoice convention).
    var customer: Customer?

    // Source — optional. Set when the job was created from an accepted estimate or an invoice (and nil
    // for a from-scratch job). Nullify on delete so the booking survives even if the source doc is removed.
    var estimate: Estimate?
    var invoice: Invoice?

    init(title: String = "", customerName: String = "", startDate: Date = .now,
         durationDays: Int = 1, notes: String = "", estimate: Estimate? = nil, invoice: Invoice? = nil,
         customer: Customer? = nil, serviceAddress: Address = Address(), agreedPrice: Double? = nil,
         status: JobStatus = .scheduled) {
        self.title = title
        self.customerName = customerName
        self.startDate = startDate
        self.durationDays = max(1, durationDays)
        self.notes = notes
        self.estimate = estimate
        self.invoice = invoice
        self.customer = customer
        self.serviceAddress = serviceAddress
        self.agreedPrice = agreedPrice
        self.statusRaw = status.rawValue
    }
}

nonisolated extension ScheduledJob {
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Job") : t
    }

    /// Typed accessor over the raw status string.
    var status: JobStatus {
        get { JobStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }

    /// True once the job is created from (or linked to) an estimate or invoice.
    var hasSource: Bool { estimate != nil || invoice != nil }

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
