//
//  MBPaymentDeleteToolTests.swift
//  GLSmallBusinessTests — AI
//
//  `record_payment` and `delete` — the two tools the person always confirms (contract §5).
//  Both keep NO Undo afterwards: money is append-only and a delete is a delete.
//
//  Pillar 5: every delete goes through `DeletionService`, with its cascade, its paid lock and its
//  "payments can't be deleted" refusal.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBPaymentDeleteToolTests {

    private func paidInvoiceWorld() throws -> (MBWriteWorld, Invoice) {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0001", status: .sent, lines: [(1000, false)], in: world.context)
        invoice.customer = world.customer
        world.context.saveChanges()
        return (world, invoice)
    }

    // MARK: - record_payment

    @Test func recordingAPaymentAsksFirstAndThenRecordsIt() async throws {
        let (world, invoice) = try paidInvoiceWorld()
        let asked = await MBWriteHarness.run(world.box, "record_payment", [
            "invoice_id": .string(world.id(invoice)), "amount": 500.01, "method": "cash",
            "date": "2026-09-21", "note": "check 1042",
        ])
        let confirmation = try #require(MBWriteHarness.confirmation(asked))
        #expect(confirmation.recordIDs == [world.id(invoice)])
        let line = GLAIStrings.english(confirmation.line)
        #expect(line.contains("INV-0001"))
        #expect(line.contains("500.01"))            // whole cents, as sent (law 60)
        #expect(invoice.amountPaid == 0)            // nothing is recorded until the person says yes

        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(invoice.amountPaid == 500.01)
        #expect(invoice.sortedPayments.first?.method == .cash)
        #expect(invoice.sortedPayments.first?.note == "check 1042")
        #expect(output["paid_in_full"]?.boolValue == false)
        #expect(MBWriteHarness.titles(done) == ["Recorded payment"])
        #expect(MBWriteHarness.activity(done).first?.kind == .recorded)
        #expect(MBWriteHarness.undo(done) == nil)   // money is never undone
    }

    @Test func moreThanTheBalanceIsRefusedBeforeAnyoneIsAsked() async throws {
        let (world, invoice) = try paidInvoiceWorld()
        let outcome = await MBWriteHarness.run(world.box, "record_payment", [
            "invoice_id": .string(world.id(invoice)), "amount": 1500, "method": "check",
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.exceedsBalance.code)
        #expect(MBWriteHarness.failureMessage(outcome).contains("split"))
        #expect(invoice.amountPaid == 0)
        #expect(invoice.sortedPayments.isEmpty)
    }

    @Test func theSameCallNeverRecordsTheMoneyTwice() async throws {
        let (world, invoice) = try paidInvoiceWorld()
        let arguments: GLAIJSON = [
            "invoice_id": .string(world.id(invoice)), "amount": 250, "method": "cash",
        ]
        let asked = await MBWriteHarness.run(world.box, "record_payment", arguments, turn: "t1", callID: "fc_1")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(asked))
        #expect(invoice.sortedPayments.count == 1)

        // The same step, run again (a retry): the tool hands back what it already did.
        let again = await MBWriteHarness.run(world.box, "record_payment", arguments, turn: "t1", callID: "fc_1")
        let output = MBWriteHarness.output(again)
        #expect(output["already_recorded"]?.boolValue == true)
        #expect(invoice.sortedPayments.count == 1)
        #expect(invoice.amountPaid == 250)

        // A different call is a different payment.
        let second = await MBWriteHarness.run(world.box, "record_payment", arguments, turn: "t1", callID: "fc_2")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(second))
        #expect(invoice.sortedPayments.count == 2)
    }

    @Test func aPaymentThatSettlesTheInvoiceSaysSo() async throws {
        let (world, invoice) = try paidInvoiceWorld()
        let asked = await MBWriteHarness.run(world.box, "record_payment", [
            "invoice_id": .string(world.id(invoice)), "amount": 1000, "method": "check",
        ])
        let output = MBWriteHarness.output(await MBWriteHarness.confirm(asked))
        #expect(output["paid_in_full"]?.boolValue == true)
        #expect(invoice.isMoneyLocked)
    }

    // MARK: - delete

    @Test func deletingACustomerNamesTheCascadeAndThenRemovesIt() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0001", in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "customer", "id": .string(world.customerID)]],
        ])
        let confirmation = try #require(MBWriteHarness.confirmation(asked))
        #expect(confirmation.isDestructive)
        // Owner ruling 2026-09-25 (7): a client is confirmed by typing their name, and the alert
        // names them the way they are typed.
        #expect(confirmation.typedName == "Marcus Reed")
        let line = GLAIStrings.english(confirmation.line)
        #expect(line.contains("Marcus Reed"))
        #expect(line.contains("estimates, invoices, change orders, receipts, and documents are removed too"))
        // The alert says "This can’t be undone." itself: the line must not say it twice.
        #expect(!line.contains("can’t be undone"))
        #expect(world.customers().count == 1)

        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(output["deleted"]?.doubleValue == 1)
        #expect(world.customers().isEmpty)
        #expect(world.estimates().isEmpty)          // the cascade came with it
        #expect(MBWriteHarness.titles(done) == ["Deleted customer"])
        #expect(MBWriteHarness.activity(done).first?.detail == "Reed, Marcus")
        #expect(MBWriteHarness.undo(done) == nil)
    }

    @Test func aDeleteIsAllOrNothingWhenOneRecordIsPaid() async throws {
        let world = try MBWriteWorld()
        let paid = TS.invoice(number: "INV-0001", status: .sent, lines: [(500, false)], in: world.context)
        paid.customer = world.customer
        TS.pay(paid, 500, in: world.context)
        let draft = TS.invoice(number: "INV-0002", status: .draft, lines: [(100, false)], in: world.context)
        draft.customer = world.customer
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "invoice", "id": .string(world.id(draft))],
                        ["kind": "invoice", "id": .string(world.id(paid))]],
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.paidLocked.code)
        #expect(world.invoices().count == 2)
    }

    @Test func aPaymentIsNeverDeletedAndOffersACreditChangeOrder() async throws {
        let (world, invoice) = try paidInvoiceWorld()
        let payment = TS.pay(invoice, 100, in: world.context)
        world.context.saveChanges()

        let outcome = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "payment", "id": .string(world.id(payment))]],
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.paymentsCannotBeDeleted.code)
        #expect(MBWriteHarness.failureMessage(outcome).contains("credit change order"))
        #expect(invoice.sortedPayments.count == 1)
    }

    @Test func severalRecordsAreNamedOneByOneAndDeletedTogether() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0007", in: world.context)
        estimate.customer = world.customer
        let job = TS.job("Backsplash", start: MBToolHarness.now, customer: world.customer, in: world.context)
        world.context.saveChanges()

        let asked = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "estimate", "id": .string(world.id(estimate))],
                        ["kind": "job", "id": .string(world.id(job))]],
        ])
        let line = GLAIStrings.english(try #require(MBWriteHarness.confirmation(asked)).line)
        #expect(line.contains("EST-0007"))
        #expect(line.contains("Backsplash"))

        let done = await MBWriteHarness.confirm(asked)
        let output = MBWriteHarness.output(done)
        #expect(output["deleted"]?.doubleValue == 2)
        #expect(MBWriteHarness.titles(done) == ["Deleted estimate", "Deleted job"])
        #expect(world.estimates().isEmpty)
        #expect(world.jobs().isEmpty)
        #expect(world.customers().count == 1)   // nothing else went with them
    }

    @Test func anIdThatIsntThereIsTheModelsOwnSlip() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "invoice", "id": "11111111-1111-1111-1111-111111111111"]],
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.recordNotFound.code)
    }
}
