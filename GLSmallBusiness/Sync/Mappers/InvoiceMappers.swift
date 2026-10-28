//
//  InvoiceMappers.swift
//  GLSmallBusiness
//
//  GLSyncMappable for the invoice family: Invoice → InvoiceGroup → InvoiceLineItem, plus
//  InvoicePayment. Manifest keys `invoice`, `invoice_group`, `invoice_line_item`,
//  `invoice_payment` (gl-business-api/sync-manifest.json).
//
//  Two stored properties per type are deliberately ABSENT from the payload, because the wire
//  protocol already carries them outside `patch` (gl-business-api README §3):
//    • `syncID`  → the op's `id`, surfaced through `glSyncID`.
//    • the CASCADE parent (`Invoice.customer`, `InvoiceGroup.invoice`, `InvoiceLineItem.group`,
//      `InvoicePayment.invoice`) → the op's `parent_id`, surfaced through `glSyncParentID`.
//  Everything else rides. NULLIFY-style links (`Invoice.job`, `InvoiceGroup.changeOrder`) are
//  ordinary payload fields carrying the referent's syncID — they are not parents, and the
//  server must not cascade on them.
//
//  Derived money (subtotal / discountAmount / taxAmount / total / amountPaid / balanceDue /
//  isPaid / revisedTotal / displayStatus) is NEVER emitted: the Worker recomputes it from the
//  same formulas (src/money.ts) and a stale total landing on the server would flip invoices
//  Paid/Unpaid across platforms. To-many arrays (`groups`, `payments`, `changeOrders`,
//  `scheduledJobs`, `lineItems`) are inverses — the CHILD carries the link, so they are not
//  stored properties of this record on the wire.
//

import Foundation
import SwiftData
import GoldLifeDocuments

// MARK: - Reference resolution
//
// Nullify-style links arrive as the referent's syncID. Resolving needs a concrete fetch per
// target type: `#Predicate` cannot reach `syncID` through a generic `GLSyncIdentified` bound
// (the same limitation SyncIdentityBackfill documents). File-private so each mapper file can
// keep its own resolvers without colliding at module scope.

private func glSyncScheduledJob(_ id: UUID?, in context: ModelContext) -> ScheduledJob? {
    guard let id else { return nil }
    let match: UUID? = id
    var descriptor = FetchDescriptor<ScheduledJob>(predicate: #Predicate { $0.syncID == match })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}

private func glSyncChangeOrder(_ id: UUID?, in context: ModelContext) -> ChangeOrder? {
    guard let id else { return nil }
    let match: UUID? = id
    var descriptor = FetchDescriptor<ChangeOrder>(predicate: #Predicate { $0.syncID == match })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}

// MARK: - Invoice

extension Invoice: GLSyncMappable {

    static var glSyncType: String { "invoice" }

    /// Cascade parent per the manifest: deleting the customer deletes their invoices.
    var glSyncParentID: UUID? { customer?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "updatedAt": GLSyncValue.date(updatedAt),
            "number": GLSyncValue.string(number),
            "jobTitle": GLSyncValue.string(jobTitle),
            "createdAt": GLSyncValue.date(createdAt),
            "dueDate": GLSyncValue.date(dueDate),
            "paymentTerms": GLSyncValue.raw(paymentTerms),
            "status": GLSyncValue.raw(status),
            // Customer snapshot — frozen at creation. The server never reconciles these against
            // the live customer, so they ride as plain values, not as a customer lookup.
            "customerFirstName": GLSyncValue.string(customerFirstName),
            "customerLastName": GLSyncValue.string(customerLastName),
            "customerBusinessName": GLSyncValue.optional(customerBusinessName),
            "customerEmail": GLSyncValue.string(customerEmail),
            "customerPhone": GLSyncValue.string(customerPhone),
            "customerAddress": GLSyncValue.address(customerAddress),
            "serviceAddress": GLSyncValue.address(serviceAddress),
            "sourceEstimateNumber": GLSyncValue.optional(sourceEstimateNumber),
            "taxRatePercent": GLSyncValue.double(taxRatePercent),
            "discountType": GLSyncValue.raw(discountType),
            "discountValue": GLSyncValue.double(discountValue),
            "customerNotes": GLSyncValue.string(customerNotes),
            "terms": GLSyncValue.string(terms),
            "amountDueNow": GLSyncValue.double(amountDueNow),
            "amountDueDetail": GLSyncValue.string(amountDueDetail),
            "stripeAppInvoiceId": GLSyncValue.string(stripeAppInvoiceId),
            "includePayLink": GLSyncValue.bool(includePayLink),
            "includeZelle": GLSyncValue.bool(includeZelle),
            "stripePaymentLinkId": GLSyncValue.string(stripePaymentLinkId),
            // Which connected account minted the link. Without it a device restored from
            // the backend reads "", treats every existing link as belonging to another
            // account, and re-mints on the next send.
            "stripePaymentLinkAccountId": GLSyncValue.string(stripePaymentLinkAccountId),
            "stripePaymentLinkURL": GLSyncValue.string(stripePaymentLinkURL),
            "stripePaymentLinkAmountCents": GLSyncValue.int(stripePaymentLinkAmountCents),
            // Stored as a String, read through the enum so an unknown status cannot reach the UI.
            "stripePayLinkStatusRaw": GLSyncValue.raw(stripePayLinkStatus),
            "stripePayLinkMintCount": GLSyncValue.int(stripePayLinkMintCount),
            "stripePaymentLinkMintedAt": GLSyncValue.date(stripePaymentLinkMintedAt),
            "changeOrderNumberSeed": GLSyncValue.int(changeOrderNumberSeed),
            // NULLIFY ref (ScheduledJob.billingInvoices): the job this invoice bills. Not a
            // parent — deleting the job must leave the invoice standing.
            "job": GLSyncValue.uuid(job?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        updatedAt = GLSyncValue.date(payload, "updatedAt")
        number = GLSyncValue.string(payload, "number")
        jobTitle = GLSyncValue.string(payload, "jobTitle")
        // Non-optional dates keep the local value when the key is absent — an older build's
        // record must not be dragged to 1970.
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        dueDate = GLSyncValue.date(payload, "dueDate") ?? dueDate
        paymentTerms = GLSyncValue.raw(payload, "paymentTerms", default: PaymentTerms.net30)
        status = GLSyncValue.raw(payload, "status", default: InvoiceStatus.draft)
        customerFirstName = GLSyncValue.string(payload, "customerFirstName")
        customerLastName = GLSyncValue.string(payload, "customerLastName")
        customerBusinessName = GLSyncValue.optionalString(payload, "customerBusinessName")
        customerEmail = GLSyncValue.string(payload, "customerEmail")
        customerPhone = GLSyncValue.string(payload, "customerPhone")
        customerAddress = GLSyncValue.address(payload, "customerAddress") ?? Address()
        serviceAddress = GLSyncValue.address(payload, "serviceAddress") ?? Address()
        sourceEstimateNumber = GLSyncValue.optionalString(payload, "sourceEstimateNumber")
        taxRatePercent = GLSyncValue.double(payload, "taxRatePercent")
        discountType = GLSyncValue.raw(payload, "discountType", default: AdjustmentType.none)
        discountValue = GLSyncValue.double(payload, "discountValue")
        customerNotes = GLSyncValue.string(payload, "customerNotes")
        terms = GLSyncValue.string(payload, "terms")
        amountDueNow = GLSyncValue.double(payload, "amountDueNow")
        amountDueDetail = GLSyncValue.string(payload, "amountDueDetail")
        stripeAppInvoiceId = GLSyncValue.string(payload, "stripeAppInvoiceId")
        includePayLink = GLSyncValue.bool(payload, "includePayLink")
        includeZelle = GLSyncValue.bool(payload, "includeZelle")
        stripePaymentLinkId = GLSyncValue.string(payload, "stripePaymentLinkId")
        stripePaymentLinkAccountId = GLSyncValue.string(payload, "stripePaymentLinkAccountId")
        stripePaymentLinkURL = GLSyncValue.string(payload, "stripePaymentLinkURL")
        stripePaymentLinkAmountCents = GLSyncValue.int(payload, "stripePaymentLinkAmountCents")
        stripePayLinkStatus = GLSyncValue.raw(
            payload, "stripePayLinkStatusRaw", default: StripePayLinkStatus.none
        )
        stripePayLinkMintCount = GLSyncValue.int(payload, "stripePayLinkMintCount")
        stripePaymentLinkMintedAt = GLSyncValue.date(payload, "stripePaymentLinkMintedAt")
        changeOrderNumberSeed = GLSyncValue.int(payload, "changeOrderNumberSeed")
        // A referent that has not been pulled yet resolves to nil; a later pull of the job
        // re-runs this apply on the invoice and restores the link.
        job = glSyncScheduledJob(GLSyncValue.uuid(payload, "job"), in: context)
    }
}

// MARK: - InvoiceGroup

extension InvoiceGroup: GLSyncMappable {

    static var glSyncType: String { "invoice_group" }

    /// Cascade parent per the manifest is the INVOICE. `changeOrder` is also a cascade link in
    /// SwiftData (ChangeOrder owns the group it pushed), but a record has exactly one server
    /// parent and the manifest names the invoice — so the change order rides in the payload.
    var glSyncParentID: UUID? { invoice?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "note": GLSyncValue.string(note),
            "sortIndex": GLSyncValue.int(sortIndex),
            "changeOrder": GLSyncValue.uuid(changeOrder?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        updatedAt = GLSyncValue.date(payload, "updatedAt")
        name = GLSyncValue.string(payload, "name")
        note = GLSyncValue.string(payload, "note")
        sortIndex = GLSyncValue.int(payload, "sortIndex")
        // Nil when the change order has not been pulled yet — a later pull fixes it.
        changeOrder = glSyncChangeOrder(GLSyncValue.uuid(payload, "changeOrder"), in: context)
    }
}

// MARK: - InvoiceLineItem

extension InvoiceLineItem: GLSyncMappable {

    static var glSyncType: String { "invoice_line_item" }

    var glSyncParentID: UUID? { group?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "details": GLSyncValue.string(details),
            "quantity": GLSyncValue.double(quantity),
            "unit": GLSyncValue.raw(unit),
            "unitPrice": GLSyncValue.double(unitPrice),
            "kind": GLSyncValue.raw(kind),
            "isTaxable": GLSyncValue.bool(isTaxable),
            "sortIndex": GLSyncValue.int(sortIndex),
            "fromChangeOrder": GLSyncValue.bool(fromChangeOrder),
            "discountType": GLSyncValue.raw(discountType),
            "discountValue": GLSyncValue.double(discountValue),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        updatedAt = GLSyncValue.date(payload, "updatedAt")
        name = GLSyncValue.string(payload, "name")
        details = GLSyncValue.string(payload, "details")
        // quantity defaults to 1, matching the model — a missing key must not zero a line.
        quantity = GLSyncValue.double(payload, "quantity", default: 1)
        unit = GLSyncValue.raw(payload, "unit", default: UnitOfMeasure.squareFoot)
        unitPrice = GLSyncValue.double(payload, "unitPrice")
        kind = GLSyncValue.raw(payload, "kind", default: LineItemKind.labor)
        isTaxable = GLSyncValue.bool(payload, "isTaxable")
        sortIndex = GLSyncValue.int(payload, "sortIndex")
        fromChangeOrder = GLSyncValue.bool(payload, "fromChangeOrder")
        discountType = GLSyncValue.raw(payload, "discountType", default: AdjustmentType.none)
        discountValue = GLSyncValue.double(payload, "discountValue")
    }
}

// MARK: - InvoicePayment

extension InvoicePayment: GLSyncMappable {

    static var glSyncType: String { "invoice_payment" }

    var glSyncParentID: UUID? { invoice?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "updatedAt": GLSyncValue.date(updatedAt),
            "amount": GLSyncValue.double(amount),
            "date": GLSyncValue.date(date),
            "method": GLSyncValue.raw(method),
            "note": GLSyncValue.string(note),
            // RETIRED INPUT, still synced: existing payments carry historical fee snapshots that
            // Statistics still reads, so dropping them from the wire would rewrite past expenses.
            "processorName": GLSyncValue.string(processorName),
            "processorFeePercentSnapshot": GLSyncValue.double(processorFeePercentSnapshot),
            "processorFlatFeeSnapshot": GLSyncValue.double(processorFlatFeeSnapshot),
            "stripePaymentLinkId": GLSyncValue.string(stripePaymentLinkId),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        updatedAt = GLSyncValue.date(payload, "updatedAt")
        amount = GLSyncValue.double(payload, "amount")
        date = GLSyncValue.date(payload, "date") ?? date
        // The shipped degrade rule, generalized: a method added by a newer build reads as .other
        // rather than rejecting the payment.
        method = GLSyncValue.raw(payload, "method", default: PaymentMethod.other)
        note = GLSyncValue.string(payload, "note")
        processorName = GLSyncValue.string(payload, "processorName")
        processorFeePercentSnapshot = GLSyncValue.double(payload, "processorFeePercentSnapshot")
        processorFlatFeeSnapshot = GLSyncValue.double(payload, "processorFlatFeeSnapshot")
        stripePaymentLinkId = GLSyncValue.string(payload, "stripePaymentLinkId")
    }
}

// MARK: - Audit
//
// The closed list of payload keys per type, consumed by the round-trip / property-count guard
// (GLSYNC-SPEC.md §8). Add a stored property to one of these @Models without mapping it here
// and the suite fails — that failure IS the regression net.
//
// STITCHING NOTE: the bare `GLSyncMapperAudit` declaration below must exist exactly ONCE across
// the mapper files. Every other mapper file should carry only its `extension`.

enum GLSyncMapperAudit {}

extension GLSyncMapperAudit {

    nonisolated static let invoiceProperties: [String: [String]] = [
        "invoice": [
            "updatedAt", "number", "jobTitle", "createdAt", "dueDate", "paymentTerms", "status",
            "customerFirstName", "customerLastName", "customerBusinessName", "customerEmail",
            "customerPhone", "customerAddress", "serviceAddress", "sourceEstimateNumber",
            "taxRatePercent", "discountType", "discountValue", "customerNotes", "terms",
            "amountDueNow", "amountDueDetail", "stripeAppInvoiceId", "includePayLink",
            "includeZelle",
            "stripePaymentLinkId", "stripePaymentLinkAccountId", "stripePaymentLinkURL",
            "stripePaymentLinkAmountCents",
            "stripePayLinkStatusRaw", "stripePayLinkMintCount", "stripePaymentLinkMintedAt",
            "changeOrderNumberSeed", "job",
        ],
        "invoice_group": [
            "updatedAt", "name", "note", "sortIndex", "changeOrder",
        ],
        "invoice_line_item": [
            "updatedAt", "name", "details", "quantity", "unit", "unitPrice", "kind", "isTaxable",
            "sortIndex", "fromChangeOrder", "discountType", "discountValue",
        ],
        "invoice_payment": [
            "updatedAt", "amount", "date", "method", "note", "processorName",
            "processorFeePercentSnapshot", "processorFlatFeeSnapshot", "stripePaymentLinkId",
        ],
    ]
}
