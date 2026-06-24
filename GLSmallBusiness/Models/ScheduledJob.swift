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

    /// The optional Project this job is grouped under (invisible until used).
    var project: Project?

    /// Invoices that BILL this job — deposit + draws + final for progress billing. Distinct from the
    /// `invoice` SOURCE link above. Nullify on delete so removing a job keeps its (financial) invoices.
    @Relationship(deleteRule: .nullify, inverse: \Invoice.job)
    var billingInvoices: [Invoice]?

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

// Progress-billing math (touches Invoice/Estimate models, so main-actor — used from views).
extension ScheduledJob {
    /// Non-draft invoices that bill this job (drafts don't count toward billed/collected).
    var activeBillingInvoices: [Invoice] {
        (billingInvoices ?? []).filter { $0.status != .draft }
    }
    var invoicedTotal: Double { activeBillingInvoices.reduce(0) { $0 + $1.total } }
    var amountPaid: Double { activeBillingInvoices.reduce(0) { $0 + $1.amountPaid } }
    var balanceDue: Double { activeBillingInvoices.reduce(0) { $0 + $1.balanceDue } }

    /// What the job is contracted for: the agreed price, else the linked estimate total, else whatever
    /// has been invoiced (so an un-priced job's "fully billed" reduces to a zero-balance check).
    var contractedValue: Double {
        if let price = agreedPrice, price > 0 { return price }
        if let estimateTotal = estimate?.total, estimateTotal > 0 { return estimateTotal }
        return invoicedTotal
    }
    var remainingToInvoice: Double { max(0, contractedValue - invoicedTotal) }

    /// The completion-package gate: billed to 100% of the contracted value AND every invoice collected.
    /// A $0 / fully-comped job satisfies the "billed" clause vacuously.
    var isFullyBilledAndCollected: Bool {
        (contractedValue <= 0.005 || invoicedTotal >= contractedValue - 0.005) && balanceDue <= 0.005
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

    /// For a timed job, "1:00 – 4:00 PM"; empty for an all-day job.
    var timeText: String {
        guard !isAllDay, let start = startTime, let minutes = durationMinutes, minutes > 0 else { return "" }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
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

    /// The day-starts this job occupies, using the full WorkSchedule (skips weekends, holidays,
    /// vacations, and blocked overrides). The schedule-aware counterpart of `occupiedDays(mask:)`.
    func occupiedDays(schedule: WorkSchedule, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: startDate)
        var guardCount = 0
        while days.count < max(1, durationDays), guardCount < 3650 {
            if WorkCalendar.isWorkday(day, schedule: schedule, calendar: calendar) { days.append(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return days
    }

    func endDay(schedule: WorkSchedule, calendar: Calendar = .current) -> Date {
        occupiedDays(schedule: schedule, calendar: calendar).last ?? calendar.startOfDay(for: startDate)
    }

    /// The time interval(s) this job blocks. An all-day job blocks the full working window of each
    /// workday it owns; a timed job blocks only `[startTime, startTime + durationMinutes]` on its day —
    /// so timed jobs can share a day. Used by the interval engine to find intra-day openings.
    func occupiedIntervals(schedule: WorkSchedule, calendar: Calendar = .current) -> [DateInterval] {
        if isAllDay {
            return occupiedDays(schedule: schedule, calendar: calendar).compactMap {
                WorkCalendar.workingHours($0, schedule: schedule, calendar: calendar).first
            }
        }
        guard let start = startTime, let minutes = durationMinutes, minutes > 0 else { return [] }
        return [DateInterval(start: start, duration: TimeInterval(minutes * 60))]
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

/// An opening in the schedule: either a run of fully-free workdays (good for an all-day/multi-day job)
/// or a single-day time window (good for a short timed job, e.g. between two cleanings).
nonisolated struct Opening: Identifiable, Equatable {
    enum Span: Equatable {
        case fullDays(Int)
        case window(DateInterval)
    }
    let start: Date
    let end: Date
    let span: Span
    var id: Date { start }

    /// Workday capacity for a full-day run; 1 for an intra-day window.
    var workdays: Int { if case .fullDays(let n) = span { return n } else { return 1 } }
    var window: DateInterval? { if case .window(let interval) = span { return interval } else { return nil } }
}

nonisolated extension Opening {
    /// The capacity shown next to the date: "Fits 3 workdays" or "4 hr free".
    var capacityText: String {
        if let window {
            return "\(Opening.durationLabel(minutes: Int(window.duration / 60))) free"
        }
        return "Fits \(workdays) \(workdays == 1 ? "workday" : "workdays")"
    }

    static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60, mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours) hr \(mins) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(mins) min"
    }
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

    // MARK: Schedule-aware (workdays + hours + holidays + vacation + overrides)

    static func occupiedDays(_ jobs: [ScheduledJob], schedule: WorkSchedule,
                             calendar: Calendar = .current) -> Set<Date> {
        var set = Set<Date>()
        for job in jobs { set.formUnion(job.occupiedDays(schedule: schedule, calendar: calendar)) }
        return set
    }

    /// The earliest workday on or after `from` that no job occupies — Row 1's "Next available date"
    /// fallback when there are no bounded gaps.
    static func nextAvailable(_ jobs: [ScheduledJob], from: Date = .now, schedule: WorkSchedule,
                              calendar: Calendar = .current) -> Date {
        let occupied = occupiedDays(jobs, schedule: schedule, calendar: calendar)
        var day = calendar.startOfDay(for: from)
        var guardCount = 0
        while guardCount < 3650 {
            if WorkCalendar.isWorkday(day, schedule: schedule, calendar: calendar), !occupied.contains(day) {
                return day
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return calendar.startOfDay(for: from)
    }

    /// Bounded open workday stretches between `from` and `from + horizonDays` — each followed by booked
    /// work (the open-ended tail is availability, not a gap, so it's excluded; that's the "clear date").
    static func gaps(_ jobs: [ScheduledJob], from: Date = .now, horizonDays: Int = 90,
                     schedule: WorkSchedule, calendar: Calendar = .current) -> [ScheduleGap] {
        let occupied = occupiedDays(jobs, schedule: schedule, calendar: calendar)
        let start = calendar.startOfDay(for: from)
        guard let limit = calendar.date(byAdding: .day, value: horizonDays, to: start) else { return [] }

        var gaps: [ScheduleGap] = []
        var runDays: [Date] = []
        var day = start
        while day < limit {
            if WorkCalendar.isWorkday(day, schedule: schedule, calendar: calendar) {
                if occupied.contains(day) {
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
        return gaps
    }

    /// "Next clear date" — the first workday after the LAST booked day (the open-ended runway). When
    /// nothing is booked on/after `from`, it's just the next available workday from `from`.
    static func nextClearDate(_ jobs: [ScheduledJob], from: Date = .now, schedule: WorkSchedule,
                              calendar: Calendar = .current) -> Date {
        let occupied = occupiedDays(jobs, schedule: schedule, calendar: calendar)
        let start = calendar.startOfDay(for: from)
        guard let lastBooked = occupied.filter({ $0 >= start }).max() else {
            return nextAvailable(jobs, from: from, schedule: schedule, calendar: calendar)
        }
        var day = calendar.date(byAdding: .day, value: 1, to: lastBooked) ?? lastBooked
        var guardCount = 0
        while guardCount < 3650 {
            if WorkCalendar.isWorkday(day, schedule: schedule, calendar: calendar), !occupied.contains(day) {
                return day
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return calendar.startOfDay(for: lastBooked)
    }

    // MARK: Interval openings (timed-aware — intra-day windows + multi-day runs)

    /// Bounded openings between booked work within the horizon: runs of fully-free workdays AND the
    /// free windows left on partially-booked days (between timed jobs). The open-ended tail after the
    /// last booked day is excluded — that's the "Next clear date". Windows shorter than `minMinutes`
    /// are dropped.
    static func openings(_ jobs: [ScheduledJob], from: Date = .now, horizonDays: Int = 90,
                         schedule: WorkSchedule, minMinutes: Int = 30,
                         calendar: Calendar = .current) -> [Opening] {
        let occupied = jobs.flatMap { $0.occupiedIntervals(schedule: schedule, calendar: calendar) }
        let start = calendar.startOfDay(for: from)
        guard let limit = calendar.date(byAdding: .day, value: horizonDays, to: start) else { return [] }

        var openings: [Opening] = []
        var fullRun: [Date] = []
        let minSeconds = TimeInterval(minMinutes * 60)
        var day = start
        while day < limit {
            if let work = WorkCalendar.workingHours(day, schedule: schedule, calendar: calendar).first {
                let blocks = occupied.compactMap { work.intersection(with: $0) }.filter { $0.duration > 0 }
                if blocks.isEmpty {
                    fullRun.append(day)                       // a fully-free workday
                } else {
                    flush(&fullRun, into: &openings)          // a booked day closes any free run before it
                    for window in subtract(work, blocks) where window.duration >= minSeconds {
                        openings.append(Opening(start: window.start, end: window.end, span: .window(window)))
                    }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        // A trailing all-free run is the open-ended tail, not a bounded gap — drop it.
        return openings
    }

    private static func flush(_ run: inout [Date], into openings: inout [Opening]) {
        if let first = run.first, let last = run.last {
            openings.append(Opening(start: first, end: last, span: .fullDays(run.count)))
        }
        run.removeAll()
    }

    /// `base` minus the `blocks` that overlap it — the free sub-intervals, in order.
    static func subtract(_ base: DateInterval, _ blocks: [DateInterval]) -> [DateInterval] {
        var free: [DateInterval] = []
        var cursor = base.start
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            let blockStart = max(block.start, base.start)
            let blockEnd = min(block.end, base.end)
            if blockStart > cursor { free.append(DateInterval(start: cursor, end: blockStart)) }
            cursor = max(cursor, blockEnd)
        }
        if cursor < base.end { free.append(DateInterval(start: cursor, end: base.end)) }
        return free
    }
}
