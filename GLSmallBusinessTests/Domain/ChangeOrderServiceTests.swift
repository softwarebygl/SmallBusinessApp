//
//  ChangeOrderServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The one change-order save path: the form, the status picker, "Add items to invoice" on both
//  screens, delete from the detail screen and the lists, and the assistant.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct ChangeOrderServiceTests {

    private func draft(_ items: [ChangeOrderLineDraft]? = nil, title: String = " Sealer ") -> ChangeOrderDraft {
        ChangeOrderDraft(title: title, note: " Signed on site ",
                         items: items ?? [ChangeOrderLineDraft(name: " Extra coat ", unitPrice: 200, isTaxable: true)])
    }

    // MARK: Create / update

    @Test func createNumbersPerInvoiceBumpsTheSeedAndSnapshotsTax() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 10, in: context)
        invoice.changeOrderNumberSeed = 4          // CO-0004 was minted once and deleted
        context.saveChanges()

        let items = [ChangeOrderLineDraft(name: "Extra coat", unitPrice: 200, isTaxable: true),
                     ChangeOrderLineDraft(name: "Skip trim", unitPrice: 50, isCredit: true),
                     ChangeOrderLineDraft(name: "  ", unitPrice: 999)]
        let order = try DomainState.neverSubscribed.run {   // change orders are never capped
            try ChangeOrderService.create(draft(items), on: invoice, in: context)
        }
        #expect(order.number == "CO-0005" && invoice.changeOrderNumberSeed == 5)
        #expect(order.title == "Sealer" && order.note == "Signed on site")
        #expect(order.taxRatePercent == 10 && order.status == .pending && !order.appliedToInvoice)
        #expect(order.sortedLineItems.map(\.unitPrice) == [200, -50], "blank row dropped; the credit stored negative")
        #expect(order.total == 150 + 20)
        #expect(order.syncID != nil && !context.hasChanges)
    }

    @Test func createRefusals() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        context.saveChanges()
        #expect(DomainState.subscribed.run {
            domainError { try ChangeOrderService.create(draft([ChangeOrderLineDraft(name: " ", unitPrice: 1)]), on: invoice, in: context) }
        } == .itemRequired)
        #expect(DomainState.lapsed.run { domainError { try ChangeOrderService.create(draft(), on: invoice, in: context) } }
                == .readOnly(operation: "saveChangeOrder", lapsed: true))
        #expect(DomainState.subscribed.run {
            domainError { try ChangeOrderService.create(draft([ChangeOrderLineDraft(name: "X", quantity: -1, unitPrice: 1)]), on: invoice, in: context) }
        } == .negativeValue)
        #expect(try context.fetchCount(FetchDescriptor<ChangeOrder>()) == 0)
    }

    @Test func editingAnAppliedOrderRepushesItsItemsAndKeepsItsRate() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, lines: [(100, false)], in: context)
        context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: context) }
        #expect(invoice.total == 1100)
        let position = try #require(order.invoiceGroup?.sortIndex)

        invoice.taxRatePercent = 5
        context.saveChanges()
        var edit = ChangeOrderDraft(order)
        edit.items[0].unitPrice = 300
        let matched = try DomainState.subscribed.run { try ChangeOrderService.update(order, with: edit, in: context) }
        #expect(matched)
        #expect(order.taxRatePercent == 0, "an approved order keeps the rate it was signed at (law 87, QA F82)")
        #expect(order.invoiceGroup?.sortIndex == position, "re-pushed in the same place")
        #expect(invoice.total == 1300, "the invoice bills the edited amount (nothing here is taxable)")
        #expect(!context.hasChanges)
    }

    // MARK: The order's tax rate (law 87: a signed document never changes; QA F82)

    /// Renaming an order is not a money edit: it keeps the rate it has, whatever the invoice's
    /// rate is now (it used to re-snapshot on every save).
    @Test func aTitleOnlyEditKeepsTheOrdersRate() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 6, in: context)
        context.saveChanges()
        let order = try DomainState.subscribed.run { try ChangeOrderService.create(draft(), on: invoice, in: context) }
        #expect(order.taxRatePercent == 6 && order.total == 212)

        invoice.taxRatePercent = 7
        context.saveChanges()
        var edit = ChangeOrderDraft(order)
        edit.title = "Sealer, two coats"
        edit.note = "Re-signed"
        edit.items[0].name = "Extra sealer coat"
        _ = try DomainState.subscribed.run { try ChangeOrderService.update(order, with: edit, in: context) }
        #expect(order.title == "Sealer, two coats")
        #expect(order.taxRatePercent == 6 && order.total == 212, "a title-only edit never re-rates the order")
    }

    /// A pending order whose money changes is re-priced, so it takes the invoice's rate today.
    @Test func aMoneyEditOnAPendingOrderTakesTheInvoicesRate() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 6, in: context)
        context.saveChanges()
        let order = try DomainState.subscribed.run { try ChangeOrderService.create(draft(), on: invoice, in: context) }
        invoice.taxRatePercent = 7
        context.saveChanges()

        var edit = ChangeOrderDraft(order)
        edit.items[0].unitPrice = 300
        _ = try DomainState.subscribed.run { try ChangeOrderService.update(order, with: edit, in: context) }
        #expect(order.taxRatePercent == 7 && order.total == 321)
        #expect(ChangeOrderService.taxRateAfterSave(order, keeping: ChangeOrderDraft(order).items, invoiceRate: 9) == 7,
                "nothing changed, nothing re-rated")
    }

    /// An approved order is signed: even a money edit keeps the rate it was signed at.
    @Test func anApprovedOrderKeepsItsRateOnAMoneyEdit() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 6, in: context)
        let order = TS.changeOrder(invoice, status: .approved, taxRatePercent: 6, lines: [(100, true)], in: context)
        context.saveChanges()
        invoice.taxRatePercent = 7
        context.saveChanges()

        var edit = ChangeOrderDraft(order)
        edit.items[0].unitPrice = 200
        _ = try DomainState.subscribed.run { try ChangeOrderService.update(order, with: edit, in: context) }
        #expect(order.taxRatePercent == 6 && order.total == 212)
    }

    @Test func anOrderBilledToAPaidInvoiceIsLocked() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, lines: [(100, false)], in: context)
        context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: context) }
        TS.pay(invoice, 1100, in: context)
        context.saveChanges()
        #expect(order.isBilledToLockedInvoice)

        try DomainState.subscribed.run {
            #expect(domainError { try ChangeOrderService.update(order, with: ChangeOrderDraft(order), in: context) } == .paidLocked)
            #expect(domainError { try ChangeOrderService.setStatus(order, .declined, in: context) } == .paidLocked)
            #expect(domainError { _ = try DeletionService.delete([.changeOrder(order)], evenIfItemsUnmatched: true, in: context) } == .paidLocked)
            // Staying Approved is not a change to the billed money.
            try ChangeOrderService.setStatus(order, .approved, in: context)
            // A new order on a paid invoice is a create — allowed.
            _ = try ChangeOrderService.create(draft(), on: invoice, in: context)
        }
        #expect(order.status == .approved && order.appliedToInvoice)
        #expect(invoice.sortedChangeOrders.count == 2)
    }

    // MARK: Status / apply

    @Test func unapprovingTakesItsItemsBackOffAndApprovingNeverAddsThem() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .pending, lines: [(100, false)], in: context)
        context.saveChanges()

        try DomainState.subscribed.run {
            #expect(domainError { try ChangeOrderService.applyToInvoice(order, in: context) } == .changeOrderNotApproved)
            #expect(try ChangeOrderService.setStatus(order, .approved, in: context))
            #expect(!order.appliedToInvoice, "approving does not bill")
            try ChangeOrderService.applyToInvoice(order, in: context)
            try ChangeOrderService.applyToInvoice(order, in: context)   // already on: nothing to do
        }
        #expect(invoice.total == 1100 && invoice.sortedGroups.count == 2)

        let matched = try DomainState.subscribed.run { try ChangeOrderService.setStatus(order, .declined, in: context) }
        #expect(matched)
        #expect(!order.appliedToInvoice && invoice.total == 1000 && invoice.sortedGroups.count == 1)
        #expect(!context.hasChanges)
        #expect(DomainState.offline.run { domainError { _ = try ChangeOrderService.setStatus(order, .pending, in: context) } }
                == .readOnly(operation: "changeChangeOrderStatus", lapsed: false))
    }

    @Test func settleStatusChangeIsTheSameEffectForThePicker() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, lines: [(100, false)], in: context)
        context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: context) }
        order.status = .pending                                   // the picker's own write
        #expect(try DomainState.subscribed.run { try ChangeOrderService.settleStatusChange(order, in: context) })
        #expect(!order.appliedToInvoice && invoice.total == 1000 && !context.hasChanges)
    }

    /// Screen-only, but never an unguarded door: read-only, a gone record, and moving an order
    /// billed to a paid invoice off Approved are all refused, and nothing comes off the invoice.
    @Test func settleStatusChangeRefusesWhatSetStatusRefuses() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, lines: [(100, false)], in: context)
        context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(order, in: context) }
        order.status = .pending
        #expect(DomainState.lapsed.run { domainError { _ = try ChangeOrderService.settleStatusChange(order, in: context) } }
                == .readOnly(operation: "changeChangeOrderStatus", lapsed: true))
        #expect(order.appliedToInvoice)
        order.status = .approved
        context.saveChanges()
        TS.pay(invoice, invoice.total, in: context)                 // now paid: its billing is locked
        context.saveChanges()
        order.status = .declined
        #expect(DomainState.subscribed.run { domainError { _ = try ChangeOrderService.settleStatusChange(order, in: context) } }
                == .paidLocked)
        #expect(order.appliedToInvoice && invoice.sortedGroups.count == 2)
    }

    // MARK: Delete (through DeletionService, the one door)

    @Test func deleteTakesBilledItemsOffAndCascades() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let applied = TS.changeOrder(invoice, number: "CO-0001", status: .approved, lines: [(100, false)], in: context)
        let pending = TS.changeOrder(invoice, number: "CO-0002", lines: [(50, false)], in: context)
        context.saveChanges()
        try DomainState.subscribed.run { try ChangeOrderService.applyToInvoice(applied, in: context) }

        #expect(DomainState.lapsed.run { domainError { _ = try DeletionService.delete([.changeOrder(applied)], evenIfItemsUnmatched: false, in: context) } }
                == .readOnly(operation: "deleteChangeOrder", lapsed: true))

        let outcome = try DomainState.subscribed.run {
            try DeletionService.delete([.changeOrder(applied), .changeOrder(pending)], evenIfItemsUnmatched: false, in: context)
        }
        #expect(outcome == .deleted(.init(deleted: 2, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false)))
        #expect(try context.fetchCount(FetchDescriptor<ChangeOrder>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChangeOrderLineItem>()) == 0)
        #expect(invoice.total == 1000 && invoice.sortedGroups.count == 1)
        #expect(!context.hasChanges)
    }

    /// A pre-link legacy apply whose group can't be told apart: the detail screen stops and asks,
    /// the lists delete anyway and say so.
    @Test func unmatchedItemsStopOrProceedAsAsked() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, applied: true, lines: [(100, false)], in: context)
        context.saveChanges()          // applied, but no linked group and no legacy candidate

        let stop = try DomainState.subscribed.run { try DeletionService.delete([.changeOrder(order)], evenIfItemsUnmatched: false, in: context) }
        #expect(stop == .itemsUnmatched)
        #expect(try context.fetchCount(FetchDescriptor<ChangeOrder>()) == 1)

        let proceed = try DomainState.subscribed.run { try DeletionService.delete([.changeOrder(order)], evenIfItemsUnmatched: true, in: context) }
        #expect(proceed == .deleted(.init(deleted: 1, itemsLeftOnInvoice: true, tripsOtherDevicesBreaker: false)))
        #expect(try context.fetchCount(FetchDescriptor<ChangeOrder>()) == 0)
    }

    // MARK: Contract change orders

    @Test func createOnContractNumbersBumpsSeedAndUpdatesContractedValue() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        customer.email = "adrian@example.com"
        customer.phoneNumber = "555-1234"
        let contract = Contract(
            number: "CON-0001",
            title: "Kitchen Remodel",
            customerName: customer.listDisplayName,
            agreedPrice: 5000,
            status: .signed,
            customer: customer
        )
        contract.changeOrderNumberSeed = 2
        context.insert(contract)
        context.saveChanges()

        let items = [ChangeOrderLineDraft(name: "Under-cabinet lighting", unitPrice: 500, isTaxable: false)]
        let order = try DomainState.neverSubscribed.run {
            try ChangeOrderService.create(draft(items, title: "Lighting"), on: contract, in: context)
        }

        #expect(order.number == "CO-0003")
        #expect(contract.changeOrderNumberSeed == 3)
        #expect(order.title == "Lighting")
        #expect(order.contract === contract)
        #expect(order.invoice == nil)
        #expect(order.customerDisplayName == customer.fullName)
        #expect(order.recipientEmail == "adrian@example.com")
        #expect(order.recipientPhone == "555-1234")
        #expect(order.projectTitle == "Kitchen Remodel")
        #expect(contract.sortedChangeOrders.count == 1)
        #expect(contract.contractedValue == 5000, "pending order does not increase contracted value yet")

        // Status changed to approved
        _ = try DomainState.subscribed.run {
            try ChangeOrderService.setStatus(order, .approved, in: context)
        }
        #expect(order.status == .approved)
        #expect(contract.contractedValue == 5500, "approved order increases contracted value")

        // Status changed to declined
        _ = try DomainState.subscribed.run {
            try ChangeOrderService.setStatus(order, .declined, in: context)
        }
        #expect(order.status == .declined)
        #expect(contract.contractedValue == 5000, "declined order removes increase")

        // Update change order in place
        var edit = ChangeOrderDraft(order)
        edit.title = "Lighting & Dimmer"
        edit.items[0].unitPrice = 750
        let updated = try DomainState.subscribed.run {
            try ChangeOrderService.update(order, with: edit, in: context)
        }
        #expect(updated)
        #expect(order.title == "Lighting & Dimmer")
        #expect(order.total == 750)

        // Delete contract change order
        let deleteOutcome = try DomainState.subscribed.run {
            try DeletionService.delete([.changeOrder(order)], evenIfItemsUnmatched: false, in: context)
        }
        #expect(deleteOutcome == .deleted(.init(deleted: 1, itemsLeftOnInvoice: false, tripsOtherDevicesBreaker: false)))
        #expect(contract.sortedChangeOrders.isEmpty)
    }
}
