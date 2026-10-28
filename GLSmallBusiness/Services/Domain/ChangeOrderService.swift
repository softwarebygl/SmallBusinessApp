//
//  ChangeOrderService.swift
//  GLSmallBusiness
//
//  Every change-order write — the Change Order form, the detail screen's status picker, "Add items
//  to invoice" (on the order and on the invoice), and (later) the assistant's tools. Delete is
//  `DeletionService`'s (it takes the billed items off the invoice first, like un-approving).
//
//  Rules kept from the screens: numbers are CO-#### per invoice from `ChangeOrder.nextNumber`, and
//  the invoice's seed is bumped so a deleted top number is never reused; a credit is stored as a
//  negative unit price; the tax rate is snapshotted from the invoice when the order is created, and
//  again only when a pending order's money changes — never on a title or note edit, and never on an
//  approved order (law 87: a signed document never changes; QA F82); an order already on the
//  invoice is re-pushed after an edit. The paid lock: an order whose items are billed
//  on a paid invoice can't be edited, moved off Approved, or deleted (`isBilledToLockedInvoice`);
//  creating and applying are creates, which the server allows on a paid invoice.
//

import Foundation
import SwiftData

@MainActor
enum ChangeOrderService {

    // MARK: Create / update

    /// Adds a change order to `invoice`. Change orders have no free-tier cap.
    @discardableResult
    static func create(_ draft: ChangeOrderDraft, on invoice: Invoice, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> ChangeOrder {
        try DomainGate.requireCanCreate(ChangeOrder.self, cap: nil, operation: .saveChangeOrder,
                                        in: context, subscription)
        try DomainGate.requireLive(invoice, .saveChangeOrder)
        try validate(draft)
        let number = ChangeOrder.nextNumber(for: invoice)
        let changeOrder = ChangeOrder(number: number, title: "", taxRatePercent: invoice.taxRatePercent)
        changeOrder.invoice = invoice
        context.insert(changeOrder)
        // Remember the minted number so deleting the highest order can't hand it out again.
        if let minted = ChangeOrder.numberValue(of: number) {
            setIfChanged(invoice, \.changeOrderNumberSeed, max(invoice.changeOrderNumberSeed, minted))
        }
        write(draft, to: changeOrder, invoice: invoice, in: context)
        context.saveChanges()
        return changeOrder
    }

    /// Adds a change order to `contract`.
    @discardableResult
    static func create(_ draft: ChangeOrderDraft, on contract: Contract, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> ChangeOrder {
        try DomainGate.requireCanCreate(ChangeOrder.self, cap: nil, operation: .saveChangeOrder,
                                        in: context, subscription)
        try DomainGate.requireLive(contract, .saveChangeOrder)
        try validate(draft)
        let number = ChangeOrder.nextNumber(for: contract)
        let changeOrder = ChangeOrder(number: number, title: "", taxRatePercent: contract.taxRatePercent)
        changeOrder.contract = contract
        context.insert(changeOrder)
        if let minted = ChangeOrder.numberValue(of: number) {
            setIfChanged(contract, \.changeOrderNumberSeed, max(contract.changeOrderNumberSeed, minted))
        }
        write(draft, to: changeOrder, invoice: nil, in: context)
        context.saveChanges()
        return changeOrder
    }

    /// Edits a change order in place. If it is already on the invoice its items are re-pushed so the
    /// invoice bills the edited amounts. Returns false when those items couldn't be matched on the
    /// invoice (a pre-link legacy apply): the order DID save; the invoice needs a hand edit.
    @discardableResult
    static func update(_ changeOrder: ChangeOrder, with draft: ChangeOrderDraft, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> Bool {
        try DomainGate.requireWritable(.saveChangeOrder, subscription)
        try DomainGate.requireLive(changeOrder, .saveChangeOrder)
        if let invoice = changeOrder.invoice {
            try DomainGate.requireLive(invoice, .saveChangeOrder)
            if changeOrder.isBilledToLockedInvoice { throw DomainGate.refusal(.paidLocked, .saveChangeOrder) }
            try validate(draft)
            write(draft, to: changeOrder, invoice: invoice, in: context)
            // Settle the row edits first, so the re-push below reads the saved rows and nothing else.
            context.saveChanges()
            let matched = changeOrder.resyncInvoiceItems(using: context)   // no-op unless applied
            context.saveChanges()
            return matched
        } else if let contract = changeOrder.contract {
            try DomainGate.requireLive(contract, .saveChangeOrder)
            try validate(draft)
            write(draft, to: changeOrder, invoice: nil, in: context)
            context.saveChanges()
            return true
        } else {
            throw DomainGate.refusal(.recordNotFound, .saveChangeOrder)
        }
    }

    // MARK: Status

    /// Pending / Approved / Declined. Moving an order that is on the invoice off Approved takes its
    /// items back off; approving never adds them (that is `applyToInvoice`). Returns false when the
    /// items couldn't be matched on the invoice — the status still changed.
    @discardableResult
    static func setStatus(_ changeOrder: ChangeOrder, _ status: ChangeOrderStatus, in context: ModelContext,
                          subscription: SubscriptionManager? = nil) throws -> Bool {
        try DomainGate.requireWritable(.changeChangeOrderStatus, subscription)
        try DomainGate.requireLive(changeOrder, .changeChangeOrderStatus)
        if changeOrder.isBilledToLockedInvoice, status != .approved {
            throw DomainGate.refusal(.paidLocked, .changeChangeOrderStatus)
        }
        setIfChanged(changeOrder, \.statusRaw, status.rawValue)
        let matched = takeItemsOffIfNotApproved(changeOrder, in: context)
        context.saveChanges()
        return matched
    }

    /// SCREEN-ONLY. The effect of a status that is already written: the detail screen's picker is
    /// bound to the model, so it writes first and its `onChange` (after its own lock and read-only
    /// checks, which drive its alerts) calls this — the same effect `setStatus` has. It re-checks
    /// those same rules so it can never be the unguarded door; a tool calls `setStatus`.
    @discardableResult
    static func settleStatusChange(_ changeOrder: ChangeOrder, in context: ModelContext,
                                   subscription: SubscriptionManager? = nil) throws -> Bool {
        try DomainGate.requireWritable(.changeChangeOrderStatus, subscription)
        try DomainGate.requireLive(changeOrder, .changeChangeOrderStatus)
        if changeOrder.isBilledToLockedInvoice, changeOrder.status != .approved {
            throw DomainGate.refusal(.paidLocked, .changeChangeOrderStatus)
        }
        let matched = takeItemsOffIfNotApproved(changeOrder, in: context)
        context.saveChanges()
        return matched
    }

    /// An order on the invoice that is no longer Approved takes its items back off. False = they
    /// couldn't be matched (a pre-link legacy apply); nothing changed on the invoice.
    private static func takeItemsOffIfNotApproved(_ changeOrder: ChangeOrder, in context: ModelContext) -> Bool {
        guard changeOrder.appliedToInvoice, changeOrder.status != .approved else { return true }
        return changeOrder.removeItemsFromInvoice(using: context)
    }

    // MARK: Apply

    /// Adds an approved order's items to its invoice as a new group (full price, no discount).
    /// Already added = nothing to do.
    static func applyToInvoice(_ changeOrder: ChangeOrder, in context: ModelContext,
                               subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.changeChangeOrderStatus, subscription)
        try DomainGate.requireLive(changeOrder, .changeChangeOrderStatus)
        guard let invoice = changeOrder.invoice else {
            throw DomainGate.refusal(.recordNotFound, .changeChangeOrderStatus)
        }
        try DomainGate.requireLive(invoice, .changeChangeOrderStatus)
        guard !changeOrder.appliedToInvoice else { return }
        guard changeOrder.status == .approved else {
            throw DomainGate.refusal(.changeOrderNotApproved, .changeChangeOrderStatus)
        }
        changeOrder.addItemsToInvoice(using: context)
        context.saveChanges()
    }

    // MARK: Internals

    private static func validate(_ draft: ChangeOrderDraft) throws {
        guard draft.hasNamedItem else { throw DomainGate.refusal(.itemRequired, .saveChangeOrder) }
        for item in draft.items {
            // The price is a magnitude; the sign comes from Charge/Credit.
            try DomainGate.requireNonNegative(item.quantity, abs(item.unitPrice), for: .saveChangeOrder)
        }
    }

    /// The tax rate `changeOrder` holds once `kept` (the draft's named rows) is saved onto it. An
    /// approved order — signed, or already on the invoice — keeps the rate it was signed at, so the
    /// invoice bills exactly what the customer agreed to. A pending order takes the invoice's rate
    /// today only when its money changes (a row's quantity, price, Charge/Credit or Taxable, or a
    /// row added or removed); a title, note or description edit keeps its rate. A new order is
    /// created at the invoice's rate (`create`). The lock preview reads the same answer, so it
    /// prices the save exactly as the save stores it.
    static func taxRateAfterSave(_ changeOrder: ChangeOrder, keeping kept: [ChangeOrderLineDraft],
                                 invoiceRate: Double) -> Double {
        if changeOrder.status == .approved || changeOrder.appliedToInvoice { return changeOrder.taxRatePercent }
        return moneyChanges(changeOrder, keeping: kept) ? invoiceRate : changeOrder.taxRatePercent
    }

    /// True when saving `kept` changes what the order charges: its rows as (quantity, signed unit
    /// price, taxable), compared without regard to their order (a reorder charges the same).
    private static func moneyChanges(_ changeOrder: ChangeOrder, keeping kept: [ChangeOrderLineDraft]) -> Bool {
        struct Money: Hashable { let quantity: Double; let unitPrice: Double; let isTaxable: Bool }
        func counted(_ rows: [Money]) -> [Money: Int] { rows.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        let saved = changeOrder.sortedLineItems.map { Money(quantity: $0.quantity, unitPrice: $0.unitPrice, isTaxable: $0.isTaxable) }
        let drafted = kept.map {
            Money(quantity: $0.quantity, unitPrice: ($0.isCredit ? -1 : 1) * abs($0.unitPrice), isTaxable: $0.isTaxable)
        }
        return counted(saved) != counted(drafted)
    }

    private static func write(_ draft: ChangeOrderDraft, to changeOrder: ChangeOrder, invoice: Invoice?,
                              in context: ModelContext) {
        // Blank rows are dropped; the rest keep the order the form shows them in.
        let kept = draft.items.filter { !DocumentDraftRules.trim($0.name).isEmpty }
        // Read before the rows below are rewritten: it compares the saved rows with the draft.
        let rate = invoice?.taxRatePercent ?? (changeOrder.contract?.taxRatePercent ?? 0)
        setIfChanged(changeOrder, \.taxRatePercent,
                     taxRateAfterSave(changeOrder, keeping: kept, invoiceRate: rate))
        setIfChanged(changeOrder, \.title, DocumentDraftRules.trim(draft.title))
        setIfChanged(changeOrder, \.note, DocumentDraftRules.trim(draft.note))
        setIfChanged(changeOrder, \.statusRaw, draft.status.rawValue)
        RowReconciler.reconcile(
            existing: changeOrder.liveRows(changeOrder.lineItems),
            drafts: kept,
            modelID: { $0.modelID },
            make: { _ in
                let item = ChangeOrderLineItem()
                item.changeOrder = changeOrder      // inverse set BEFORE insert, as every form does
                context.insert(item)
                return item
            },
            update: { item, line, index in
                setIfChanged(item, \.name, DocumentDraftRules.trim(line.name))
                setIfChanged(item, \.quantity, line.quantity)
                setIfChanged(item, \.unit, line.unit)
                // Credits are stored as a negative unit price; the draft holds the magnitude.
                setIfChanged(item, \.unitPrice, (line.isCredit ? -1 : 1) * abs(line.unitPrice))
                setIfChanged(item, \.isTaxable, line.isTaxable)
                setIfChanged(item, \.sortIndex, index)
            },
            delete: { context.deleteSynced($0) })
    }
}
