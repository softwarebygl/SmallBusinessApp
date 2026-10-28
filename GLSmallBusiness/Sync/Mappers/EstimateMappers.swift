//
//  EstimateMappers.swift
//  GLSmallBusiness
//
//  GLSync payload mappers for the quoting side of the app: an estimate, the groups that
//  organize its lines, those lines, and the change orders that amend an invoice mid-job plus
//  their lines. See GLSYNC-SPEC.md §6 for the rules and gl-business-api/sync-manifest.json
//  for the server's per-type enforcement — every `glSyncType` below is a manifest key,
//  spelled exactly as the manifest spells it.
//
//  Payload keys are the SWIFT property names verbatim, so the manifest's protected /
//  status_transitions lists match with no translation table in between. Hand-written on
//  purpose (the no-AI-contingency rule): the regression net is the round-trip test plus the
//  property audit at the bottom of this file.
//
//  Derived money never rides: subtotal, lineDiscount, lineTotal, taxAmount, total and
//  depositAmount are all recomputed from the fields below, and a stale total must not be able
//  to land on a document a customer is about to read.
//

import Foundation
import SwiftData
import GoldLifeDocuments

// MARK: - Shared file utilities

/// True when the payload actually carries this key.
///
/// A pulled payload can be a PATCH — only the fields the other device touched — so an ABSENT
/// key means "not part of this change" and the local value has to survive it. Scalars express
/// that by passing their CURRENT value as the read fallback; optionals, enums and references
/// need this check instead, because for them a nil read is ambiguous between "absent" and
/// "explicitly cleared".
///
/// `private` rather than internal deliberately: each mapper file keeps its own copy, and a
/// module-scope copy per file would be a duplicate declaration.
private nonisolated func glSyncHas(_ payload: GLSyncPayload, _ key: String) -> Bool {
    payload.index(forKey: key) != nil
}

/// Resolve a reference (a payload uuid) to the local record it names.
///
/// One concrete lookup per type on purpose: a `#Predicate` cannot reach a protocol member
/// through a generic (the limitation SyncIdentityBackfill documents), so there is no single
/// generic `syncID` fetch to share.
///
/// A missing referent is NOT an error: parents and children arrive in whatever order the
/// server pages them, so an unresolved id means "not on this device yet". The link is left
/// as it stands — nil on a freshly pulled record — and a later pull re-applies the payload
/// once the referent exists. Never fabricate a row to hang the link on.
private enum EstimateRefLookup {

    static func customer(_ id: UUID?, in context: ModelContext) -> Customer? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Customer>(predicate: #Predicate<Customer> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func estimate(_ id: UUID?, in context: ModelContext) -> Estimate? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Estimate>(predicate: #Predicate<Estimate> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func estimateGroup(_ id: UUID?, in context: ModelContext) -> EstimateGroup? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<EstimateGroup>(predicate: #Predicate<EstimateGroup> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func invoice(_ id: UUID?, in context: ModelContext) -> Invoice? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate<Invoice> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func invoiceGroup(_ id: UUID?, in context: ModelContext) -> InvoiceGroup? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<InvoiceGroup>(predicate: #Predicate<InvoiceGroup> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func changeOrder(_ id: UUID?, in context: ModelContext) -> ChangeOrder? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<ChangeOrder>(predicate: #Predicate<ChangeOrder> { $0.syncID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

// MARK: - Estimate

extension Estimate: GLSyncMappable {

    static var glSyncType: String { "estimate" }

    /// The manifest cascades an estimate off its customer.
    var glSyncParentID: UUID? { customer?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "number": GLSyncValue.string(number),
            "jobTitle": GLSyncValue.string(jobTitle),
            "createdAt": GLSyncValue.date(createdAt),
            "validUntil": GLSyncValue.date(validUntil),
            // A native Codable enum still rides as its raw string, under its own property name.
            // `isExpired` is derived from validUntil + status and is never sent.
            "status": GLSyncValue.raw(status),
            // Customer snapshot, frozen at creation: the server never "fixes these up" from the
            // live customer, so they ride as plain values rather than as a lookup.
            "customerFirstName": GLSyncValue.string(customerFirstName),
            "customerLastName": GLSyncValue.string(customerLastName),
            "customerBusinessName": GLSyncValue.optional(customerBusinessName),
            "customerEmail": GLSyncValue.string(customerEmail),
            "customerPhone": GLSyncValue.string(customerPhone),
            // Objects, never flattened columns — the server stores each one whole.
            "customerAddress": GLSyncValue.address(customerAddress),
            "serviceAddress": GLSyncValue.address(serviceAddress),
            "taxRatePercent": GLSyncValue.double(taxRatePercent),
            "combineTotals": GLSyncValue.bool(combineTotals),
            "discountType": GLSyncValue.raw(discountType),
            "discountValue": GLSyncValue.double(discountValue),
            "depositType": GLSyncValue.raw(depositType),
            "depositValue": GLSyncValue.double(depositValue),
            "customerNotes": GLSyncValue.string(customerNotes),
            "terms": GLSyncValue.string(terms),
            // The cascade parent rides here as well as in `glSyncParentID`: that property is
            // get-only, so the payload is the only way an applying device can re-attach a
            // pulled estimate to its customer.
            "customer": GLSyncValue.uuid(customer?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        // Identity is never cleared: a nil id would orphan the record from its server row.
        if glSyncHas(payload, "syncID") { syncID = GLSyncValue.uuid(payload, "syncID") ?? syncID }
        if glSyncHas(payload, "updatedAt") { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        number = GLSyncValue.string(payload, "number", default: number)
        jobTitle = GLSyncValue.string(payload, "jobTitle", default: jobTitle)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        validUntil = GLSyncValue.date(payload, "validUntil") ?? validUntil
        if glSyncHas(payload, "status") {
            // An unreadable status degrades to the model's own default rather than failing the
            // record — a newer build's case must never brick this one.
            status = GLSyncValue.raw(payload, "status", default: EstimateStatus.draft)
        }

        customerFirstName = GLSyncValue.string(payload, "customerFirstName", default: customerFirstName)
        customerLastName = GLSyncValue.string(payload, "customerLastName", default: customerLastName)
        if glSyncHas(payload, "customerBusinessName") {
            customerBusinessName = GLSyncValue.optionalString(payload, "customerBusinessName")
        }
        customerEmail = GLSyncValue.string(payload, "customerEmail", default: customerEmail)
        customerPhone = GLSyncValue.string(payload, "customerPhone", default: customerPhone)
        customerAddress = GLSyncValue.address(payload, "customerAddress") ?? customerAddress
        serviceAddress = GLSyncValue.address(payload, "serviceAddress") ?? serviceAddress

        taxRatePercent = GLSyncValue.double(payload, "taxRatePercent", default: taxRatePercent)
        combineTotals = GLSyncValue.bool(payload, "combineTotals", default: combineTotals)
        if glSyncHas(payload, "discountType") {
            discountType = GLSyncValue.raw(payload, "discountType", default: AdjustmentType.none)
        }
        discountValue = GLSyncValue.double(payload, "discountValue", default: discountValue)
        if glSyncHas(payload, "depositType") {
            depositType = GLSyncValue.raw(payload, "depositType", default: AdjustmentType.none)
        }
        depositValue = GLSyncValue.double(payload, "depositValue", default: depositValue)

        customerNotes = GLSyncValue.string(payload, "customerNotes", default: customerNotes)
        terms = GLSyncValue.string(payload, "terms", default: terms)

        if glSyncHas(payload, "customer") {
            let incoming = GLSyncValue.uuid(payload, "customer")
            if let resolved = EstimateRefLookup.customer(incoming, in: context) {
                customer = resolved
            } else if incoming == nil {
                customer = nil          // explicitly cleared upstream
            }
            // Otherwise the customer has not been pulled to this device yet: leave the link
            // nil and let a later pull wire it up.
        }
    }
}

// MARK: - Estimate group

extension EstimateGroup: GLSyncMappable {

    static var glSyncType: String { "estimate_group" }

    var glSyncParentID: UUID? { estimate?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "note": GLSyncValue.string(note),
            "sortIndex": GLSyncValue.int(sortIndex),
            "estimate": GLSyncValue.uuid(estimate?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if glSyncHas(payload, "syncID") { syncID = GLSyncValue.uuid(payload, "syncID") ?? syncID }
        if glSyncHas(payload, "updatedAt") { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        name = GLSyncValue.string(payload, "name", default: name)
        note = GLSyncValue.string(payload, "note", default: note)
        sortIndex = GLSyncValue.int(payload, "sortIndex", default: sortIndex)

        if glSyncHas(payload, "estimate") {
            let incoming = GLSyncValue.uuid(payload, "estimate")
            if let resolved = EstimateRefLookup.estimate(incoming, in: context) {
                estimate = resolved
            } else if incoming == nil {
                estimate = nil
            }
            // Unresolved = the estimate has not arrived yet; leave it nil for a later pull.
        }
    }
}

// MARK: - Estimate line item

extension EstimateLineItem: GLSyncMappable {

    static var glSyncType: String { "estimate_line_item" }

    var glSyncParentID: UUID? { group?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "details": GLSyncValue.string(details),
            "quantity": GLSyncValue.double(quantity),
            "unit": GLSyncValue.raw(unit),
            "unitPrice": GLSyncValue.double(unitPrice),
            "kind": GLSyncValue.raw(kind),
            "isTaxable": GLSyncValue.bool(isTaxable),
            "sortIndex": GLSyncValue.int(sortIndex),
            // The per-line discount TYPE rides with its VALUE: a type flip alone changes the
            // money, which is why the manifest protects both.
            "discountType": GLSyncValue.raw(discountType),
            "discountValue": GLSyncValue.double(discountValue),
            "group": GLSyncValue.uuid(group?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if glSyncHas(payload, "syncID") { syncID = GLSyncValue.uuid(payload, "syncID") ?? syncID }
        if glSyncHas(payload, "updatedAt") { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        name = GLSyncValue.string(payload, "name", default: name)
        details = GLSyncValue.string(payload, "details", default: details)
        quantity = GLSyncValue.double(payload, "quantity", default: quantity)
        if glSyncHas(payload, "unit") {
            unit = GLSyncValue.raw(payload, "unit", default: UnitOfMeasure.squareFoot)
        }
        unitPrice = GLSyncValue.double(payload, "unitPrice", default: unitPrice)
        if glSyncHas(payload, "kind") {
            kind = GLSyncValue.raw(payload, "kind", default: LineItemKind.labor)
        }
        isTaxable = GLSyncValue.bool(payload, "isTaxable", default: isTaxable)
        sortIndex = GLSyncValue.int(payload, "sortIndex", default: sortIndex)
        if glSyncHas(payload, "discountType") {
            discountType = GLSyncValue.raw(payload, "discountType", default: AdjustmentType.none)
        }
        discountValue = GLSyncValue.double(payload, "discountValue", default: discountValue)

        if glSyncHas(payload, "group") {
            let incoming = GLSyncValue.uuid(payload, "group")
            if let resolved = EstimateRefLookup.estimateGroup(incoming, in: context) {
                group = resolved
            } else if incoming == nil {
                group = nil
            }
            // Unresolved = the group has not arrived yet; leave it nil for a later pull.
        }
    }
}

// MARK: - Change order

extension ChangeOrder: GLSyncMappable {

    static var glSyncType: String { "change_order" }

    /// Cascades off the invoice it amends. NOT paid-locked: a change order is the sanctioned
    /// way to add work to an invoice that is already paid.
    var glSyncParentID: UUID? { invoice?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "number": GLSyncValue.string(number),
            "title": GLSyncValue.string(title),
            "createdAt": GLSyncValue.date(createdAt),
            "note": GLSyncValue.string(note),
            // Written through the `status` accessor, which already folds an unreadable stored
            // raw down to `.pending`; the key stays `statusRaw` because that is the stored
            // property name and the manifest's status_transitions table keys on it.
            "statusRaw": GLSyncValue.raw(status),
            // A creation-time snapshot of the invoice's rate, never re-read from the invoice.
            "taxRatePercent": GLSyncValue.double(taxRatePercent),
            "appliedToInvoice": GLSyncValue.bool(appliedToInvoice),
            "invoice": GLSyncValue.uuid(invoice?.syncID),
            // The invoice group this order's items were pushed into. Mirrored by
            // `InvoiceGroup.changeOrder` on the other side; SwiftData keeps the two in step, so
            // whichever row lands first establishes the edge.
            "invoiceGroup": GLSyncValue.uuid(invoiceGroup?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if glSyncHas(payload, "syncID") { syncID = GLSyncValue.uuid(payload, "syncID") ?? syncID }
        if glSyncHas(payload, "updatedAt") { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        number = GLSyncValue.string(payload, "number", default: number)
        title = GLSyncValue.string(payload, "title", default: title)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        note = GLSyncValue.string(payload, "note", default: note)
        if glSyncHas(payload, "statusRaw") {
            status = GLSyncValue.raw(payload, "statusRaw", default: ChangeOrderStatus.pending)
        }
        taxRatePercent = GLSyncValue.double(payload, "taxRatePercent", default: taxRatePercent)
        appliedToInvoice = GLSyncValue.bool(payload, "appliedToInvoice", default: appliedToInvoice)

        if glSyncHas(payload, "invoice") {
            let incoming = GLSyncValue.uuid(payload, "invoice")
            if let resolved = EstimateRefLookup.invoice(incoming, in: context) {
                invoice = resolved
            } else if incoming == nil {
                invoice = nil
            }
            // Unresolved = the invoice has not arrived yet; leave it nil for a later pull.
        }
        if glSyncHas(payload, "invoiceGroup") {
            let incoming = GLSyncValue.uuid(payload, "invoiceGroup")
            if let resolved = EstimateRefLookup.invoiceGroup(incoming, in: context) {
                invoiceGroup = resolved
            } else if incoming == nil {
                invoiceGroup = nil
            }
            // Unresolved = the pushed group has not arrived yet; leave it nil for a later pull.
        }
    }
}

// MARK: - Change order line item

extension ChangeOrderLineItem: GLSyncMappable {

    static var glSyncType: String { "change_order_line_item" }

    var glSyncParentID: UUID? { changeOrder?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "details": GLSyncValue.string(details),
            "quantity": GLSyncValue.double(quantity),
            "unit": GLSyncValue.raw(unit),
            "unitPrice": GLSyncValue.double(unitPrice),
            "isTaxable": GLSyncValue.bool(isTaxable),
            "sortIndex": GLSyncValue.int(sortIndex),
            "changeOrder": GLSyncValue.uuid(changeOrder?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if glSyncHas(payload, "syncID") { syncID = GLSyncValue.uuid(payload, "syncID") ?? syncID }
        if glSyncHas(payload, "updatedAt") { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        name = GLSyncValue.string(payload, "name", default: name)
        details = GLSyncValue.string(payload, "details", default: details)
        quantity = GLSyncValue.double(payload, "quantity", default: quantity)
        if glSyncHas(payload, "unit") {
            // Change-order lines default to `.job`, not the estimate line's `.squareFoot`.
            unit = GLSyncValue.raw(payload, "unit", default: UnitOfMeasure.job)
        }
        unitPrice = GLSyncValue.double(payload, "unitPrice", default: unitPrice)
        isTaxable = GLSyncValue.bool(payload, "isTaxable", default: isTaxable)
        sortIndex = GLSyncValue.int(payload, "sortIndex", default: sortIndex)

        if glSyncHas(payload, "changeOrder") {
            let incoming = GLSyncValue.uuid(payload, "changeOrder")
            if let resolved = EstimateRefLookup.changeOrder(incoming, in: context) {
                changeOrder = resolved
            } else if incoming == nil {
                changeOrder = nil
            }
            // Unresolved = the order has not arrived yet; leave it nil for a later pull.
        }
    }
}

// MARK: - Property audit
//
// The exact payload keys each mapper in this file emits, in emission order. The round-trip /
// property-count test reads this rather than reflecting over the mappers, so adding a stored
// property to one of these @Models without mapping it fails the suite loudly
// (GLSYNC-SPEC.md §8). Keep a key here only while `glSyncPayload()` actually writes it.
//
// Deliberately absent from every list: the to-many relationship arrays
// (`Estimate.groups` / `.scheduledJobs`, `EstimateGroup.lineItems`, `ChangeOrder.lineItems`).
// A to-many is the inverse of a child's own reference, and the CHILD row carries that edge.

extension GLSyncMapperAudit {

    nonisolated static let estimateProperties: [String: [String]] = [
        "estimate": [
            "syncID", "updatedAt", "number", "jobTitle", "createdAt", "validUntil", "status",
            "customerFirstName", "customerLastName", "customerBusinessName", "customerEmail",
            "customerPhone", "customerAddress", "serviceAddress", "taxRatePercent",
            "discountType", "discountValue", "depositType", "depositValue", "customerNotes",
            "terms", "customer", "combineTotals",
        ],
        "estimate_group": [
            "syncID", "updatedAt", "name", "note", "sortIndex", "estimate",
        ],
        "estimate_line_item": [
            "syncID", "updatedAt", "name", "details", "quantity", "unit", "unitPrice", "kind",
            "isTaxable", "sortIndex", "discountType", "discountValue", "group",
        ],
        "change_order": [
            "syncID", "updatedAt", "number", "title", "createdAt", "note", "statusRaw",
            "taxRatePercent", "appliedToInvoice", "invoice", "invoiceGroup",
        ],
        "change_order_line_item": [
            "syncID", "updatedAt", "name", "details", "quantity", "unit", "unitPrice",
            "isTaxable", "sortIndex", "changeOrder",
        ],
    ]
}
