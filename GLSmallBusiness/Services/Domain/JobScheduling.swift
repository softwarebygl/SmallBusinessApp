//
//  JobScheduling.swift
//  GLSmallBusiness
//
//  The schedule's read side, out of the views: the "does this double-book?" check the Job form and
//  Schedule Job sheet both ask before saving, and the Calendar's "what's on day X / what's coming /
//  next opening / next clear date" answers. `SchedulingEngine` stays the engine; this is the one
//  place that decides which jobs, which window and which schedule it is fed, so the calendar, the
//  forms and (later) the assistant all read the same answer.
//
//  Reads only — nothing here writes, so nothing here is gated.
//

import Foundation
import SwiftData

/// One existing booking a proposed job would share time with.
struct JobOverlap: Identifiable {
    /// The stored job (for a repeating job, the series — not the throwaway occurrence copy).
    let job: ScheduledJob
    /// The day the two collide on (the first, when they collide on several).
    let day: Date
    var id: PersistentIdentifier { job.persistentModelID }
}

/// Which "does this double-book?" question is asked. There is one: the Job form, the Schedule Job
/// sheet and a tool all ask `.full` (owner ruling 2026-09-22 — the form's old rule missed a booking
/// that started before the proposal's day, and the sheet's flagged any shared workday whatever the
/// times). Kept as a type so call sites name the question they ask.
enum JobOverlapRule {
    /// Occupied time windows (all-day jobs fill the working hours, timed jobs only their window),
    /// with existing bookings expanded from 120 days back (so a long booking that started earlier
    /// still counts) through 90 days ahead or the proposal's whole span.
    case full
}

@MainActor
enum JobScheduling {

    /// How far back existing bookings are expanded, so a long occurrence that STARTS before the
    /// proposal but runs into it still counts (`SchedulingEngine.expand` filters by start date).
    static let lookbackDays = 120
    /// How far ahead a proposal (and its repeats) is checked.
    static let lookaheadDays = 90

    /// The existing jobs `proposal` would overlap under `rule`, one entry per job, soonest first.
    /// Repeating jobs, the proposal's own and the existing ones, are expanded into their
    /// occurrences first. `excluding` leaves out the job being edited.
    ///
    /// A warning, never a refusal: the screens ask "Schedule anyway?", a tool books and reports.
    static func overlaps(for proposal: ScheduledJob, among jobs: [ScheduledJob],
                         excluding editing: ScheduledJob? = nil, schedule: WorkSchedule,
                         rule: JobOverlapRule = .full,
                         calendar: Calendar = .current) -> [JobOverlap] {
        let others = jobs.filter { $0.persistentModelID != editing?.persistentModelID && !$0.isDeleted }
        switch rule {
        case .full:
            let start = calendar.startOfDay(for: proposal.startDate)
            let span = proposal.occupiedDays(schedule: schedule, calendar: calendar).count
            let range = DateInterval(
                start: calendar.date(byAdding: .day, value: -lookbackDays, to: start) ?? start,
                end: calendar.date(byAdding: .day, value: max(lookaheadDays, span + 1), to: start) ?? start)
            return intersectingWindows(proposal, others, in: range, schedule: schedule, calendar: calendar)
        }
    }

    /// `overlaps` for everything in the store, with the owner's effective schedule.
    static func overlaps(for proposal: ScheduledJob, excluding editing: ScheduledJob? = nil,
                         in context: ModelContext, legacyMask: Int, rule: JobOverlapRule = .full,
                         calendar: Calendar = .current) -> [JobOverlap] {
        let jobs = (try? context.fetch(FetchDescriptor<ScheduledJob>())) ?? []
        return overlaps(for: proposal, among: jobs, excluding: editing,
                        schedule: ScheduleQueries.schedule(in: context, legacyMask: legacyMask),
                        rule: rule, calendar: calendar)
    }

    private static func intersectingWindows(_ proposal: ScheduledJob, _ jobs: [ScheduledJob],
                                            in range: DateInterval, schedule: WorkSchedule,
                                            calendar: Calendar) -> [JobOverlap] {
        let proposed = SchedulingEngine.expand([proposal], in: range, calendar: calendar)
            .flatMap { $0.occupiedIntervals(schedule: schedule, calendar: calendar) }
        guard !proposed.isEmpty else { return [] }
        var result: [JobOverlap] = []
        for job in jobs {
            let intervals = SchedulingEngine.expand([job], in: range, calendar: calendar)
                .flatMap { $0.occupiedIntervals(schedule: schedule, calendar: calendar) }
            let hits = intervals.filter { interval in proposed.contains { $0.intersects(interval) } }
            if let first = hits.map(\.start).min() {
                result.append(JobOverlap(job: job, day: calendar.startOfDay(for: first)))
            }
        }
        return result.sorted { $0.day < $1.day }
    }
}

/// The Calendar's answers as plain functions: fed the jobs and the schedule the screen already
/// has (so a view keeps its @Query), or fetched from a context (for a tool).
@MainActor
enum ScheduleQueries {

    /// Default length of "what's coming up".
    nonisolated static let upcomingLimit = 12

    /// The owner's effective schedule: the saved one, else the standard week under the legacy
    /// workdays mask.
    static func schedule(in context: ModelContext, legacyMask: Int) -> WorkSchedule {
        effectiveWorkSchedule(try? context.fetch(FetchDescriptor<BusinessProfile>()).first,
                              legacyMask: legacyMask)
    }

    /// The window repeating jobs are materialized over: a month back, a year forward.
    static func horizon(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -31, to: today) ?? now
        let end = calendar.date(byAdding: .day, value: 366, to: start) ?? now
        return DateInterval(start: start, end: end)
    }

    /// Every job as the calendar shows it — repeating series expanded into concrete occurrences.
    static func expanded(_ jobs: [ScheduledJob], in horizon: DateInterval,
                         calendar: Calendar = .current) -> [ScheduledJob] {
        #if DEBUG
        expansionCount += 1
        #endif
        return SchedulingEngine.expand(jobs, in: horizon, calendar: calendar)
    }

    #if DEBUG
    /// How many times `expanded` has run (tests: one Calendar render expands once).
    static private(set) var expansionCount = 0
    #endif

    /// The stored job a calendar row opens: for an occurrence copy, the series it was made from
    /// (the copy itself was never inserted, so a detail screen would call it removed). When that
    /// series is gone from `stored`, the copy comes back as is and the detail screen says so.
    static func storedJob(for job: ScheduledJob, among stored: [ScheduledJob]) -> ScheduledJob {
        guard let sourceID = job.occurrenceSourceID else { return job }
        return stored.first { $0.persistentModelID == sourceID } ?? job
    }

    /// Each day → the jobs on it (every workday a job occupies), earliest start first.
    static func jobsByDay(_ expanded: [ScheduledJob], schedule: WorkSchedule,
                          calendar: Calendar = .current) -> [Date: [ScheduledJob]] {
        var map: [Date: [ScheduledJob]] = [:]
        for job in expanded {
            for day in job.occupiedDays(schedule: schedule, calendar: calendar) {
                map[day, default: []].append(job)
            }
        }
        return map.mapValues { $0.sorted { $0.startDate < $1.startDate } }
    }

    /// What's on `day`.
    static func jobs(on day: Date, _ expanded: [ScheduledJob], schedule: WorkSchedule,
                     calendar: Calendar = .current) -> [ScheduledJob] {
        jobsByDay(expanded, schedule: schedule, calendar: calendar)[calendar.startOfDay(for: day)] ?? []
    }

    /// The agenda: jobs not yet finished (last day today or later), soonest first.
    static func upcoming(_ expanded: [ScheduledJob], schedule: WorkSchedule, now: Date = .now,
                         limit: Int = upcomingLimit, calendar: Calendar = .current) -> [ScheduledJob] {
        let today = calendar.startOfDay(for: now)
        return Array(expanded
            .filter { $0.endDay(schedule: schedule, calendar: calendar) >= today }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit))
    }

    /// The bounded openings between booked work (full free days and gaps inside partly booked
    /// days). The first is the banner's "Next available".
    static func openings(_ expanded: [ScheduledJob], schedule: WorkSchedule, from: Date = .now,
                         calendar: Calendar = .current) -> [Opening] {
        SchedulingEngine.openings(expanded, from: from, schedule: schedule, calendar: calendar)
    }

    /// The first workday after the last booked day — the banner's "Next clear date".
    static func clearDate(_ expanded: [ScheduledJob], schedule: WorkSchedule, from: Date = .now,
                          calendar: Calendar = .current) -> Date {
        SchedulingEngine.nextClearDate(expanded, from: from, schedule: schedule, calendar: calendar)
    }

    /// The earliest free workday on or after `from`.
    static func nextAvailable(_ expanded: [ScheduledJob], schedule: WorkSchedule, from: Date = .now,
                              calendar: Calendar = .current) -> Date {
        SchedulingEngine.nextAvailable(expanded, from: from, schedule: schedule, calendar: calendar)
    }

    /// True when some series repeats forever (the banner then says "Ongoing").
    static func hasOpenEndedRecurrence(_ jobs: [ScheduledJob]) -> Bool {
        jobs.contains { $0.isOpenEndedRecurrence }
    }

    /// Every stored job, expanded over the default horizon — the tool-side entry point.
    static func expandedJobs(in context: ModelContext, now: Date = .now,
                             calendar: Calendar = .current) -> [ScheduledJob] {
        let jobs = (try? context.fetch(FetchDescriptor<ScheduledJob>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
        return expanded(jobs, in: horizon(now: now, calendar: calendar), calendar: calendar)
    }
}

/// The Calendar's expansion, kept between renders. A body reads the expanded jobs many times
/// (grid, banner, agenda, openings), and each `ScheduleQueries.expanded` call makes a new @Model
/// copy for every occurrence over a year — 8 weekly clients was about 8,000 allocations per render
/// (QA F90). This answers from the last expansion until the jobs' change token moves. Held in a
/// view's @State: a plain class, so filling it inside `body` never invalidates the view.
@MainActor
final class ScheduleExpansionCache {
    private var key: ScheduleExpansionKey?
    private var value: [ScheduledJob] = []

    func expanded(_ jobs: [ScheduledJob], in horizon: DateInterval,
                  calendar: Calendar = .current) -> [ScheduledJob] {
        let current = ScheduleExpansionKey(jobs, horizon: horizon, calendar: calendar)
        if current != key {
            value = ScheduleQueries.expanded(jobs, in: horizon, calendar: calendar)
            key = current
        }
        return value
    }
}

/// The jobs' change token: everything an expansion reads (which jobs, their schedule and
/// recurrence, and what an occurrence copy carries), plus the window and the calendar.
struct ScheduleExpansionKey: Hashable {
    private struct Job: Hashable {
        let id: PersistentIdentifier
        let title: String
        let customer: String
        let notes: String
        let start: Date
        let durationDays: Int
        let isAllDay: Bool
        let startTime: Date?
        let durationMinutes: Int?
        let address: [String]
        let frequency: String
        let weekdayMask: Int
        let endDate: Date?
        let count: Int
    }
    private let jobs: [Job]
    private let horizon: DateInterval
    private let calendar: Calendar

    init(_ jobs: [ScheduledJob], horizon: DateInterval, calendar: Calendar) {
        self.jobs = jobs.map {
            Job(id: $0.persistentModelID, title: $0.title, customer: $0.displayCustomerName, notes: $0.notes,
                start: $0.startDate, durationDays: $0.durationDays, isAllDay: $0.isAllDay,
                startTime: $0.startTime, durationMinutes: $0.durationMinutes,
                address: [$0.serviceAddressStreet1, $0.serviceAddressStreet2, $0.serviceAddressCity,
                          $0.serviceAddressState, $0.serviceAddressPostalCode],
                frequency: $0.recurrenceFrequencyRaw, weekdayMask: $0.recurrenceWeekdayMask,
                endDate: $0.recurrenceEndDate, count: $0.recurrenceCount)
        }
        self.horizon = horizon
        self.calendar = calendar
    }
}
