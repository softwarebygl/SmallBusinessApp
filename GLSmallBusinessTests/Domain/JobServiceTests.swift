//
//  JobServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The job save path shared by the Job form, Schedule Job, the job detail screen, the job lists and
//  the assistant — plus the one overlap check both booking screens ask.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct JobServiceTests {

    private let cal = TS.calendar
    /// Tuesday 15 Sep 2026 — a plain workday under the standard schedule (no holiday near it).
    private var tuesday: Date { TS.day(2026, 9, 15) }

    private func at(_ hour: Int, _ minute: Int = 0, on day: Date) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: Create and edit

    @Test func createAppliesTheFormRulesAndSavesAnID() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let draft = JobDraft(title: "  Tile shower ", startDate: at(15, on: tuesday), durationDays: 3,
                             startTime: at(10, on: tuesday), notes: " grout ", agreedPrice: 0,
                             serviceAddress: Address(street1: " 1 Main ", street2: " Apt 4 ", city: "Miami",
                                                     state: "FL", postalCode: "32301"))
        let job = try DomainState.subscribed.run {
            try JobService.create(draft, for: customer, in: context, calendar: cal)
        }
        #expect(job.title == "Tile shower" && job.notes == "grout")
        #expect(job.customer === customer && job.customerName == customer.listDisplayName)
        #expect(job.startDate == tuesday, "stored as the start of the day")
        #expect(job.isAllDay && job.durationDays == 3 && job.startTime == nil && job.durationMinutes == nil)
        #expect(job.agreedPrice == 0, "0 is a real (comped) price, not 'unset'")
        #expect(job.serviceAddress.street1 == "1 Main" && job.serviceAddress.street2 == "Apt 4")
        #expect(job.recurrenceFrequency == nil)
        #expect(job.syncID != nil && !context.hasChanges, "saved now, not left for autosave")
    }

    @Test func aTimedJobIsOneDayWithAtLeastThirtyMinutes() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let draft = JobDraft(startDate: tuesday, isAllDay: false, durationDays: 5,
                             startTime: at(13, 30, on: TS.day(2020, 1, 1)), durationMinutes: 10)
        let job = try DomainState.subscribed.run { try JobService.create(draft, for: customer, in: context, calendar: cal) }
        #expect(!job.isAllDay && job.durationDays == 1)
        #expect(job.startTime == at(13, 30, on: tuesday), "the hour and minute land on the job's own day")
        #expect(job.durationMinutes == 30)
    }

    @Test func createRefusals() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let draft = JobDraft(startDate: tuesday)
        #expect(DomainState.subscribed.run { domainError { try JobService.create(draft, for: nil, in: context) } }
                == .customerRequired)
        var negative = draft
        negative.agreedPrice = -1
        #expect(DomainState.subscribed.run { domainError { try JobService.create(negative, for: customer, in: context) } }
                == .negativeValue)
        #expect(DomainState.lapsed.run { domainError { try JobService.create(draft, for: customer, in: context) } }
                == .readOnly(operation: "saveJob", lapsed: true))
        #expect(DomainState.offline.run { domainError { try JobService.create(draft, for: customer, in: context) } }
                == .readOnly(operation: "saveJob", lapsed: false))
        #expect(try context.fetchCount(FetchDescriptor<ScheduledJob>()) == 0, "nothing refused was inserted")
        // Sample mode is never read-only, even offline.
        _ = try DomainState.sampleOffline.run { try JobService.create(draft, for: customer, in: context) }
        #expect(try context.fetchCount(FetchDescriptor<ScheduledJob>()) == 1)
        // The form never refused a stored negative price; only a tool is held to ≥ 0.
        let old = try DomainState.subscribed.run { try JobService.create(negative, for: customer, origin: .screen, in: context) }
        #expect(old.agreedPrice == -1)
    }

    @Test func theFreeJobCapApplies() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        for i in 0..<FreeTier.jobs { TS.job("J\(i)", start: tuesday, in: context) }
        context.saveChanges()
        #expect(DomainState.neverSubscribed.run { domainError { try JobService.create(JobDraft(startDate: tuesday), for: customer, in: context) } }
                == .freeLimitReached(operation: "saveJob"))
        _ = try DomainState.subscribed.run { try JobService.create(JobDraft(startDate: tuesday), for: customer, in: context) }
        #expect(try context.fetchCount(FetchDescriptor<ScheduledJob>()) == FreeTier.jobs + 1)
    }

    /// The form has no Apt/Suite field; an edit carries street2 through instead of blanking it.
    @Test func updateKeepsCustomerAndStreet2AndWritesRecurrence() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Deck", start: tuesday, customer: customer, in: context)
        job.serviceAddress = Address(street1: "1 Main", street2: "Suite 9", city: "T", state: "FL", postalCode: "1")
        context.saveChanges()

        var draft = JobDraft(job)
        draft.title = "Deck repair"
        draft.recurrence = JobRecurrence(frequency: .weekly, weekdayMask: 0b0010_1010, end: .afterVisits(0))
        try DomainState.subscribed.run { try JobService.update(job, with: draft, in: context, calendar: cal) }
        #expect(job.title == "Deck repair" && job.customer === customer)
        #expect(job.serviceAddress.street2 == "Suite 9")
        #expect(job.recurrenceFrequency == .weekly && job.recurrenceWeekdayMask == 0b0010_1010)
        #expect(job.recurrenceCount == 1 && job.recurrenceEndDate == nil, "after N visits is at least 1")

        draft.recurrence = JobRecurrence(frequency: .monthly, end: .onDate(at(17, on: TS.day(2026, 12, 1))))
        try DomainState.subscribed.run { try JobService.update(job, with: draft, in: context, calendar: cal) }
        #expect(job.recurrenceEndDate == TS.day(2026, 12, 1) && job.recurrenceCount == 0)

        draft.recurrence = nil
        try DomainState.subscribed.run { try JobService.update(job, with: draft, in: context, calendar: cal) }
        #expect(job.recurrenceFrequencyRaw == "" && job.recurrenceWeekdayMask == 0
                && job.recurrenceEndDate == nil && job.recurrenceCount == 0)
        #expect(!context.hasChanges)
    }

    /// Re-saving the same values writes nothing (setIfChanged): no new updatedAt, no outbox noise.
    @Test func anUnchangedSaveTouchesNothing() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = try DomainState.subscribed.run {
            try JobService.create(JobDraft(title: "A", startDate: tuesday, agreedPrice: 100), for: customer,
                                  in: context, calendar: cal)
        }
        let stamp = job.updatedAt
        try DomainState.subscribed.run { try JobService.update(job, with: JobDraft(job), in: context, calendar: cal) }
        #expect(job.updatedAt == stamp)
    }

    @Test func updateRefusesADeletedJobAndReadOnly() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Gone", start: tuesday, in: context)
        context.saveChanges()
        #expect(DomainState.lapsed.run { domainError { try JobService.update(job, with: JobDraft(job), in: context) } }
                == .readOnly(operation: "saveJob", lapsed: true))
        let draft = JobDraft(job)
        context.delete(job) // GLSYNC-LINT-OK: test setup — simulate a sync pull removing the row
        context.saveChanges()
        #expect(DomainState.subscribed.run { domainError { try JobService.update(job, with: draft, in: context) } }
                == .recordNotFound)
    }

    // MARK: Schedule from a source

    @Test func scheduleFromAnEstimateCopiesTheSnapshotOnly() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(status: .accepted, in: context)
        estimate.jobTitle = "Kitchen"
        estimate.customer = customer
        context.saveChanges()
        let start = at(14, on: tuesday)
        let job = try DomainState.subscribed.run {
            try JobService.schedule(from: .estimate(estimate), start: start, durationDays: 2,
                                    notes: "  bring tile ", in: context)
        }
        #expect(job.title == "Kitchen" && job.estimate === estimate && job.customer === customer)
        #expect(job.startDate == start, "stored as given — the sheet's behavior")
        #expect(job.durationDays == 2 && job.isAllDay && job.notes == "bring tile")
        #expect(job.agreedPrice == nil && job.serviceAddress.isEmpty, "price is not copied; address is empty when source address is empty")
        #expect(job.syncID != nil && !context.hasChanges)

        #expect(DomainState.offline.run { domainError { try JobService.schedule(from: .estimate(estimate), start: start, durationDays: 1, notes: "", in: context) } }
                == .readOnly(operation: "scheduleJob", lapsed: false))
    }

    @Test func scheduleCopiesServiceAddressFromSource() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(status: .accepted, in: context)
        estimate.customer = customer
        estimate.serviceAddress = Address(street1: "742 Evergreen Terrace", city: "Springfield", state: "IL", postalCode: "62704")
        context.saveChanges()

        let job = try DomainState.subscribed.run {
            try JobService.schedule(from: .estimate(estimate), start: tuesday, durationDays: 1, notes: "", in: context)
        }
        #expect(job.serviceAddress.street1 == "742 Evergreen Terrace")
        #expect(job.serviceAddress.city == "Springfield")
    }

    @Test func scheduleFromAnInvoiceAndItsCap() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        context.saveChanges()
        let job = try DomainState.subscribed.run {
            try JobService.schedule(from: .invoice(invoice), start: tuesday, durationDays: 1, notes: "", in: context)
        }
        #expect(job.invoice === invoice)
        for i in 0..<FreeTier.jobs { TS.job("J\(i)", start: tuesday, in: context) }
        context.saveChanges()
        #expect(DomainState.neverSubscribed.run { domainError { try JobService.schedule(from: .invoice(invoice), start: tuesday, durationDays: 1, notes: "", in: context) } }
                == .freeLimitReached(operation: "scheduleJob"))
    }

    // MARK: Status

    @Test func completingStampsOnceAndReopeningClears() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Paint", start: tuesday, in: context)
        context.saveChanges()
        let first = TS.day(2026, 9, 20), later = TS.day(2026, 9, 25)
        try DomainState.subscribed.run {
            try JobService.setStatus(.completed, for: job, in: context, now: first)
            #expect(job.status == .completed && job.completedAt == first)
            try JobService.setStatus(.completed, for: job, in: context, now: later)
            #expect(job.completedAt == first, "the warranty clock keeps its first start")
            try JobService.setStatus(.inProgress, for: job, in: context, now: later)
            #expect(job.status == .inProgress && job.completedAt == nil)
        }
        #expect(!context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { try JobService.setStatus(.completed, for: job, in: context) } }
                == .readOnly(operation: "changeJobStatus", lapsed: true))
        #expect(job.status == .inProgress)
    }

    // MARK: Photos and documents

    @Test func photosAndDocuments() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Bath", start: tuesday, in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            let photos = try DocumentService.attachPhotos([Data([1]), Data([2])], to: .job(job), in: context)
            #expect(job.photos.count == 2 && photos.allSatisfy { $0.syncID != nil })
            #expect(photos.map(\.name) == [mbLoc("Photo \(1)"), mbLoc("Photo \(2)")], "numbered within the record (F13)")
            let doc = try DocumentService.attachDocument(Data([3]), name: "permit.pdf", to: .job(job), in: context)
            #expect(job.documents.map(\.name) == ["permit.pdf"])

            try DocumentService.set(.attachment(doc), data: Data([4]), name: "permit-v2.pdf", in: context)
            #expect(doc.data == Data([4]) && doc.name == "permit-v2.pdf")
            try DocumentService.set(.attachment(doc), data: nil, name: "", in: context)
            #expect(job.documents.isEmpty, "removing the file removes the attachment")

            try DeletionService.delete([.attachment(photos[0])], in: context)
            #expect(job.photos.count == 1)
        }
        #expect(!context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { _ = try DocumentService.attachPhotos([Data([9])], to: .job(job), in: context) } }
                == .readOnly(operation: "addJobAttachment", lapsed: true))
        #expect(DomainState.offline.run { domainError { try DeletionService.delete([.attachment(job.photos[0])], in: context) } }
                == .readOnly(operation: "deleteJobAttachment", lapsed: false))
        #expect(job.photos.count == 1)
    }

    // MARK: Delete

    /// Photos and documents go with the job; receipts and billing invoices stay, unlinked.
    @Test func deleteCascadesAttachmentsAndKeepsMoney() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Roof", start: tuesday, in: context)
        let receipt = TS.receipt(total: 40, category: "Materials", date: tuesday, in: context)
        receipt.job = job
        let invoice = TS.invoice(in: context)
        invoice.job = job
        context.insert(JobAttachment(kind: .photo, name: "Photo", data: Data([1]), job: job))
        context.saveChanges()

        #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.job(job)], in: context) } }
                == .readOnly(operation: "deleteJob", lapsed: true))
        _ = try DomainState.subscribed.run { try DeletionService.delete([.job(job)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<ScheduledJob>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<JobAttachment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1 && receipt.job == nil)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 1 && invoice.job == nil)
        #expect(!context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.job(job)], in: context) } }
                == .recordNotFound)
    }
}

// MARK: - The one overlap check

@MainActor
@Suite(.serialized)
struct JobOverlapTests {

    private let cal = TS.calendar
    private let schedule = WorkSchedule.standard   // Mon–Fri 8–5
    private var tuesday: Date { TS.day(2026, 9, 15) }

    private func proposal(_ draft: JobDraft) -> ScheduledJob { JobService.proposal(from: draft, calendar: cal) }

    @Test func allDayJobsCollideOnASharedWorkday() {
        let existing = TS.job("Existing", start: TS.day(2026, 9, 14), days: 2)   // Mon–Tue
        let hit = JobScheduling.overlaps(for: proposal(JobDraft(startDate: tuesday)), among: [existing],
                                         schedule: schedule, calendar: cal)
        #expect(hit.map(\.job) == [existing] && hit.first?.day == tuesday)
        let miss = JobScheduling.overlaps(for: proposal(JobDraft(startDate: TS.day(2026, 9, 16))), among: [existing],
                                          schedule: schedule, calendar: cal)
        #expect(miss.isEmpty)
    }

    @Test func timedJobsCollideOnlyWhenTheWindowsMeet() {
        let morning = TS.job("Morning", start: tuesday, hour: 9, minutes: 60)   // 9–10
        let afternoon = JobDraft(startDate: tuesday, isAllDay: false,
                                 startTime: cal.date(bySettingHour: 13, minute: 0, second: 0, of: tuesday),
                                 durationMinutes: 60)
        #expect(JobScheduling.overlaps(for: proposal(afternoon), among: [morning], schedule: schedule, calendar: cal).isEmpty)
        var overlapping = afternoon
        overlapping.startTime = cal.date(bySettingHour: 9, minute: 30, second: 0, of: tuesday)
        #expect(JobScheduling.overlaps(for: proposal(overlapping), among: [morning], schedule: schedule, calendar: cal).count == 1)
        // An all-day proposal blocks the whole working day, so it meets the timed job.
        #expect(JobScheduling.overlaps(for: proposal(JobDraft(startDate: tuesday)), among: [morning],
                                       schedule: schedule, calendar: cal).count == 1)
    }

    /// A weekly series blocks its future dates; a long job that started weeks before still counts.
    @Test func repeatsAndEarlierStartsAreSeen() {
        let weekly = TS.job("Weekly", start: TS.day(2026, 9, 1), recurrence: .weekly)   // every Tuesday
        let fourWeeksOut = TS.day(2026, 9, 29)
        #expect(JobScheduling.overlaps(for: proposal(JobDraft(startDate: fourWeeksOut)), among: [weekly],
                                       schedule: schedule, calendar: cal).map(\.job) == [weekly])
        let long = TS.job("Long", start: TS.day(2026, 8, 3), days: 40)
        #expect(JobScheduling.overlaps(for: proposal(JobDraft(startDate: tuesday)), among: [long],
                                       schedule: schedule, calendar: cal).count == 1)
    }

    /// The Job form and the Schedule Job sheet both ask `.full` (owner ruling 2026-09-22): a
    /// repeat whose earlier occurrence runs into the proposal's day is seen (the form's old rule
    /// only looked from the proposal's day on).
    /// (One-off jobs are never filtered by the range; only a repeat's occurrences are.)
    @Test func theFullRuleLooksBeforeTheProposalsDay() {
        // Every Monday for three workdays: Monday's occurrence runs into Tuesday.
        let weekly = TS.job("Weekly", start: TS.day(2026, 9, 14), days: 3, recurrence: .weekly)
        let hit = JobScheduling.overlaps(for: proposal(JobDraft(startDate: tuesday)), among: [weekly],
                                         schedule: schedule, rule: .full, calendar: cal)
        #expect(hit.map(\.job) == [weekly] && hit.first?.day == tuesday)
        // The sheet's proposal (a plain all-day booking) gets the same answer.
        let sheetProposal = ScheduledJob(startDate: tuesday, durationDays: 1)
        #expect(JobScheduling.overlaps(for: sheetProposal, among: [weekly], schedule: schedule,
                                       rule: .full, calendar: cal).map(\.job) == [weekly])
        let sameDay = TS.job("Same", start: tuesday)
        #expect(JobScheduling.overlaps(for: proposal(JobDraft(startDate: tuesday)), among: [sameDay],
                                       schedule: schedule, rule: .full, calendar: cal).count == 1)
    }

    /// The sheet used to warn on ANY shared workday; under `.full` an all-day booking (the working
    /// hours) and an evening job outside them don't collide, while a long booking that started
    /// weeks earlier still does (120 days back).
    @Test func theScheduleSheetsBookingComparesTimeWindows() {
        let evening = TS.job("Evening", start: tuesday, hour: 19, minutes: 60)
        let allDay = ScheduledJob(startDate: tuesday, durationDays: 1)
        #expect(JobScheduling.overlaps(for: allDay, among: [evening], schedule: schedule,
                                       rule: .full, calendar: cal).isEmpty)
        let workHours = TS.job("Midday", start: tuesday, hour: 11, minutes: 60)
        #expect(JobScheduling.overlaps(for: allDay, among: [workHours], schedule: schedule,
                                       rule: .full, calendar: cal).map(\.job) == [workHours])
        let long = TS.job("Long", start: TS.day(2026, 8, 3), days: 40)
        let multiDay = ScheduledJob(startDate: tuesday, durationDays: 3)
        #expect(JobScheduling.overlaps(for: multiDay, among: [long], schedule: schedule,
                                       rule: .full, calendar: cal).count == 1, "looks 120 days back")
    }

    @Test func theJobBeingEditedIsLeftOut() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Self", start: tuesday, in: context)
        context.saveChanges()
        let draft = JobDraft(job)
        #expect(JobScheduling.overlaps(for: proposal(draft), among: [job], excluding: job,
                                       schedule: schedule, calendar: cal).isEmpty)
        #expect(JobScheduling.overlaps(for: proposal(draft), among: [job], schedule: schedule, calendar: cal).count == 1)
    }
}

// MARK: - The calendar's reads

@MainActor
@Suite(.serialized)
struct ScheduleQueriesTests {

    private let cal = TS.calendar
    private let schedule = WorkSchedule.standard

    @Test func dayMapAgendaAndOpenings() {
        let now = TS.day(2026, 9, 14)                                   // Monday
        let a = TS.job("A", start: TS.day(2026, 9, 14), days: 2)        // Mon–Tue
        let b = TS.job("B", start: TS.day(2026, 9, 18))                 // Fri
        let old = TS.job("Old", start: TS.day(2026, 9, 1))
        let expanded = ScheduleQueries.expanded([a, b, old], in: ScheduleQueries.horizon(now: now, calendar: cal),
                                                calendar: cal)
        let byDay = ScheduleQueries.jobsByDay(expanded, schedule: schedule, calendar: cal)
        #expect(byDay[TS.day(2026, 9, 15)]?.map(\.title) == ["A"])
        #expect(ScheduleQueries.jobs(on: TS.day(2026, 9, 18), expanded, schedule: schedule, calendar: cal).map(\.title) == ["B"])
        #expect(ScheduleQueries.upcoming(expanded, schedule: schedule, now: now, calendar: cal).map(\.title) == ["A", "B"],
                "a finished job is not upcoming")
        let first = ScheduleQueries.openings(expanded, schedule: schedule, from: now, calendar: cal).first
        #expect(first?.start == TS.day(2026, 9, 16) && first?.workdays == 2, "Wed–Thu between A and B")
        #expect(ScheduleQueries.clearDate(expanded, schedule: schedule, from: now, calendar: cal) == TS.day(2026, 9, 21))
        #expect(ScheduleQueries.nextAvailable(expanded, schedule: schedule, from: now, calendar: cal) == TS.day(2026, 9, 16))
        #expect(!ScheduleQueries.hasOpenEndedRecurrence([a, b]))
    }
}
