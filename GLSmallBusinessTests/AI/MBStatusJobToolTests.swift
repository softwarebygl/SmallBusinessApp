//
//  MBStatusJobToolTests.swift
//  GLSmallBusinessTests — AI
//
//  `set_status` for the four records that have one, and `save_job` (book, reschedule, repeat,
//  price, project). Overlaps are reported, never refused; a paid invoice's status is locked; and
//  un-approving a charge that would leave the invoice paid asks first.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBStatusJobToolTests {

    // MARK: - set_status

    @Test func anEstimateStatusChangesAndComesBack() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0001", in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "estimate", "id": .string(world.id(estimate)), "status": "accepted",
        ])
        _ = MBWriteHarness.output(outcome)
        #expect(estimate.status == .accepted)
        #expect(MBWriteHarness.titles(outcome) == ["Changed estimate status"])

        let revert = await MBWriteHarness.undoLatest(outcome)
        guard case .reverted? = revert else {
            Issue.record("the status should have gone back")
            return
        }
        #expect(estimate.status == .draft)
    }

    @Test func aWrongStatusForTheKindIsTheModelsOwnSlip() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0002", in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()
        let outcome = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "estimate", "id": .string(world.id(estimate)), "status": "approved",
        ])
        #expect(MBWriteHarness.failureReason(outcome) == "invalid_arguments")
        #expect(MBWriteHarness.activity(outcome).isEmpty)   // not a "Not done" row on the card
        #expect(estimate.status == .draft)
    }

    @Test func aPaidInvoiceKeepsItsStatusAndOffersAChangeOrder() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0001", status: .sent, lines: [(500, false)], in: world.context)
        invoice.customer = world.customer
        TS.pay(invoice, 500, in: world.context)
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "invoice", "id": .string(world.id(invoice)), "status": "draft",
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.paidLocked.code)
        #expect(MBWriteHarness.failureMessage(outcome).contains("change order"))
        #expect(invoice.status == .sent)
    }

    @Test func markingAZeroInvoiceSentAsksFirstBecauseItLocksIt() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0002", status: .draft, lines: [(0, false)], in: world.context)
        invoice.customer = world.customer
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "invoice", "id": .string(world.id(invoice)), "status": "sent",
        ])
        #expect(MBWriteHarness.line(asked).contains("INV-0002"))
        #expect(invoice.status == .draft)

        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(invoice.status == .sent)
        #expect(invoice.isMoneyLocked)
        #expect(MBWriteHarness.undo(done) == nil)
    }

    @Test func unApprovingAnAddedChangeOrderTakesItsItemsOff() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0003", status: .sent, lines: [(1000, false)], in: world.context)
        invoice.customer = world.customer
        let order = TS.changeOrder(invoice, number: "CO-0001", status: .approved, lines: [(300, false)],
                                   in: world.context)
        world.context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: world.context) }
        #expect(invoice.total == 1300)

        let outcome = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "change_order", "id": .string(world.id(order)), "status": "declined",
        ])
        _ = MBWriteHarness.output(outcome)
        #expect(order.status == .declined)
        #expect(invoice.total == 1000)
        #expect(MBWriteHarness.titles(outcome) == ["Changed change order status"])

        // Undo puts the order back on Approved AND its items back on the invoice.
        let revert = await MBWriteHarness.undoLatest(outcome)
        guard case .reverted? = revert else {
            Issue.record("the change order should have gone back")
            return
        }
        #expect(order.status == .approved)
        #expect(order.appliedToInvoice)
        #expect(invoice.total == 1300)
    }

    @Test func aJobStatusKeepsItsCompletionDateThroughUndo() async throws {
        let world = try MBWriteWorld()
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        let completed = MBToolHarness.now.addingTimeInterval(-3 * 24 * 60 * 60)
        job.statusRaw = JobStatus.completed.rawValue
        job.completedAt = completed
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "job", "id": .string(world.id(job)), "status": "inProgress",
        ])
        _ = MBWriteHarness.output(outcome)
        #expect(job.status == .inProgress)
        #expect(job.completedAt == nil)

        let revert = await MBWriteHarness.undoLatest(outcome)
        guard case .reverted? = revert else {
            Issue.record("the job status should have gone back")
            return
        }
        #expect(job.status == .completed)
        #expect(job.completedAt == completed)   // the warranty clock isn't restarted
    }

    // MARK: - save_job

    @Test func bookingAJobReportsOverlapsButBooksAnyway() async throws {
        let world = try MBWriteWorld()
        let monday = MBToolHarness.now
        let existing = TS.job("Existing", start: monday, days: 2, customer: world.customer, in: world.context)
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "save_job", [
            "customer_id": .string(world.customerID), "title": "Backsplash",
            "start_date": "2026-09-21", "duration_days": 1, "agreed_price": 2500.01,
        ])
        let output = MBWriteHarness.output(outcome)
        let job = try #require(world.jobs().first { $0.persistentModelID != existing.persistentModelID })
        #expect(job.title == "Backsplash")
        #expect(job.agreedPrice == 2500.01)   // whole cents, as sent (law 60)
        #expect(job.customer?.persistentModelID == world.customer.persistentModelID)
        let overlaps = try #require(output["overlaps"]?.arrayValue)
        #expect(overlaps.count == 1)
        #expect(overlaps.first?["id"]?.stringValue == world.id(existing))
        #expect(MBWriteHarness.titles(outcome) == ["Booked job"])
    }

    @Test func aJobCanBeMovedRepeatedAndPutInAProjectThenUndone() async throws {
        let world = try MBWriteWorld()
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        let project = Project(name: "Reed Remodel", customer: world.customer)
        world.context.insert(project)
        world.context.saveChanges()
        let startedOn = TS.calendar.startOfDay(for: job.startDate)

        let outcome = await MBWriteHarness.run(world.box, "save_job", [
            "id": .string(world.id(job)), "start_date": "2026-09-28",
            "repeats": "weekly", "repeat_weekdays": ["monday", "wednesday"], "repeat_count": 4,
            "project_id": .string(world.id(project)),
            "service_address": ["street1": "9 Oak Ln", "city": "Miami"],
        ])
        _ = MBWriteHarness.output(outcome)
        #expect(job.startDate == TS.day(2026, 9, 28))
        #expect(job.recurrenceFrequency == .weekly)
        #expect(job.recurrenceCount == 4)
        #expect(job.recurrenceWeekdayMask == (1 << 1 | 1 << 3))
        #expect(job.project?.persistentModelID == project.persistentModelID)
        #expect(job.serviceAddress.street1 == "9 Oak Ln")
        #expect(MBWriteHarness.titles(outcome) == ["Updated job"])

        let revert = await MBWriteHarness.undoLatest(outcome)
        guard case .reverted? = revert else {
            Issue.record("the job should have gone back")
            return
        }
        #expect(job.startDate == startedOn)
        #expect(job.recurrenceFrequency == nil)
        #expect(job.project == nil)
    }

    @Test func aJobFromAnEstimateNeedsAnAcceptedOne() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0003", status: .sent, in: world.context)
        estimate.customer = world.customer
        estimate.jobTitle = "Master bath"
        world.context.saveChanges()

        let refused = await MBWriteHarness.run(world.box, "save_job", [
            "from_estimate_id": .string(world.id(estimate)), "start_date": "2026-09-23",
        ])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
        #expect(world.jobs().isEmpty)

        try DomainState.subscribed.run {
            try EstimateService.setStatus(estimate, .accepted, in: world.context)
        }
        let booked = await MBWriteHarness.run(world.box, "save_job", [
            "from_estimate_id": .string(world.id(estimate)), "start_date": "2026-09-23",
            "duration_days": 2, "notes": "Gate code 1234",
        ])
        _ = MBWriteHarness.output(booked)
        let job = try #require(world.jobs().first)
        #expect(job.estimate?.persistentModelID == estimate.persistentModelID)
        #expect(job.title == "Master bath")
        #expect(job.durationDays == 2)
        #expect(job.notes == "Gate code 1234")
        #expect(job.customer?.persistentModelID == world.customer.persistentModelID)
    }

    /// A project id the model half-remembered refuses BEFORE the booking, so the person is never
    /// told nothing happened while a job sits on their calendar.
    @Test func aBadProjectIdRefusesBeforeTheJobIsBooked() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "save_job", [
            "customer_id": .string(world.customerID), "title": "Backsplash",
            "start_date": "2026-09-23", "project_id": .string(UUID().uuidString),
        ])
        #expect(MBWriteHarness.failureReason(refused) == "not_found")
        #expect(world.jobs().isEmpty, "nothing is booked when the project can't be found")

        // Same on an edit: the job's own fields are untouched.
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        world.context.saveChanges()
        let refusedEdit = await MBWriteHarness.run(world.box, "save_job", [
            "id": .string(world.id(job)), "title": "Renamed",
            "project_id": .string(UUID().uuidString),
        ])
        #expect(MBWriteHarness.failureReason(refusedEdit) == "not_found")
        #expect(job.title == "Backsplash", "the rename is not written either")
    }

    @Test func aJobsCustomerIsNeverChanged() async throws {
        let world = try MBWriteWorld()
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        let other = TS.customer(first: "Bea", last: "Ruiz", business: nil, in: world.context)
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "save_job", [
            "id": .string(world.id(job)), "customer_id": .string(world.id(other)),
        ])
        #expect(MBWriteHarness.failureReason(outcome) == "invalid_arguments")
        #expect(job.customer?.persistentModelID == world.customer.persistentModelID)
    }

    @Test func aTimedVisitKeepsItsWindow() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "save_job", [
            "customer_id": .string(world.customerID), "title": "Walkthrough",
            "all_day": false, "start_time": "2026-09-24T14:00:00-04:00", "duration_minutes": 90,
        ])
        _ = MBWriteHarness.output(outcome)
        let job = try #require(world.jobs().first)
        #expect(!job.isAllDay)
        #expect(job.durationMinutes == 90)
        #expect(job.startDate == TS.day(2026, 9, 24))
        let hour = TS.calendar.component(.hour, from: try #require(job.startTime))
        #expect(hour == 14)
    }
}
