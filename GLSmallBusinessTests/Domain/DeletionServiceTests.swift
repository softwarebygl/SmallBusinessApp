//
//  DeletionServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The one delete door every list, detail screen, document Remove and (later) the assistant's
//  `delete` tool goes through: the gate for each kind's own operation, the paid lock, the
//  server's cascade cap, the other-devices breaker report, all-or-nothing batches, payments never
//  deleted, and one save that persists the queued sync op with the delete.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct DeletionServiceTests {

    /// A customer with an estimate, an unpaid invoice with no payment recorded (one with a payment
    /// can't be deleted, law 60: see `aRecordedPaymentRefusesTheInvoiceAndItsCustomer`), an applied
    /// change order, a receipt, a package extra and a job — saved, so every row has its syncID.
    private func customerWithRecords(in context: ModelContext)
        -> (Customer, Estimate, Invoice, Receipt, ScheduledJob) {
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(in: context)
        estimate.customer = customer
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        invoice.customer = customer
        TS.changeOrder(invoice, status: .approved, in: context)
        let receipt = TS.receipt(total: 40, category: "Materials", date: .now, in: context)
        receipt.customer = customer
        context.insert(CustomerDocument(name: "extra.pdf", data: Data([1]), customer: customer))
        let job = TS.job("Tile", start: .now, customer: customer, in: context)
        context.saveChanges()
        return (customer, estimate, invoice, receipt, job)
    }

    // MARK: Cascade, the queued op, and the save

    @Test func aCustomerGoesWithTheirRecordsInOneQueuedOpAndIsSaved() throws {
        let context = try DomainFixtures.context()
        let (customer, _, invoice, _, job) = customerWithRecords(in: context)
        let customerID = try #require(customer.syncID)
        let invoiceID = try #require(invoice.syncID)

        let plan = try DomainState.subscribed.run { try DeletionService.plan([.customer(customer)], in: context) }
        #expect(plan.kinds == [.customer] && plan.rootCount == 1)
        #expect(plan.cascadeRows >= 7, "estimate + group + line, invoice + group + line, change order, receipt, extra")
        #expect(plan.summary == mbLoc("Their estimates, invoices, change orders, receipts, and documents are removed too. This can’t be undone."))
        #expect(!plan.tripsOtherDevicesBreaker)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 1, "a plan deletes nothing")

        let outcome = try DomainState.subscribed.run { try DeletionService.delete([.customer(customer)], in: context) }
        #expect(outcome == .deleted(.init(deleted: 1, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false)))
        #expect(!context.hasChanges, "saved now, with the queued delete op")
        for count in [try context.fetchCount(FetchDescriptor<Customer>()),
                      try context.fetchCount(FetchDescriptor<Estimate>()),
                      try context.fetchCount(FetchDescriptor<Invoice>()),
                      try context.fetchCount(FetchDescriptor<ChangeOrder>()),
                      try context.fetchCount(FetchDescriptor<Receipt>()),
                      try context.fetchCount(FetchDescriptor<CustomerDocument>())] {
            #expect(count == 0)
        }
        #expect(job.customer == nil, "jobs are kept, just unlinked")

        let ops = GLSyncOutboxEntry.all(in: context).filter(\.isDelete)
        #expect(ops.count == 1, "one op for the root, carrying its subtree")
        #expect(ops.first?.recordID == customerID)
        #expect(ops.first?.cascade.contains(invoiceID) == true)
    }

    @Test func aRecordInsideAnotherRootsCascadeIsNotDeletedTwice() throws {
        let context = try DomainFixtures.context()
        let (customer, estimate, invoice, _, _) = customerWithRecords(in: context)
        let targets: [DeletionService.Target] = [.invoice(invoice), .customer(customer), .estimate(estimate)]
        let plan = try DomainState.subscribed.run { try DeletionService.plan(targets, in: context) }
        #expect(plan.kinds == [.customer])
        let outcome = try DomainState.subscribed.run { try DeletionService.delete(targets, in: context) }
        #expect(outcome == .deleted(.init(deleted: 1, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false)))
        #expect(GLSyncOutboxEntry.all(in: context).filter(\.isDelete).count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 0)
    }

    @Test func eachKindDeletesThroughItsOwnPath() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(in: context)
        let entry = TS.logHours(employee, 4, in: context)
        let check = TS.paycheck(employee, gross: 100, periodStart: .now, periodEnd: .now, payDate: .now, in: context)
        let sub = TS.subcontractor(in: context)
        let owed = TS.oweSub(sub, 50, in: context)
        let project = Project(name: "Kitchen")
        context.insert(project)
        let job = TS.job("Tile", start: .now, in: context)
        job.project = project
        let item = PriceSheetItem(name: "Grout")
        context.insert(item)
        context.saveChanges()

        _ = try DomainState.subscribed.run {
            try DeletionService.delete([.timeEntry(entry), .paycheck(check), .subPayment(owed),
                                        .project(project), .priceItem(item)], in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<TimeEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Paycheck>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SubPayment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PriceSheetItem>()) == 0)
        #expect(job.project == nil && !job.isDeleted, "a project's jobs are kept")
        #expect(GLSyncOutboxEntry.all(in: context).contains { $0.recordType == "price_sheet_item" && $0.isDelete },
                "a Price Sheet delete reaches the server as a tombstone (QA F3: the catalog is backed up)")

        _ = try DomainState.subscribed.run { try DeletionService.delete([.employee(employee), .subcontractor(sub)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Subcontractor>()) == 0)
        #expect(!context.hasChanges)
    }

    @Test func aSubcontractorsKeychainTINGoesFirst() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        sub.updateTIN("12-3456789")
        context.saveChanges()
        let key = sub.tinKey
        let probe = TS.subcontractor()
        probe.tinKey = key
        defer { probe.clearSecureTIN() }
        #expect(probe.hasTIN)

        _ = try DomainState.subscribed.run { try DeletionService.delete([.subcontractor(sub)], in: context) }
        #expect(!probe.hasTIN, "the SSN/EIN must not outlive the subcontractor in the Keychain")
    }

    // MARK: Refusals

    @Test func eachKindIsGatedAsItsOwnOperation() throws {
        let context = try DomainFixtures.context()
        let receipt = TS.receipt(total: 10, category: "Fuel", date: .now, in: context)
        let invoice = TS.invoice(in: context)
        context.saveChanges()

        #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.receipt(receipt)], in: context) } }
                == .readOnly(operation: "deleteReceipt", lapsed: true))
        #expect(DomainState.offline.run { domainError { try DeletionService.delete([.invoice(invoice)], in: context) } }
                == .readOnly(operation: "deleteInvoice", lapsed: false))
        #expect(DomainState.lapsed.run { domainError { _ = try DeletionService.plan([.invoice(invoice)], in: context) } }
                == .readOnly(operation: "deleteInvoice", lapsed: true), "a plan refuses what the delete would")
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1 && context.fetchCount(FetchDescriptor<Invoice>()) == 1)

        // Sample mode is never read-only, even offline.
        _ = try DomainState.sampleOffline.run { try DeletionService.delete([.receipt(receipt)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 0)
    }

    @Test func thePaidLockRefusesTheWholeBatch() throws {
        let context = try DomainFixtures.context()
        let paid = TS.invoice(number: "INV-0001", lines: [(500, false)], in: context)
        TS.pay(paid, 500, in: context)
        let payer = TS.customer(first: "Paid", in: context)
        paid.customer = payer
        let clean = TS.customer(first: "Clean", in: context)
        let open = TS.invoice(number: "INV-0002", in: context)
        context.saveChanges()
        #expect(paid.isMoneyLocked && payer.hasPaidInvoice)

        DomainState.subscribed.run {
            #expect(domainError { try DeletionService.delete([.invoice(open), .invoice(paid)], in: context) } == .paidLocked)
            #expect(domainError { try DeletionService.delete([.customer(clean), .customer(payer)], in: context) } == .paidLocked)
            #expect(domainError { _ = try DeletionService.plan([.customer(payer)], in: context) } == .paidLocked)
        }
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 2, "nothing in a refused batch is deleted")
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 2)
    }

    /// Law 60: payments are append-only. The paid lock covers only an invoice paid IN FULL, so a
    /// partly paid invoice (or the customer above it) used to be deleted with its payments: a
    /// $2,000 deposit gone from Collected. Any recorded payment now refuses the delete, on the
    /// phone first, because the server refuses it too (`has_payments`) and a refused delete is
    /// parked for good. Projects and jobs never cascade an invoice, so they are not touched.
    @Test func aRecordedPaymentRefusesTheInvoiceAndItsCustomer() throws {
        let context = try DomainFixtures.context()
        let owing = TS.customer(first: "Owing", in: context)
        let partly = TS.invoice(number: "INV-0003", lines: [(5000, false)], in: context)
        partly.customer = owing
        TS.pay(partly, 2000, in: context)
        let zeroPayment = TS.invoice(number: "INV-0004", lines: [(300, false)], in: context)
        TS.pay(zeroPayment, 0, in: context)
        let open = TS.invoice(number: "INV-0005", in: context)
        let clean = TS.customer(first: "Clean", in: context)
        context.saveChanges()
        #expect(!partly.isMoneyLocked && !owing.hasPaidInvoice, "outside the paid lock")
        let outboxBefore = GLSyncOutboxEntry.all(in: context).filter(\.isDelete).count

        DomainState.subscribed.run {
            #expect(domainError { try DeletionService.delete([.invoice(open), .invoice(partly)], origin: .screen, in: context) }
                    == .hasRecordedPayments(customer: false), "all-or-nothing: the open invoice stays too")
            #expect(domainError { _ = try DeletionService.plan([.invoice(partly)], in: context) } == .hasRecordedPayments(customer: false))
            #expect(domainError { try DeletionService.delete([.invoice(zeroPayment)], origin: .screen, in: context) }
                    == .hasRecordedPayments(customer: false), "any recorded payment is a record, even $0 (the server's rule)")
            #expect(domainError { try DeletionService.delete([.customer(clean), .customer(owing)], origin: .screen, in: context) }
                    == .hasRecordedPayments(customer: true), "the customer's own sentence, not one about deleting payments")
            #expect(domainError { _ = try DeletionService.plan([.customer(owing)], in: context) } == .hasRecordedPayments(customer: true))
        }
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<InvoicePayment>()) == 2, "the payments are kept")
        #expect(partly.amountPaid == 2000)
        #expect(GLSyncOutboxEntry.all(in: context).filter(\.isDelete).count == outboxBefore, "no delete op queued")

        // The paid lock still answers first for a fully paid invoice (the server's order too).
        TS.pay(partly, 3000, in: context)
        context.saveChanges()
        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.invoice(partly)], in: context) } }
                == .paidLocked)

        // An invoice with no payment still deletes.
        _ = try DomainState.subscribed.run { try DeletionService.delete([.invoice(open)], origin: .screen, in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 2)
    }

    @Test func aRecordAlreadyGoneRefusesTheBatch() throws {
        let context = try DomainFixtures.context()
        let a = TS.receipt(total: 1, category: "Fuel", date: .now, in: context)
        let b = TS.receipt(total: 2, category: "Fuel", date: .now, in: context)
        context.saveChanges()
        _ = try DomainState.subscribed.run { try DeletionService.delete([.receipt(a)], in: context) }
        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.receipt(b), .receipt(a)], in: context) } }
                == .recordNotFound)
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1)
    }

    @Test func moreThanFiveHundredCascadeRowsIsRefused() throws {
        let context = try DomainFixtures.context()
        let big = TS.employee(first: "Big", in: context)
        for _ in 0...DeletionService.maxCascadeRows { TS.logHours(big, 1, in: context) }   // 501
        let edge = TS.employee(first: "Edge", in: context)
        for _ in 0..<DeletionService.maxCascadeRows { TS.logHours(edge, 1, in: context) }  // 500
        context.saveChanges()

        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.employee(edge), .employee(big)], in: context) } }
                == .tooMuchToDelete)
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == 2)
        let plan = try DomainState.subscribed.run { try DeletionService.plan([.employee(edge)], in: context) }
        #expect(plan.cascadeRows == DeletionService.maxCascadeRows, "exactly the cap is allowed")
        _ = try DomainState.subscribed.run { try DeletionService.delete([.employee(edge)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == 1)
        // The screens have always deleted a big record; the cap is the tool's (owner's call).
        #expect(try DomainState.subscribed.run { try DeletionService.plan([.employee(big)], origin: .screen, in: context) }
                .cascadeRows == DeletionService.maxCascadeRows + 1)
        _ = try DomainState.subscribed.run { try DeletionService.delete([.employee(big)], origin: .screen, in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Employee>()) == 0)
    }

    @Test func moreThanTwentyFiveRootsIsReportedNotRefused() throws {
        let context = try DomainFixtures.context()
        let receipts = (0...DeletionService.otherDevicesBreakerRoots).map {
            TS.receipt(total: Double($0 + 1), category: "Fuel", date: .now, in: context)
        }
        context.saveChanges()
        let targets = receipts.map(DeletionService.Target.receipt)

        let under = try DomainState.subscribed.run { try DeletionService.plan(Array(targets.dropFirst()), in: context) }
        #expect(under.rootCount == 25 && !under.tripsOtherDevicesBreaker)

        let over = try DomainState.subscribed.run { try DeletionService.plan(targets, in: context) }
        #expect(over.rootCount == 26 && over.tripsOtherDevicesBreaker)
        #expect(over.summary.contains(DeletionService.otherDevicesBreakerNote))

        let outcome = try DomainState.subscribed.run { try DeletionService.delete(targets, in: context) }
        #expect(outcome == .deleted(.init(deleted: 26, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: true)))
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 0)
    }

    // MARK: Naming a record (the tools' door)

    @Test func targetsResolveBySyncIDAndPaymentsAreNeverDeleted() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let item = PriceSheetItem(name: "Grout")
        context.insert(item)
        let invoice = TS.invoice(in: context)
        let payment = TS.pay(invoice, 10, in: context)
        context.saveChanges()
        let itemID = try PriceSheetService.ensureID(item, in: context)

        let found = try DeletionService.target(kind: .customer, id: try #require(customer.syncID), in: context)
        #expect(found.kind == .customer && found.model.persistentModelID == customer.persistentModelID)
        #expect(try DeletionService.target(kind: .priceItem, id: itemID, in: context).kind == .priceItem)
        #expect(domainError { _ = try DeletionService.target(kind: .invoice, id: UUID(), in: context) } == .recordNotFound)
        #expect(domainError { _ = try DeletionService.target(kind: .customer, id: try #require(invoice.syncID), in: context) }
                == .recordNotFound, "an id of another kind is not a match")
        #expect(domainError { _ = try DeletionService.target(kind: .payment, id: try #require(payment.syncID), in: context) }
                == .paymentsCannotBeDeleted)
        #expect(try context.fetchCount(FetchDescriptor<InvoicePayment>()) == 1)
    }

    // MARK: The confirmation's words

    @Test func theSummaryUsesTheScreensWords() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let receipt = TS.receipt(total: 5, category: "Fuel", date: .now, in: context)
        let job = TS.job("Tile", start: .now, in: context)
        let invoice = TS.invoice(in: context)
        let applied = TS.changeOrder(invoice, status: .approved, applied: true, in: context)
        context.saveChanges()

        try DomainState.subscribed.run {
            #expect(try DeletionService.plan([.receipt(receipt)], in: context).summary == mbLoc("This can’t be undone."))
            #expect(try DeletionService.plan([.job(job)], in: context).summary
                    == mbLoc("Its photos and documents are removed too. This can’t be undone."))
            #expect(try DeletionService.plan([.changeOrder(applied)], in: context).summary
                    == mbLoc("Its items come off the invoice too. This can’t be undone."))
            // Mixed: each distinct effect once; the bare "can't be undone" folds into them.
            let mixed = try DeletionService.plan([.customer(customer), .receipt(receipt)], in: context)
            #expect(mixed.summary == mbLoc("Their estimates, invoices, change orders, receipts, and documents are removed too. This can’t be undone."))
            // An invoice that can be deleted holds no payment (law 60), so its words never name one.
            #expect(try DeletionService.plan([.invoice(invoice)], in: context).summary
                    == mbLoc("Their line items, change orders, photos, and documents are removed too. This can’t be undone."))
            #expect(try DeletionService.plan([.invoice(invoice)], in: context).effects
                    == [mbLoc("Their line items, change orders, photos, and documents are removed too.")])
            #expect(mixed.kinds == [.customer, .receipt])
        }
    }

    @Test func everyKindHasItsOwnDeleteOperation() {
        let operations = DeletionService.Kind.allCases.map(\.operation)
        #expect(Set(operations).count == operations.count, "each kind is gated and logged as itself")
        #expect(DeletionService.Kind.payment.operation == .deletePayment)
        #expect(DeletionService.Kind.document.rawValue == "document"
                && DeletionService.Kind.changeOrder.rawValue == "change_order")
    }
}
