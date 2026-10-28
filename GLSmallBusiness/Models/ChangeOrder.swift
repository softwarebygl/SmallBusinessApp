//
//  ChangeOrder.swift
//  GLSmallBusiness
//
//  A change order amends an invoice's scope mid-job: it lists the added (or removed) work, the
//  price change, and the revised total, and carries an approval status so there's a paper trail.
//  Added items can optionally be pushed onto the invoice as a new line-item group.
//
//  NOTE (schema): pre-launch, these new @Models fold into GLSchemaV1 (see GLSchema.swift). The
//  added `Invoice.changeOrders` relationship is optional/additive, per the CloudKit rules.
//

import Foundation
import SwiftData

enum ChangeOrderStatus: String, Codable, CaseIterable, Identifiable {
    case pending, approved, declined
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pending: return mbLoc("Pending")
        case .approved: return mbLoc("Approved")
        case .declined: return mbLoc("Declined")
        }
    }
}

@Model
final class ChangeOrder {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var number: String = ""
    var title: String = ""
    var createdAt: Date = Date.now
    var note: String = ""
    var statusRaw: String = ChangeOrderStatus.pending.rawValue
    /// Tax rate snapshot from the invoice at creation, applied to taxable change items.
    var taxRatePercent: Double = 0
    /// True once the items have been pushed onto the invoice as a group (prevents double-adding).
    var appliedToInvoice: Bool = false

    var invoice: Invoice?
    var contract: Contract?

    /// The invoice group this order's items were pushed into (set on apply). Cascade, so deleting an
    /// applied order always removes its billed items from the invoice too — the invoice can never keep
    /// charging for a change order that no longer exists. Optional/additive per the CloudKit rules;
    /// nil for orders applied before this link existed (see `legacyAppliedGroup`).
    @Relationship(deleteRule: .cascade, inverse: \InvoiceGroup.changeOrder)
    var invoiceGroup: InvoiceGroup?

    @Relationship(deleteRule: .cascade, inverse: \ChangeOrderLineItem.changeOrder)
    var lineItems: [ChangeOrderLineItem]?

    init(number: String = "", title: String = "", createdAt: Date = .now, taxRatePercent: Double = 0) {
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.taxRatePercent = taxRatePercent
    }
}

extension ChangeOrder {
    var status: ChangeOrderStatus {
        get { ChangeOrderStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var sortedLineItems: [ChangeOrderLineItem] {
        liveRows(lineItems).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Pushes this change order's items onto its invoice as a new line-item group (charged at full price,
    /// flagged `fromChangeOrder` so the invoice's overall discount won't re-rate them) and marks it applied
    /// so its amount is counted exactly once. No-op unless it's approved and not already applied.
    func addItemsToInvoice(using context: ModelContext) {
        guard let invoice, status == .approved, !appliedToInvoice else { return }
        let groupName = title.isEmpty ? number : "\(number): \(title)"
        let group = InvoiceGroup(name: groupName, sortIndex: (invoice.sortedGroups.last?.sortIndex ?? 0) + 1)
        group.invoice = invoice
        group.changeOrder = self   // so delete/edit/decline can find exactly these items later
        context.insert(group)
        for (index, item) in sortedLineItems.enumerated() {
            let li = InvoiceLineItem(
                name: item.name, details: item.details, quantity: item.quantity,
                unit: item.unit, unitPrice: item.unitPrice, kind: .labor,
                isTaxable: item.isTaxable, sortIndex: index
            )
            li.fromChangeOrder = true
            li.group = group
            context.insert(li)
        }
        appliedToInvoice = true
    }

    /// Pulls this order's items back off the invoice (deleting the group it pushed) and clears the
    /// applied flag, so the invoice never bills for an order that was edited, declined, or removed.
    /// Returns false when the group can't be identified (a pre-link legacy apply with more than one
    /// candidate) — the caller should tell the user to remove the items from the invoice by hand.
    // @MainActor because it routes through `deleteSynced`, which queues the wire op off
    // the live object graph before the rows go — main-context work. Every caller is a
    // SwiftUI view already on the main actor.
    @MainActor
    @discardableResult
    func removeItemsFromInvoice(using context: ModelContext) -> Bool {
        guard appliedToInvoice else { return true }
        guard let group = invoiceGroup ?? legacyAppliedGroup else { return false }
        // deleteSynced, not delete: the group's own subtree (its line items) has to be read
        // for the wire while it is still attached — see GLSyncDeleteRouting.swift.
        context.deleteSynced(group)   // cascades to its line items
        invoiceGroup = nil
        appliedToInvoice = false
        return true
    }

    /// Re-pushes the current items after an edit to an already-applied order, keeping the group's
    /// position — the invoice always bills what the order says, never a stale copy.
    // @MainActor because it routes through `deleteSynced`, which queues the wire op off
    // the live object graph before the rows go — main-context work. Every caller is a
    // SwiftUI view already on the main actor.
    @MainActor
    @discardableResult
    func resyncInvoiceItems(using context: ModelContext) -> Bool {
        guard appliedToInvoice else { return true }
        let oldSortIndex = (invoiceGroup ?? legacyAppliedGroup)?.sortIndex
        guard removeItemsFromInvoice(using: context) else { return false }
        guard status == .approved else { return true }   // no longer approved → items stay off
        addItemsToInvoice(using: context)
        if let oldSortIndex, let group = invoiceGroup { group.sortIndex = oldSortIndex }
        return true
    }

    /// Fallback identification for groups pushed before the group↔order link existed: only safe when
    /// this is the invoice's single applied order and exactly one unlinked all-change-order group exists.
    private var legacyAppliedGroup: InvoiceGroup? {
        guard let invoice else { return nil }
        let appliedOrders = invoice.liveRows(invoice.changeOrders).filter(\.appliedToInvoice)
        guard appliedOrders.count == 1 else { return nil }
        let candidates = invoice.liveRows(invoice.groups).filter { group in
            guard group.changeOrder == nil, let items = group.lineItems, !items.isEmpty else { return false }
            return items.allSatisfy(\.fromChangeOrder)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// This order's money, exact — `ChangeOrderMath` over its items at its snapshotted tax rate.
    var totals: ChangeOrderMath.Totals {
        ChangeOrderMath.totals(lines: sortedLineItems.map { ($0.exactLineTotal, $0.isTaxable) },
                               taxRatePercent: taxRatePercent)
    }

    /// Sum of line totals — negative when the change removes scope (a credit). Rounded once.
    var subtotal: Double { totals.subtotal }

    var taxAmount: Double { totals.tax }

    /// The price change this order represents (can be negative). Rounded once.
    var total: Double { totals.total }

    var customer: Customer? {
        invoice?.customer ?? contract?.customer
    }

    var customerDisplayName: String {
        if let invoice { return invoice.customerDisplayName }
        if let contract { return contract.displayCustomerName }
        return ""
    }

    var customerBusinessName: String? {
        invoice?.customerBusinessName ?? contract?.customer?.businessName
    }

    var customerFirstName: String {
        if let invoice { return invoice.customerFirstName }
        if let live = contract?.customer {
            let fn = live.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fn.isEmpty { return fn }
            let name = live.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return contract?.customerName ?? ""
    }

    var recipientEmail: String {
        let live = (invoice?.recipientEmail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        return contract?.recipientEmail ?? ""
    }

    var recipientPhone: String {
        let live = (invoice?.recipientPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        return contract?.recipientPhone ?? ""
    }

    var projectTitle: String {
        let invTitle = invoice?.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !invTitle.isEmpty { return invTitle }
        let contractTitle = contract?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !contractTitle.isEmpty { return contractTitle }
        return ""
    }

    /// CO-0001 style, sequenced per invoice — max(seed, highest existing) + 1, so deleting the
    /// highest order can't hand its number to the next one (the invoice's `changeOrderNumberSeed`
    /// remembers every number ever minted). The caller bumps the seed after assigning the number,
    /// via `numberValue(of:)`.
    static func nextNumber(for invoice: Invoice) -> String {
        nextNumber(after: invoice.sortedChangeOrders, seed: invoice.changeOrderNumberSeed)
    }

    /// CO-0001 style, sequenced per contract.
    static func nextNumber(for contract: Contract) -> String {
        nextNumber(after: contract.sortedChangeOrders, seed: contract.changeOrderNumberSeed)
    }

    static func nextNumber(after existing: [ChangeOrder], seed: Int = 0) -> String {
        let highest = existing.compactMap { numberValue(of: $0.number) }.max() ?? 0
        return String(format: "CO-%04d", max(seed, highest) + 1)
    }

    /// The numeric part of a CO number ("CO-0004" → 4), or nil when non-numeric. Callers use it
    /// to bump `Invoice.changeOrderNumberSeed` or `Contract.changeOrderNumberSeed` after minting.
    static func numberValue(of number: String) -> Int? {
        Int(number.replacingOccurrences(of: "CO-", with: ""))
    }
}

@Model
final class ChangeOrderLineItem {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.job
    var unitPrice: Double = 0
    var isTaxable: Bool = false
    var sortIndex: Int = 0

    var changeOrder: ChangeOrder?

    init(name: String = "", details: String = "", quantity: Double = 1,
         unit: UnitOfMeasure = .job, unitPrice: Double = 0, isTaxable: Bool = false, sortIndex: Int = 0) {
        self.name = name
        self.details = details
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.isTaxable = isTaxable
        self.sortIndex = sortIndex
    }

    /// quantity × unit price (a credit carries a negative price), exact.
    var exactLineTotal: Decimal { DomainMoney.product(quantity, unitPrice) }
    /// The same, rounded once — what the line shows.
    var lineTotal: Double { DomainMoney.roundedToCents(exactLineTotal) }
}

// ChangeOrderMath is shared via GLChangeOrderMath from GoldLifeDocuments.
