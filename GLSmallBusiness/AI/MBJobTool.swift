//
//  MBJobTool.swift
//  GLSmallBusiness — AI
//
//  `save_job`: book a job (no id) or change one (with id) — through `JobService` (and
//  `ProjectService` for the project a job sits in), the same saves the Job form and the Schedule
//  Job sheet run (law 58).
//
//  Overlaps are a warning, never a refusal (contract §5): the job is booked and every existing
//  booking it shares time with comes back in `overlaps`, so the assistant can mention it — exactly
//  what the form's "Schedule anyway?" leaves the person to decide.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBSaveJobTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        if args.string("id") != nil { return edit(args, store) }
        return book(args, store)
    }

    // MARK: Booking

    private func book(_ args: MBArguments, _ store: ModelContext) -> GLAIToolOutcome {
        let value = MBValue(calendar: env.calendar)
        let source: ScheduleJobSource?
        switch sourceFor(args, store) {
        case .outcome(let outcome): return outcome
        case .value(let found): source = found
        }
        var customer: Customer?
        switch source {
        case .estimate(let estimate): customer = estimate.customer
        case .invoice(let invoice): customer = invoice.customer
        case nil: break
        }
        if source == nil {
            guard let id = args.string("customer_id") else {
                return MBToolFailure.invalid(
                    "A new job needs customer_id, or from_estimate_id / from_invoice_id to book it from a document.")
            }
            guard let found = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return MBToolFailure.notFound(.customer)
            }
            customer = found
        }
        guard let customer, !customer.isDeleted else { return MBToolFailure.domain(.customerRequired) }

        // Resolved BEFORE the booking: a project id the model half-remembered must refuse while
        // nothing has been written, never after a job is already on the calendar.
        let project: Project?
        switch resolveProject(args, store) {
        case .outcome(let outcome): return outcome
        case .value(let found): project = found
        }

        var draft = JobDraft(startDate: env.calendar.startOfDay(for: env.now()))
        switch patched(draft, args, value) {
        case .outcome(let outcome): return outcome
        case .value(let updated): draft = updated
        }

        let job: ScheduledJob
        do {
            if let source {
                // The sheet's door: title and customer come from the document, all-day, no repeats.
                job = try JobService.schedule(from: source, start: draft.startDate,
                                              durationDays: draft.durationDays, notes: draft.notes,
                                              in: store, subscription: env.subscription())
                // Anything else the model asked for is a plain edit on top, as a person would do.
                if needsEditAfterScheduling(args) {
                    var afterDraft = JobDraft(job)
                    switch patched(afterDraft, args, value) {
                    case .outcome(let outcome): return outcome
                    case .value(let updated): afterDraft = updated
                    }
                    try JobService.update(job, with: afterDraft, origin: .tool, in: store,
                                          calendar: env.calendar, subscription: env.subscription())
                }
            } else {
                job = try JobService.create(draft, for: customer, origin: .tool, in: store,
                                            calendar: env.calendar, subscription: env.subscription())
            }
        } catch {
            return MBToolFailure.unexpected(error)
        }

        let projectProblem = args.has("project_id") ? assignProject(project, to: job, store) : nil
        let id = MBIDs.id(job, env)
        let ref = MBWrite.ref(.job, id)
        env.ledger.note(id, MBFingerprint.of(job))
        let title = job.displayTitle
        return .result(output(job, store: store, projectProblem: projectProblem),
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.job,
                                               title: MBWriteStrings.jobBooked,
                                               detail: detail(job), record: ref)],
                       undo: undoCreate(ref, title: title, env: env))
    }

    /// Did the model ask for anything the Schedule Job sheet doesn't set itself?
    private func needsEditAfterScheduling(_ args: MBArguments) -> Bool {
        ["title", "all_day", "start_time", "duration_minutes", "repeats", "repeat_weekdays",
         "repeat_until", "repeat_count", "agreed_price", "service_address"].contains { args.has($0) }
    }

    private func sourceFor(_ args: MBArguments, _ store: ModelContext) -> MBStep<ScheduleJobSource?> {
        if let id = args.string("from_estimate_id") {
            guard let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.estimate))
            }
            guard estimate.status == .accepted else {
                return .outcome(MBToolFailure.invalid(
                    "Only an accepted estimate can be scheduled. Ask whether the customer accepted it, then set_status accepted first."))
            }
            return .value(.estimate(estimate))
        }
        if let id = args.string("from_invoice_id") {
            guard let invoice = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.invoice))
            }
            return .value(.invoice(invoice))
        }
        return .value(nil)
    }

    // MARK: Editing

    private func edit(_ args: MBArguments, _ store: ModelContext) -> GLAIToolOutcome {
        let value = MBValue(calendar: env.calendar)
        guard let id = args.string("id"),
              let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
            return MBToolFailure.notFound(.job)
        }
        let recordID = MBIDs.id(job, env)
        let ref = MBWrite.ref(.job, recordID)
        if args.has("customer_id"), let wanted = args.string("customer_id"),
           wanted != job.customer.map({ MBIDs.id($0, env) }) {
            return MBToolFailure.invalid("A job's customer can't be changed. Book a new job instead.")
        }
        let before = JobDraft(job)
        let beforeProject = job.project.map { MBIDs.id($0, env) }
        let draft: JobDraft
        switch patched(before, args, value) {
        case .outcome(let outcome): return outcome
        case .value(let updated): draft = updated
        }
        // Resolved before the write, so a bad project id refuses while nothing has changed.
        let project: Project?
        switch resolveProject(args, store) {
        case .outcome(let outcome): return outcome
        case .value(let found): project = found
        }
        do {
            try JobService.update(job, with: draft, origin: .tool, in: store, calendar: env.calendar,
                                  subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        let projectProblem = args.has("project_id") ? assignProject(project, to: job, store) : nil
        env.ledger.note(recordID, MBFingerprint.of(job))
        let token = env.ledger.stash(.job(before, projectID: beforeProject))
        return .result(output(job, store: store, projectProblem: projectProblem),
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.job,
                                               title: MBWriteStrings.jobUpdated,
                                               detail: detail(job), record: ref)],
                       undo: undoEdit(ref, title: job.displayTitle, token: token, env: env))
    }

    // MARK: The draft

    private func patched(_ draft: JobDraft, _ args: MBArguments, _ value: MBValue) -> MBStep<JobDraft> {
        var draft = draft
        if let title = args.json["title"]?.stringValue { draft.title = title }
        if let notes = args.json["notes"]?.stringValue { draft.notes = notes }
        if args.has("start_date") {
            guard let day = value.parseDay(args.string("start_date")) else {
                return .outcome(MBToolFailure.invalid("start_date must be a date, YYYY-MM-DD."))
            }
            draft.startDate = day
        }
        if let allDay = args.bool("all_day") { draft.isAllDay = allDay }
        if let days = args.int("duration_days") { draft.durationDays = max(1, min(60, days)) }
        if args.has("start_time") {
            guard let moment = Self.moment(args.string("start_time")) else {
                return .outcome(MBToolFailure.invalid("start_time must be an ISO 8601 date-time with an offset."))
            }
            draft.startTime = moment
            draft.isAllDay = args.bool("all_day") ?? false
            if !args.has("start_date") { draft.startDate = env.calendar.startOfDay(for: moment) }
        }
        if let minutes = args.int("duration_minutes") { draft.durationMinutes = max(30, min(600, minutes)) }
        if args.has("agreed_price") {
            draft.agreedPrice = args.isNull("agreed_price") ? nil : args.money("agreed_price")
        }
        draft.serviceAddress = MBWriteValue.address(draft.serviceAddress, patch: args.object("service_address"))
        switch recurrence(draft, args, value) {
        case .outcome(let outcome): return .outcome(outcome)
        case .value(let updated): draft = updated
        }
        return .value(draft)
    }

    /// The Repeats section: none clears it; weekly and every-2-weeks take their weekdays; the end
    /// is a last day, a number of visits, or never.
    private func recurrence(_ draft: JobDraft, _ args: MBArguments, _ value: MBValue) -> MBStep<JobDraft> {
        var draft = draft
        let touchesRecurrence = ["repeats", "repeat_weekdays", "repeat_until", "repeat_count"]
            .contains { args.has($0) }
        guard touchesRecurrence else { return .value(draft) }
        if let raw = args.string("repeats"), raw == "none" {
            draft.recurrence = nil
            return .value(draft)
        }
        var rule = draft.recurrence ?? JobRecurrence(frequency: .weekly)
        if args.has("repeats") {
            guard let frequency = args.raw("repeats", RecurrenceFrequency.self) else {
                return .outcome(MBToolFailure.invalid("repeats must be none, weekly, biweekly or monthly."))
            }
            rule.frequency = frequency
        }
        let weekdays = args.strings("repeat_weekdays")
        if !weekdays.isEmpty {
            var mask = 0
            for day in weekdays {
                guard let index = Self.weekdayNames.firstIndex(of: day) else {
                    return .outcome(MBToolFailure.invalid("repeat_weekdays takes weekday names, e.g. monday."))
                }
                mask |= 1 << index
            }
            rule.weekdayMask = mask
        }
        if args.has("repeat_until") {
            guard let day = value.parseDay(args.string("repeat_until")) else {
                return .outcome(MBToolFailure.invalid("repeat_until must be a date, YYYY-MM-DD."))
            }
            rule.end = .onDate(day)
        } else if let count = args.int("repeat_count") {
            rule.end = count > 0 ? .afterVisits(min(365, count)) : .never
        }
        draft.recurrence = rule
        return .value(draft)
    }

    /// The project `project_id` names (nil = take the job out), looked up with NOTHING written yet.
    private func resolveProject(_ args: MBArguments, _ store: ModelContext) -> MBStep<Project?> {
        guard args.has("project_id"), !args.isNull("project_id") else { return .value(nil) }
        guard let id = args.string("project_id") else {
            return .outcome(MBToolFailure.invalid("project_id must be a project id, or null to take the job out."))
        }
        guard let found = MBRecordLookup.record(.project, id: id, as: Project.self, in: store) else {
            return .outcome(MBToolFailure.notFound(.project))
        }
        return .value(found)
    }

    /// Files the (already saved) job into its project. The job is real either way, so a refusal
    /// here is reported ALONGSIDE the booking — never instead of it, which would tell the person
    /// nothing happened while a job sits on their calendar.
    private func assignProject(_ project: Project?, to job: ScheduledJob, _ store: ModelContext) -> String? {
        do {
            try ProjectService.assign(job, to: project, in: store, subscription: env.subscription())
            return nil
        } catch let error as DomainError {
            return GLAIStrings.english(error.personReason)
        } catch {
            return "It couldn't be filed under that project."
        }
    }

    /// ISO 8601 with an offset (`2026-09-21T14:00:00-04:00`), as the manifest says.
    static func moment(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    // MARK: Output

    /// The booking, plus every existing job it shares time with — a warning, never a refusal.
    private func output(_ job: ScheduledJob, store: ModelContext, projectProblem: String? = nil) -> GLAIJSON {
        let dto = MBRecordDTO(env: env, context: store)
        let value = MBValue(calendar: env.calendar)
        let proposal = JobService.proposal(from: JobDraft(job), calendar: env.calendar)
        let overlaps = JobScheduling.overlaps(for: proposal, excluding: job, in: store,
                                              legacyMask: env.legacyMask(), rule: .full,
                                              calendar: env.calendar)
        let rows = overlaps.prefix(10).map { overlap -> GLAIJSON in
            [
                "id": .string(MBIDs.id(overlap.job, env)),
                "title": value.text(overlap.job.displayTitle, limit: 120),
                "day": value.day(overlap.day),
            ]
        }
        var result: [String: GLAIJSON] = ["ok": true, "job": dto.row(job), "overlaps": .array(rows)]
        if let projectProblem {
            result["project_not_set"] = true
            result["message"] = .string("The job is saved, but it couldn't be put in that project. \(projectProblem) Tell the user that part didn't take.")
        }
        return .object(result)
    }

    private func detail(_ job: ScheduledJob) -> String {
        let value = MBValue(calendar: env.calendar)
        return "\(job.displayTitle) · \(value.dayString(job.startDate))"
    }

    // MARK: Undo

    private func undoCreate(_ ref: GLAIRecordRef, title: String, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(job: title), ledger: env.ledger,
                     fingerprint: { MBWrite.job(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let job = MBWrite.job(ref.id, env) else { return MBUndo.recordGone }
            // A job that has picked up invoices, receipts or files since is kept.
            guard job.liveRows(job.billingInvoices).isEmpty, job.liveRows(job.receipts).isEmpty,
                  job.liveRows(job.attachments).isEmpty else {
                return .failed(MBWriteStrings.undoKeptHasRecords)
            }
            let label = job.displayTitle
            do {
                try DeletionService.delete([.job(job)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.job, MBWriteStrings.deleted(.job),
                                   detail: label, record: nil)
        }
    }

    private func undoEdit(_ ref: GLAIRecordRef, title: String, token: UUID, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(job: title), ledger: env.ledger,
                     fingerprint: { MBWrite.job(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let job = MBWrite.job(ref.id, env),
                  case .job(let before, let projectID)? = env.ledger.snapshot(token) else {
                return MBUndo.recordGone
            }
            do {
                // `.screen` on the way back: every value here is the job's own stored one.
                try JobService.update(job, with: before, origin: .screen, in: store, calendar: env.calendar,
                                      subscription: env.subscription())
                let project = projectID.flatMap { MBWrite.project($0, env) }
                if project?.persistentModelID != job.project?.persistentModelID {
                    try ProjectService.assign(job, to: project, in: store, subscription: env.subscription())
                }
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(ref.id, MBFingerprint.of(job))
            return MBUndo.reverted(.updated, MBWriteSymbol.job, MBWriteStrings.jobRestored,
                                   detail: job.displayTitle, record: ref)
        }
    }
}
