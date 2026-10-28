//
//  JobService.swift
//  GLSmallBusiness
//
//  Every job write — the Job form (new and edit), Schedule Job (from an estimate or invoice), the
//  job detail screen's status control, and (later) the assistant's tools. Photos and documents are
//  `DocumentService`'s, delete is `DeletionService`'s. One save path, so the form and a tool can never book a job differently.
//
//  Rules kept from the Job form: title and notes trimmed; `startDate` stored as the start of the
//  day; an all-day job clears its time window, a timed job is one day long with at least 30
//  minutes; "no agreed price" is nil (0 is a real, comped price); recurrence written or cleared
//  as a whole. A job made from scratch needs a customer (the model allows none; the form never
//  did). The address goes through the flat columns only (the legacy composite is write-forbidden).
//  Changed here: street2 (Apt/Suite) is carried through instead of blanked — the form has no
//  street2 field, so it passes the job's current value. New here: edits touch only the fields
//  that changed (`setIfChanged`), and every write ends in `saveChanges()`.
//

import Foundation
import SwiftData

/// How a repeating job ends.
nonisolated enum JobRecurrenceEnd: Equatable, Sendable {
    case never
    /// The last day an occurrence may fall on (stored as the start of that day).
    case onDate(Date)
    /// A number of visits (at least 1).
    case afterVisits(Int)
}

/// A job's repeat rule, as the form's Repeats section edits it.
nonisolated struct JobRecurrence: Equatable, Sendable {
    var frequency: RecurrenceFrequency
    /// Bit `weekday - 1` per weekday (weekly and every-2-weeks); 0 = the start date's weekday.
    var weekdayMask: Int = 0
    var end: JobRecurrenceEnd = .never
}

/// A job's schedule, price, address and notes, as a form or a tool supplies them (untrimmed is
/// fine). The customer is chosen on create only — a job's customer never changes afterwards.
nonisolated struct JobDraft: Equatable, Sendable {
    var title = ""
    /// The job's day (any time on it; stored as the start of the day).
    var startDate: Date
    var isAllDay = true
    /// All-day jobs: workdays (at least 1).
    var durationDays = 1
    /// Timed jobs: the hour and minute are read from this (9:00 when nil).
    var startTime: Date?
    /// Timed jobs: the window's length in minutes (at least 30).
    var durationMinutes = 120
    var notes = ""
    /// nil = no agreed price. 0 is a real price (a comped job).
    var agreedPrice: Double?
    var serviceAddress = Address()
    var recurrence: JobRecurrence?

    init(title: String = "", startDate: Date, isAllDay: Bool = true, durationDays: Int = 1,
         startTime: Date? = nil, durationMinutes: Int = 120, notes: String = "",
         agreedPrice: Double? = nil, serviceAddress: Address = Address(),
         recurrence: JobRecurrence? = nil) {
        self.title = title
        self.startDate = startDate
        self.isAllDay = isAllDay
        self.durationDays = durationDays
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.notes = notes
        self.agreedPrice = agreedPrice
        self.serviceAddress = serviceAddress
        self.recurrence = recurrence
    }

    /// The job's current values — the starting point for a partial edit.
    @MainActor
    init(_ job: ScheduledJob) {
        let recurrence = job.recurrenceFrequency.map { frequency in
            JobRecurrence(frequency: frequency, weekdayMask: job.recurrenceWeekdayMask,
                          end: job.recurrenceEndDate.map { .onDate($0) }
                            ?? (job.recurrenceCount > 0 ? .afterVisits(job.recurrenceCount) : .never))
        }
        self.init(title: job.title, startDate: job.startDate, isAllDay: job.isAllDay,
                  durationDays: job.durationDays, startTime: job.startTime,
                  durationMinutes: job.durationMinutes ?? 120, notes: job.notes,
                  agreedPrice: job.agreedPrice, serviceAddress: job.serviceAddress,
                  recurrence: recurrence)
    }
}

/// The source a job is scheduled from — the Schedule Job sheet's two doors.
extension ScheduleJobSource {
    /// The source record, for the liveness check.
    fileprivate var record: any PersistentModel {
        switch self {
        case .estimate(let estimate): estimate
        case .invoice(let invoice): invoice
        }
    }
}

@MainActor
enum JobService {

    // MARK: Create and edit

    /// Books a new job for `customer` (required — the form's rule). Checked against the free
    /// job cap, as every door to the form already is.
    @discardableResult
    static func create(_ draft: JobDraft, for customer: Customer?, origin: WriteOrigin = .tool,
                       in context: ModelContext, calendar: Calendar = .current,
                       subscription: SubscriptionManager? = nil) throws -> ScheduledJob {
        try DomainGate.requireCanCreate(ScheduledJob.self, cap: FreeTier.jobs, operation: .saveJob,
                                        in: context, subscription)
        guard let customer else { throw DomainGate.refusal(.customerRequired, .saveJob) }
        try DomainGate.requireLive(customer, .saveJob)
        try validate(draft, origin)
        let job = ScheduledJob()
        job.customer = customer
        job.customerName = customer.listDisplayName
        context.insert(job)
        apply(draft, to: job, calendar: calendar)
        context.saveChanges()
        return job
    }

    /// Edits a job's schedule, price, address and notes. The customer is not changed.
    static func update(_ job: ScheduledJob, with draft: JobDraft, origin: WriteOrigin = .tool,
                       in context: ModelContext, calendar: Calendar = .current,
                       subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveJob, subscription)
        try DomainGate.requireLive(job, .saveJob)
        try validate(draft, origin)
        apply(draft, to: job, calendar: calendar)
        context.saveChanges()
    }

    /// Books a job from an accepted estimate or an invoice (the Schedule Job sheet): the title,
    /// customer, and service address are copied from the source, it is always all-day and never repeats.
    /// The agreed price is NOT copied and `startDate` is stored as given (not moved to the start of the day).
    @discardableResult
    static func schedule(from source: ScheduleJobSource, start: Date, durationDays: Int,
                         notes: String, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws -> ScheduledJob {
        try DomainGate.requireCanCreate(ScheduledJob.self, cap: FreeTier.jobs, operation: .scheduleJob,
                                        in: context, subscription)
        try DomainGate.requireLive(source.record, .scheduleJob)
        let job = ScheduledJob(title: source.title, customerName: source.customerName,
                               startDate: start, durationDays: durationDays,
                               notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        job.serviceAddress = source.serviceAddress
        // The name snapshot in the Customers list's "Last, First", like every other path (QA L7):
        // the source's own name fields, then the live customer's name when the source has one.
        let listName: String
        switch source {
        case .estimate(let estimate):
            job.estimate = estimate; job.customer = estimate.customer
            listName = ScheduledJob.listName(first: estimate.customerFirstName, last: estimate.customerLastName,
                                             business: estimate.customerBusinessName)
        case .invoice(let invoice):
            job.invoice = invoice; job.customer = invoice.customer
            listName = ScheduledJob.listName(first: invoice.customerFirstName, last: invoice.customerLastName,
                                             business: invoice.customerBusinessName)
        }
        if !listName.isEmpty { job.customerName = listName }
        job.customerName = job.displayCustomerName
        context.insert(job)
        context.saveChanges()
        return job
    }

    // MARK: Status

    /// Scheduled / in progress / completed. Completing stamps `completedAt` once (it starts the
    /// warranty clock, so completing again keeps the first date); any other status clears it.
    static func setStatus(_ status: JobStatus, for job: ScheduledJob, in context: ModelContext,
                          now: Date = .now, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.changeJobStatus, subscription)
        try DomainGate.requireLive(job, .changeJobStatus)
        setIfChanged(job, \.statusRaw, status.rawValue)
        if status == .completed {
            if job.completedAt == nil { job.completedAt = now }
        } else {
            setIfChanged(job, \.completedAt, nil)
        }
        context.saveChanges()
    }

    // MARK: Overlap preview

    /// A throwaway (never inserted) job carrying `draft`'s schedule — what `JobScheduling.overlaps`
    /// tests before a save. Same day and time math as the save itself.
    static func proposal(from draft: JobDraft, calendar: Calendar = .current) -> ScheduledJob {
        let job = ScheduledJob(startDate: calendar.startOfDay(for: draft.startDate))
        applySchedule(draft, to: job, calendar: calendar)
        return job
    }

    // MARK: - Rules

    /// From a tool the agreed price can't be negative. The form's field can't produce one and it
    /// never refused a stored one, so the screen is not checked.
    private static func validate(_ draft: JobDraft, _ origin: WriteOrigin) throws {
        if origin == .tool, let price = draft.agreedPrice {
            try DomainGate.requireNonNegative(price, for: .saveJob)
        }
    }

    /// Writes every draft field onto `job`, touching only what changed.
    private static func apply(_ draft: JobDraft, to job: ScheduledJob, calendar: Calendar) {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        setIfChanged(job, \.title, trim(draft.title))
        setIfChanged(job, \.notes, trim(draft.notes))
        setIfChanged(job, \.agreedPrice, draft.agreedPrice.map(DomainMoney.roundedToCents))   // stored as it shows (law 60)
        applySchedule(draft, to: job, calendar: calendar)
        // The flats behind the `serviceAddress` façade, one by one (the façade writes all five).
        let address = draft.serviceAddress
        setIfChanged(job, \.serviceAddressStreet1, trim(address.street1))
        setIfChanged(job, \.serviceAddressStreet2, trim(address.street2 ?? ""))
        setIfChanged(job, \.serviceAddressCity, trim(address.city))
        setIfChanged(job, \.serviceAddressState, trim(address.state))
        setIfChanged(job, \.serviceAddressPostalCode, trim(address.postalCode))
    }

    /// Day, all-day/timed window and recurrence — shared by the save and the overlap proposal.
    private static func applySchedule(_ draft: JobDraft, to job: ScheduledJob, calendar: Calendar) {
        let day = calendar.startOfDay(for: draft.startDate)
        setIfChanged(job, \.startDate, day)
        setIfChanged(job, \.isAllDay, draft.isAllDay)
        if draft.isAllDay {
            setIfChanged(job, \.durationDays, max(1, draft.durationDays))
            setIfChanged(job, \.startTime, nil)
            setIfChanged(job, \.durationMinutes, nil)
        } else {
            setIfChanged(job, \.durationDays, 1)
            let comps = draft.startTime.map { calendar.dateComponents([.hour, .minute], from: $0) }
            let start = calendar.date(bySettingHour: comps?.hour ?? 9, minute: comps?.minute ?? 0,
                                      second: 0, of: day)
            setIfChanged(job, \.startTime, start)
            setIfChanged(job, \.durationMinutes, max(30, draft.durationMinutes))
        }
        if let recurrence = draft.recurrence {
            setIfChanged(job, \.recurrenceFrequencyRaw, recurrence.frequency.rawValue)
            setIfChanged(job, \.recurrenceWeekdayMask, recurrence.weekdayMask)
            switch recurrence.end {
            case .never:
                setIfChanged(job, \.recurrenceEndDate, nil)
                setIfChanged(job, \.recurrenceCount, 0)
            case .onDate(let end):
                setIfChanged(job, \.recurrenceEndDate, calendar.startOfDay(for: end))
                setIfChanged(job, \.recurrenceCount, 0)
            case .afterVisits(let count):
                setIfChanged(job, \.recurrenceEndDate, nil)
                setIfChanged(job, \.recurrenceCount, max(1, count))
            }
        } else {
            setIfChanged(job, \.recurrenceFrequencyRaw, "")
            setIfChanged(job, \.recurrenceWeekdayMask, 0)
            setIfChanged(job, \.recurrenceEndDate, nil)
            setIfChanged(job, \.recurrenceCount, 0)
        }
    }
}
