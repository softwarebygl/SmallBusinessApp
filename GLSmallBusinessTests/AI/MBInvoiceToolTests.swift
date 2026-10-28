//
//  MBInvoiceToolTests.swift
//  GLSmallBusinessTests — AI
//
//  `create_invoice` (standalone, from an estimate, for a job) and `edit_invoice`: the three doors
//  a person has, and the money rules that guard them —
//    • an estimate already invoiced hands back that invoice instead of a second one (Pillar 2);
//    • a PAID invoice takes only the lock-exempt fields, and says "offer a change order" for the
//      rest (Pillar 4);
//    • change-order rows are read-only on the invoice;
//    • an edit that would make the invoice read Paid asks the person first, and keeps no Undo.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBInvoiceToolTests {

    // MARK: - From an estimate

    @Test func convertingAnEstimateCopiesItsLinesAndAnswersTwiceTheSameWay() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0001", status: .accepted, taxRatePercent: 7,
                                   lines: [(1000, true), (500, false)], in: world.context)
        estimate.customer = world.customer
        estimate.depositType = .percentage
        estimate.depositValue = 25
        world.context.saveChanges()

        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)),
        ])
        let invoice = try #require(world.invoices().first)
        #expect(world.invoices().count == 1)
        #expect(invoice.sourceEstimateNumber == "EST-0001")
        #expect(invoice.allLineItems.count == 2)
        #expect(invoice.amountDueNow > 0)                       // the deposit became the amount due now
        #expect(MBWriteHarness.titles(created) == ["Created invoice"])

        // Asked again, nothing is written: the model gets the same invoice back and asks the person.
        let again = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)),
        ])
        let output = MBWriteHarness.output(again)
        #expect(output["already_invoiced"]?.boolValue == true)
        #expect(MBWriteHarness.id(output, "invoice") == world.id(invoice))
        #expect(MBWriteHarness.activity(again).isEmpty)
        #expect(MBWriteHarness.undo(again) == nil)
        #expect(world.invoices().count == 1)

        // Only when the person says so does a second one get made.
        let another = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)), "create_another": true,
            "payment_terms": "net15",
        ])
        _ = MBWriteHarness.output(another)
        #expect(world.invoices().count == 2)
        let second = try #require(world.invoices().first { $0.persistentModelID != invoice.persistentModelID })
        #expect(second.paymentTerms == .net15)
    }

    @Test func anOptionsEstimateNeedsTheChosenOptions() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.optionsEstimate(number: "EST-0002", groups: [
            (name: "Good", lines: [(1000, false)]),
            (name: "Better", lines: [(2000, false)]),
        ], in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()

        let refused = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)),
        ])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.optionsRequired.code)
        #expect(world.invoices().isEmpty)

        let better = try #require(estimate.sortedGroups.last)
        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)),
            "option_group_ids": [.string(world.id(better))],
        ])
        _ = MBWriteHarness.output(created)
        let invoice = try #require(world.invoices().first)
        #expect(invoice.total == 2000)
    }

    /// Every argument is read BEFORE the conversion: a bad `payment_terms` must refuse while no
    /// invoice exists, never after one has been minted and the estimate marked converted.
    @Test func aBadArgumentRefusesBeforeTheEstimateIsConverted() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0031", status: .accepted, lines: [(800, false)],
                                   in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()

        let refused = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)), "payment_terms": "net_30",
        ])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
        #expect(world.invoices().isEmpty, "no invoice is minted behind a refusal")

        // Spelled the way the manifest spells it, the same call goes through.
        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)), "payment_terms": "net30",
        ])
        _ = MBWriteHarness.output(created)
        #expect(world.invoices().count == 1)
        #expect(world.invoices().first?.paymentTerms == .net30)
    }

    /// The estimate's deposit becomes the invoice's amount due now, a figure the app works out, so
    /// the write hands it back and the model never computes it (release eval 2026-09-27). It is
    /// capped at the balance, as the invoice asks the customer; null means the whole balance.
    @Test func anInvoiceWriteHandsBackTheAmountDueNowTheAppWorkedOut() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0041", status: .accepted, taxRatePercent: 7,
                                   lines: [(1000, true), (500, false)], in: world.context)
        estimate.customer = world.customer
        estimate.depositType = .percentage
        estimate.depositValue = 25
        world.context.saveChanges()

        // $1,000 + $70 tax + $500 = $1,570; a 25% deposit is $392.50.
        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "from_estimate_id": .string(world.id(estimate)),
        ])
        let output = MBWriteHarness.output(created)
        #expect(output["invoice"]?["total"]?.doubleValue == 1570)
        #expect(output["invoice"]?["amount_due_now"]?.doubleValue == 392.5)
        let id = MBWriteHarness.id(output, "invoice")

        let capped = await MBWriteHarness.run(world.box, "edit_invoice", ["id": .string(id), "amount_due_now": 2000])
        #expect(MBWriteHarness.output(capped)["invoice"]?["amount_due_now"]?.doubleValue == 1570)
        let whole = await MBWriteHarness.run(world.box, "edit_invoice", ["id": .string(id), "amount_due_now": 0])
        #expect(MBWriteHarness.output(whole)["invoice"]?["amount_due_now"] == .null)
    }

    // MARK: - For a job

    /// The carry a job's first invoice makes: change-order lines come across as new rows, keeping
    /// their `fromChangeOrder` flag — so a credit stays a credit and the total matches the source.
    @Test func billingAJobCarriesTheChangeOrderCreditAndMatchesTheSource() async throws {
        let world = try MBWriteWorld()
        let source = TS.invoice(number: "INV-0001", status: .sent, taxRatePercent: 6,
                                discountType: .percentage, discountValue: 10,
                                lines: [(2000, true)], in: world.context)
        source.customer = world.customer
        let order = TS.changeOrder(source, number: "CO-0001", status: .approved, taxRatePercent: 6,
                                   lines: [(-200, false)], in: world.context)
        world.context.saveChanges()
        try DomainState.subscribed.run {
            try ChangeOrderService.applyToInvoice(order, in: world.context)
        }
        let job = TS.job("Kitchen backsplash", start: MBToolHarness.now, customer: world.customer,
                         in: world.context)
        job.invoice = source
        world.context.saveChanges()
        let sourceTotal = source.total

        let created = await MBWriteHarness.run(world.box, "create_invoice", ["job_id": .string(world.id(job))])
        let output = MBWriteHarness.output(created)
        let billing = try #require(world.invoices().first { $0.persistentModelID != source.persistentModelID })
        #expect(billing.job?.persistentModelID == job.persistentModelID)
        #expect(billing.allLineItems.contains { $0.fromChangeOrder && $0.unitPrice == -200 })
        #expect(abs(billing.total - sourceTotal) < 0.005)
        #expect(MBWriteHarness.id(output, "invoice") == world.id(billing))
        // The source keeps its own change-order group.
        #expect(order.invoice?.persistentModelID == source.persistentModelID)
        #expect(source.sortedGroups.contains { $0.changeOrder != nil })
    }

    @Test func billingAJobCanBringItsPhotosAlong() async throws {
        let world = try MBWriteWorld()
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        world.context.insert(JobAttachment(kind: .photo, name: "before.jpg", data: Data([1, 2, 3]), job: job))
        world.context.saveChanges()

        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "job_id": .string(world.id(job)), "include_from_job": ["photos"],
            "groups": [["lines": [["name": "Labor", "unit_price": 500]]]],
        ])
        _ = MBWriteHarness.output(created)
        let invoice = try #require(world.invoices().first)
        #expect(invoice.liveRows(invoice.attachments).count == 1)
        #expect(invoice.total == 500)
    }

    /// The edit itself already landed by the time the files are fetched, so a file problem is a
    /// PARTIAL result: the activity row and the Undo stay, and the model is told which part
    /// didn't take — never a bare "nothing happened" over a write that did.
    @Test func aFileImportProblemIsReportedBesideTheEditNotInsteadOfIt() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0021", lines: [(600, false)], in: world.context)
        invoice.customer = world.customer
        world.context.saveChanges()
        #expect(invoice.job == nil)

        let edited = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(world.id(invoice)), "customer_notes": "Gate code 1234",
            "include_from_job": ["photos"],
        ])
        let output = MBWriteHarness.output(edited)
        #expect(output["files_not_added"]?.boolValue == true)
        #expect(output["message"]?.stringValue?.isEmpty == false)
        #expect(invoice.customerNotes == "Gate code 1234", "the note IS saved")
        #expect(MBWriteHarness.titles(edited) == ["Updated invoice"])
        #expect(MBWriteHarness.undo(edited) != nil, "the note can still be taken back")
    }

    // MARK: - Standalone and Undo

    @Test func aStandaloneInvoiceCanBeTakenBack() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "customer_id": .string(world.customerID), "job_title": "Backsplash",
            "payment_terms": "custom", "due_date": "2026-10-15",
            "groups": [["lines": [["name": "Labor", "unit_price": 750]]]],
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "invoice")
        let invoice = try #require(MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: world.context))
        #expect(invoice.paymentTerms == .custom)
        #expect(invoice.total == 750)

        let revert = await MBWriteHarness.undoLatest(created)
        guard case .reverted? = revert else {
            Issue.record("the new invoice should have been removed")
            return
        }
        #expect(world.invoices().isEmpty)
    }

    @Test func undoIsDroppedOnceMoneyIsRecorded() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_invoice", [
            "customer_id": .string(world.customerID), "job_title": "Backsplash",
            "groups": [["lines": [["name": "Labor", "unit_price": 750]]]],
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "invoice")
        let invoice = try #require(MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: world.context))
        try DomainState.subscribed.run {
            _ = try InvoiceService.recordPayment(on: invoice, amount: 100, method: .cash, in: world.context)
        }
        let entry = try #require(MBWriteHarness.undo(created))
        let reason = try #require(entry.dropReason())
        #expect(GLAIStrings.english(reason) == "A payment was recorded on it, so it stays as it is.")
        #expect(world.invoices().count == 1)
    }

    // MARK: - edit_invoice

    @Test func aPaidInvoiceTakesOnlyTheLockExemptFields() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0001", status: .sent, lines: [(1000, false)], in: world.context)
        invoice.customer = world.customer
        TS.pay(invoice, 1000, in: world.context)
        world.context.saveChanges()
        #expect(invoice.isMoneyLocked)
        let id = world.id(invoice)

        let refused = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(id), "job_title": "Something else",
        ])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.paidLocked.code)
        #expect(MBWriteHarness.failureMessage(refused).contains("change order"))
        #expect(invoice.jobTitle == "Job")

        // The amount due now is lock-exempt — but writing to a paid invoice always asks first.
        let asked = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(id), "amount_due_now": 250, "amount_due_detail": "Deposit to start",
        ])
        #expect(MBWriteHarness.line(asked).contains("INV-0001"))
        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(invoice.amountDueNow == 250)
        #expect(invoice.amountDueDetail == "Deposit to start")
        #expect(MBWriteHarness.undo(done) == nil)   // a confirmed change keeps no Undo
    }

    @Test func changeOrderRowsCantBeChangedOnTheInvoice() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0002", status: .sent, lines: [(2000, false)], in: world.context)
        invoice.customer = world.customer
        let order = TS.changeOrder(invoice, number: "CO-0001", status: .approved, lines: [(300, false)],
                                   in: world.context)
        world.context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: world.context) }
        let billed = try #require(invoice.allLineItems.first { $0.fromChangeOrder })
        let billedGroup = try #require(billed.group)

        let removeLine = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(world.id(invoice)), "remove_line_ids": [.string(world.id(billed))],
        ])
        #expect(MBWriteHarness.failureReason(removeLine) == DomainError.changeOrderLinesReadOnly.code)

        let removeGroup = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(world.id(invoice)), "remove_group_ids": [.string(world.id(billedGroup))],
        ])
        #expect(MBWriteHarness.failureReason(removeGroup) == DomainError.changeOrderLinesReadOnly.code)
        #expect(invoice.allLineItems.count == 2)
    }

    @Test func anEditThatWouldPayTheInvoiceAsksFirst() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0003", status: .sent, lines: [(1000, false)], in: world.context)
        invoice.customer = world.customer
        TS.pay(invoice, 400, in: world.context)
        world.context.saveChanges()
        let id = world.id(invoice)

        let asked = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(id), "discount_type": "fixed", "discount_value": 600,
        ])
        let confirmation = try #require(MBWriteHarness.confirmation(asked))
        #expect(confirmation.recordIDs == [id])
        #expect(GLAIStrings.english(confirmation.line).contains("INV-0003"))
        // Cancelled: nothing is written.
        #expect(invoice.discountType == .none)
        #expect(!invoice.isMoneyLocked)

        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(invoice.discountValue == 600)
        #expect(invoice.isMoneyLocked)
        #expect(MBWriteHarness.undo(done) == nil)
    }

    @Test func anOrdinaryInvoiceEditIsSavedInPlaceAndCanBeUndone() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0004", status: .draft, lines: [(1000, false)], in: world.context)
        invoice.customer = world.customer
        world.context.saveChanges()
        let id = world.id(invoice)
        let line = try #require(invoice.allLineItems.first)

        let edited = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(id), "customer_notes": "Thanks!", "tax_rate_percent": 7,
            "lines": [["line_id": .string(world.id(line)), "unit_price": 1200],
                      ["name": "Grout", "unit_price": 80]],
        ])
        _ = MBWriteHarness.output(edited)
        #expect(world.invoices().count == 1)
        #expect(invoice.customerNotes == "Thanks!")
        #expect(invoice.allLineItems.count == 2)
        #expect(invoice.taxRatePercent == 7)

        let revert = await MBWriteHarness.undoLatest(edited)
        guard case .reverted(let activity)? = revert else {
            Issue.record("the edit should have been put back")
            return
        }
        #expect(GLAIStrings.english(activity.title) == "Restored invoice")
        #expect(invoice.customerNotes.isEmpty)
        #expect(invoice.allLineItems.count == 1)
        #expect(invoice.taxRatePercent == 0)
    }
}
