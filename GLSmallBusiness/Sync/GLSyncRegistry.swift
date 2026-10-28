//
//  GLSyncRegistry.swift
//  GLSmallBusiness
//
//  The type table: manifest key → everything the engine needs to handle a record of that
//  type without knowing what type it is. This is what lets ONE `apply(row:)` function write
//  a pulled `invoice_line_item` and a pulled `paycheck` with the same six lines of code.
//
//  Hand-written and exhaustive over all 24 sync types (gl-business-api/sync-manifest.json
//  is the closed list), for the reason every other GLSync file is hand-written: this codebase
//  has to stay maintainable by one person with no AI help. Reflection would be shorter and
//  would fail silently the first time a model changed shape.
//
//  `allTypes` below is `nonisolated` on purpose — it is the assertion surface for the
//  completeness test (GLSYNC-SPEC.md §8): a test can compare it against the manifest's keys
//  without touching SwiftData, the MainActor, or a store.
//
//  WHY EVERY LOOKUP IS PER-TYPE. `#Predicate` cannot reach `syncID` through a generic
//  `GLSyncIdentified` bound — the same limitation `SyncIdentityBackfill` documents — so each
//  entry carries its own concrete fetch. There is no way around it that does not end in
//  reflection.
//

import Foundation
import OSLog
import SwiftData
import GoldLifeMoney

/// A record that can both persist and ride the wire. Every one of the 24 conforms.
typealias GLSyncRecord = any PersistentModel & GLSyncMappable

/// A direct CASCADE child, named the way the server names it. Used to build the `cascade`
/// array on a delete op — the Worker verifies every id in it chains to the delete root
/// through `parent_id`, so this MUST follow the MANIFEST's parent, not SwiftData's delete
/// rules where the two differ (see `change_order` below).
nonisolated struct GLSyncChildRef: Sendable, Hashable {
    let type: String
    let id: UUID
}

// MARK: - One row of the table

@MainActor
struct GLSyncTypeEntry {

    /// snake_case manifest key.
    let key: String
    /// The SwiftData ENTITY name, derived from the model type rather than typed out — a
    /// hand-written copy would drift silently, and history reports entity names
    /// (GLSyncHistory's contract note).
    let entityName: String
    /// The manifest's CASCADE parent type, or nil for a root.
    let parentType: String?
    /// Depth in the parent chain (roots = 0). The push order key: a child pushed before its
    /// parent is refused `bad_parent`.
    let depth: Int
    /// One row per account (BusinessProfile / UserProfile). A second create merges into the
    /// existing head server-side rather than duplicating.
    let isSingleton: Bool
    /// No edit or delete UI exists; the record dies only by parent cascade (InvoicePayment).
    let isAppendOnly: Bool
    /// Payload keys carrying `{sha256, name}` blob references.
    let blobFields: [String]

    let fetch: (UUID, ModelContext) -> GLSyncRecord?
    /// Every row of the type. The BOOTSTRAP's alone: it has to visit everything once. A fold
    /// that used it loaded the whole table on the main actor after every save (QA 2026-10-03
    /// F91); a fold uses `fetchRows`.
    let fetchAll: (ModelContext) -> [GLSyncRecord]
    /// Only the rows history named, by row identity. What a fold loads: its cost tracks the
    /// edits, not the size of the account.
    let fetchRows: (Set<PersistentIdentifier>, ModelContext) -> [GLSyncRecord]
    /// The payload, or only the named fields of it. Same values either way; a type whose full
    /// payload is costly (the profile hashes seven documents) builds only what was asked.
    let payload: (GLSyncRecord, Set<String>?) -> GLSyncPayload
    let count: (ModelContext) -> Int
    /// Creates AND inserts. A pulled row for an unknown id needs somewhere to land.
    let createEmpty: (ModelContext) -> GLSyncRecord
    let delete: (GLSyncRecord, ModelContext) -> Void
    /// Re-attach a pulled record to its cascade parent. The parent id rides in the op
    /// ENVELOPE, not the patch, so no mapper can do this — half of them do not even carry
    /// the parent as a payload key.
    let linkParent: (GLSyncRecord, UUID?, ModelContext) -> Void
    /// Direct cascade children, for building a delete's `cascade` subtree.
    let children: (GLSyncRecord) -> [GLSyncChildRef]
    /// Blob bytes currently on the record, keyed by payload field. Only non-empty fields.
    let blobBytes: (GLSyncRecord) -> [String: Data]
    /// Write blob bytes fetched from `/attachments` back onto the record.
    let setBlobBytes: (GLSyncRecord, String, Data) -> Void
}

// MARK: - The table

@MainActor
enum GLSyncRegistry {

    /// All 24 manifest keys: the 23 the platform began with, plus the Price Sheet
    /// (`price_sheet_item`, 2026-10-03, QA finding F3 — until then it never left the phone).
    /// The completeness assertion (GLSYNC-SPEC.md §8) reads THIS —
    /// `nonisolated` so the test needs no actor, no container, and no store.
    nonisolated static let allTypes: [String] = [
        "business_profile", "user_profile", "customer", "employee", "scheduled_job",
        "subcontractor", "payment_processor", "customer_document", "estimate", "invoice",
        "receipt", "project", "time_entry", "paycheck", "job_attachment", "sub_payment",
        "estimate_group", "invoice_group", "invoice_payment", "change_order",
        "estimate_line_item", "invoice_line_item", "change_order_line_item",
        "price_sheet_item",
        "bank_account", "bank_transaction", "transaction_category_rule", "recurring_subscription",
    ]

    /// Manifest key → entry.
    static let types: [String: GLSyncTypeEntry] = {
        var table: [String: GLSyncTypeEntry] = [:]
        for entry in all { table[entry.key] = entry }
        return table
    }()

    /// SwiftData entity name → entry. History speaks entity names ("Invoice"); everything
    /// else speaks manifest keys ("invoice"). This is the one translation point.
    static let byEntityName: [String: GLSyncTypeEntry] = {
        var table: [String: GLSyncTypeEntry] = [:]
        for entry in all { table[entry.entityName] = entry }
        return table
    }()

    static func entry(for key: String) -> GLSyncTypeEntry? { types[key] }
    static func entry(entityName: String) -> GLSyncTypeEntry? { byEntityName[entityName] }

    /// Push/bootstrap order: parents before children, then oldest first. A child landing
    /// before its parent is refused `bad_parent`, and the outbox would then park a row that
    /// was never actually wrong.
    static func depth(of key: String) -> Int { types[key]?.depth ?? 0 }

    /// `pii_class` for one blob field. Only the subcontractor W-9 is tax-class; the Worker
    /// REFUSES a tax-class upload that is not client-encrypted, and the document key lives
    /// in the identity service, not here.
    nonisolated static func piiClass(type: String, field: String) -> GLSyncPIIClass {
        (type == "subcontractor" && field == "w9Data") ? .tax : .normal
    }

    // MARK: The 24

    private static let all: [GLSyncTypeEntry] = [

        // ---- roots ---------------------------------------------------------------

        entry(BusinessProfile.self, key: "business_profile", parent: nil, depth: 0,
              singleton: true,
              blobFields: ["logoData", "logoDataDark", "proofOfInsuranceData", "wcInsuranceData",
                           "wcExemptionData", "licenseDocumentData", "ownerReferenceCOIData",
                           "zelleQRCodeData"],
              fetch: { id, ctx in glFirst(#Predicate<BusinessProfile> { $0.syncID == id }, ctx) },
              make: { BusinessProfile() },
              // A new invoice or estimate bumps the profile's counter; that fold must not
              // re-hash the logos and documents (QA 2026-10-03 F91).
              partialPayload: { profile, fields in profile.glSyncPayload(only: fields) },
              children: { profile in
                  (profile.paymentProcessors ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "payment_processor", id: $0) }
                  }
              },
              blobs: { profile in
                  var blobs: [String: Data] = [:]
                  blobs["logoData"] = profile.logoData
                  blobs["logoDataDark"] = profile.logoDataDark
                  blobs["proofOfInsuranceData"] = profile.proofOfInsuranceData
                  blobs["wcInsuranceData"] = profile.wcInsuranceData
                  blobs["wcExemptionData"] = profile.wcExemptionData
                  blobs["licenseDocumentData"] = profile.licenseDocumentData
                  blobs["ownerReferenceCOIData"] = profile.ownerReferenceCOIData
                  blobs["zelleQRCodeData"] = profile.zelleQRCodeData
                  return blobs
              },
              setBlob: { profile, field, bytes in
                  switch field {
                  case "logoData": profile.logoData = bytes
                  case "logoDataDark": profile.logoDataDark = bytes
                  case "proofOfInsuranceData": profile.proofOfInsuranceData = bytes
                  case "wcInsuranceData": profile.wcInsuranceData = bytes
                  case "wcExemptionData": profile.wcExemptionData = bytes
                  case "licenseDocumentData": profile.licenseDocumentData = bytes
                  case "ownerReferenceCOIData": profile.ownerReferenceCOIData = bytes
                  case "zelleQRCodeData": profile.zelleQRCodeData = bytes
                  default: break
                  }
              }),

        // No files: the person's photo and signature live in the Gold Life ID alone (law 48;
        // audit 2026-10-03 F19). An old server row's references are neither fetched nor written
        // back, so a deleted signature can't return through a pull and the legacy upload.
        entry(UserProfile.self, key: "user_profile", parent: nil, depth: 0,
              singleton: true,
              fetch: { id, ctx in glFirst(#Predicate<UserProfile> { $0.syncID == id }, ctx) },
              make: { UserProfile() }),

        entry(Customer.self, key: "customer", parent: nil, depth: 0,
              blobFields: ["profileImageData", "coiData", "wcCoiData"],
              fetch: { id, ctx in glFirst(#Predicate<Customer> { $0.syncID == id }, ctx) },
              make: { Customer() },
              children: { customer in
                  // `projects`, `timeEntries`, `subPayments` and `scheduledJobs` are NULLIFY
                  // links — they survive the customer, and naming one here would make the
                  // Worker refuse the whole delete (`bad_parent`).
                  var refs: [GLSyncChildRef] = []
                  refs += (customer.packageDocuments ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "customer_document", id: $0) } }
                  refs += (customer.estimates ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "estimate", id: $0) } }
                  refs += (customer.invoices ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "invoice", id: $0) } }
                  refs += (customer.receipts ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "receipt", id: $0) } }
                  return refs
              },
              blobs: { customer in
                  var blobs: [String: Data] = [:]
                  blobs["profileImageData"] = customer.profileImageData
                  blobs["coiData"] = customer.coiData
                  blobs["wcCoiData"] = customer.wcCoiData
                  return blobs
              },
              setBlob: { customer, field, bytes in
                  switch field {
                  case "profileImageData": customer.profileImageData = bytes
                  case "coiData": customer.coiData = bytes
                  case "wcCoiData": customer.wcCoiData = bytes
                  default: break
                  }
              }),

        entry(Employee.self, key: "employee", parent: nil, depth: 0,
              blobFields: ["profileImageData"],
              fetch: { id, ctx in glFirst(#Predicate<Employee> { $0.syncID == id }, ctx) },
              make: { Employee() },
              children: { employee in
                  var refs: [GLSyncChildRef] = []
                  refs += (employee.timeEntries ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "time_entry", id: $0) } }
                  refs += (employee.paychecks ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "paycheck", id: $0) } }
                  return refs
              },
              blobs: { employee in
                  var blobs: [String: Data] = [:]
                  blobs["profileImageData"] = employee.profileImageData
                  return blobs
              },
              setBlob: { employee, field, bytes in
                  if field == "profileImageData" { employee.profileImageData = bytes }
              }),

        entry(ScheduledJob.self, key: "scheduled_job", parent: nil, depth: 0,
              fetch: { id, ctx in glFirst(#Predicate<ScheduledJob> { $0.syncID == id }, ctx) },
              make: { ScheduledJob() },
              children: { job in
                  // `billingInvoices` and `receipts` are NULLIFY — financial records outlive
                  // the job they were tagged to.
                  (job.attachments ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "job_attachment", id: $0) } }
              }),

        entry(Subcontractor.self, key: "subcontractor", parent: nil, depth: 0,
              blobFields: ["profileImageData", "w9Data", "coiData"],
              fetch: { id, ctx in glFirst(#Predicate<Subcontractor> { $0.syncID == id }, ctx) },
              make: { Subcontractor() },
              children: { sub in
                  (sub.payments ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "sub_payment", id: $0) } }
              },
              blobs: { sub in
                  var blobs: [String: Data] = [:]
                  blobs["profileImageData"] = sub.profileImageData
                  blobs["coiData"] = sub.coiData
                  // w9Data is pii_class 'tax' — see GLSyncEngine's upload gate. It is listed
                  // here so the engine can SEE it and refuse it out loud, rather than the
                  // field quietly never appearing.
                  blobs["w9Data"] = sub.w9Data
                  return blobs
              },
              setBlob: { sub, field, bytes in
                  switch field {
                  case "profileImageData": sub.profileImageData = bytes
                  case "coiData": sub.coiData = bytes
                  case "w9Data": sub.w9Data = bytes
                  default: break
                  }
              }),

        // The Price Sheet: an account-level catalog, no parent, no children, no blobs.
        entry(PriceSheetItem.self, key: "price_sheet_item", parent: nil, depth: 0,
              fetch: { id, ctx in glFirst(#Predicate<PriceSheetItem> { $0.syncID == id }, ctx) },
              make: { PriceSheetItem() }),

        // My Money Module (GoldLifeMoney)
        entry(BankAccount.self, key: "bank_account", parent: nil, depth: 0,
              fetch: { id, ctx in glFirst(#Predicate<BankAccount> { $0.syncID == id }, ctx) },
              make: { BankAccount() },
              children: { parent in
                  var refs: [GLSyncChildRef] = []
                  refs += (parent.transactions ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "bank_transaction", id: $0) }
                  }
                  refs += (parent.subscriptions ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "recurring_subscription", id: $0) }
                  }
                  return refs
              }),

        entry(BankTransaction.self, key: "bank_transaction", parent: "bank_account", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<BankTransaction> { $0.syncID == id }, ctx) },
              make: { BankTransaction() },
              link: { record, parentID, ctx in
                  record.bankAccountSyncID = parentID
                  record.account = parentID.flatMap { id in glFirst(#Predicate<BankAccount> { $0.syncID == id }, ctx) }
              }),

        entry(TransactionCategoryRule.self, key: "transaction_category_rule", parent: nil, depth: 0,
              fetch: { id, ctx in glFirst(#Predicate<TransactionCategoryRule> { $0.syncID == id }, ctx) },
              make: { TransactionCategoryRule() }),

        entry(RecurringSubscription.self, key: "recurring_subscription", parent: "bank_account", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<RecurringSubscription> { $0.syncID == id }, ctx) },
              make: { RecurringSubscription() },
              link: { record, parentID, ctx in
                  record.bankAccountSyncID = parentID
                  record.account = parentID.flatMap { id in glFirst(#Predicate<BankAccount> { $0.syncID == id }, ctx) }
              }),

        // ---- depth 1 -------------------------------------------------------------

        entry(PaymentProcessor.self, key: "payment_processor", parent: "business_profile", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<PaymentProcessor> { $0.syncID == id }, ctx) },
              make: { PaymentProcessor() },
              link: { record, parentID, ctx in
                  record.businessProfile = GLSyncParentLookup.businessProfile(parentID, ctx)
              }),

        entry(CustomerDocument.self, key: "customer_document", parent: "customer", depth: 1,
              blobFields: ["data"],
              fetch: { id, ctx in glFirst(#Predicate<CustomerDocument> { $0.syncID == id }, ctx) },
              make: { CustomerDocument() },
              link: { record, parentID, ctx in
                  record.customer = GLSyncParentLookup.customer(parentID, ctx)
              },
              blobs: { document in
                  var blobs: [String: Data] = [:]
                  blobs["data"] = document.data
                  return blobs
              },
              setBlob: { document, field, bytes in
                  if field == "data" { document.data = bytes }
              }),

        entry(Estimate.self, key: "estimate", parent: "customer", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<Estimate> { $0.syncID == id }, ctx) },
              make: { Estimate() },
              link: { record, parentID, ctx in
                  record.customer = GLSyncParentLookup.customer(parentID, ctx)
              },
              children: { estimate in
                  (estimate.groups ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "estimate_group", id: $0) } }
              }),

        entry(Invoice.self, key: "invoice", parent: "customer", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<Invoice> { $0.syncID == id }, ctx) },
              make: { Invoice() },
              link: { record, parentID, ctx in
                  record.customer = GLSyncParentLookup.customer(parentID, ctx)
              },
              children: { invoice in
                  var refs: [GLSyncChildRef] = []
                  refs += (invoice.groups ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "invoice_group", id: $0) } }
                  refs += (invoice.payments ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "invoice_payment", id: $0) } }
                  refs += (invoice.changeOrders ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "change_order", id: $0) } }
                  return refs
              }),

        entry(Receipt.self, key: "receipt", parent: "customer", depth: 1,
              blobFields: ["scanData"],
              fetch: { id, ctx in glFirst(#Predicate<Receipt> { $0.syncID == id }, ctx) },
              make: { Receipt() },
              link: { record, parentID, ctx in
                  record.customer = GLSyncParentLookup.customer(parentID, ctx)
              },
              blobs: { receipt in
                  var blobs: [String: Data] = [:]
                  blobs["scanData"] = receipt.scanData
                  return blobs
              },
              setBlob: { receipt, field, bytes in
                  if field == "scanData" { receipt.scanData = bytes }
              }),

        // `parent_delete: "nullify"` in the manifest: a project SURVIVES its customer. It is
        // still parented for routing, but it is never in a customer's cascade subtree.
        entry(Project.self, key: "project", parent: "customer", depth: 1,
              blobFields: ["masterAgreementData"],
              fetch: { id, ctx in glFirst(#Predicate<Project> { $0.syncID == id }, ctx) },
              make: { Project() },
              link: { record, parentID, ctx in
                  record.customer = GLSyncParentLookup.customer(parentID, ctx)
              },
              blobs: { project in
                  var blobs: [String: Data] = [:]
                  blobs["masterAgreementData"] = project.masterAgreementData
                  return blobs
              },
              setBlob: { project, field, bytes in
                  if field == "masterAgreementData" { project.masterAgreementData = bytes }
              }),

        entry(TimeEntry.self, key: "time_entry", parent: "employee", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<TimeEntry> { $0.syncID == id }, ctx) },
              make: { TimeEntry() },
              link: { record, parentID, ctx in
                  record.employee = GLSyncParentLookup.employee(parentID, ctx)
              }),

        entry(Paycheck.self, key: "paycheck", parent: "employee", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<Paycheck> { $0.syncID == id }, ctx) },
              make: { Paycheck() },
              link: { record, parentID, ctx in
                  record.employee = GLSyncParentLookup.employee(parentID, ctx)
              }),

        entry(JobAttachment.self, key: "job_attachment", parent: "scheduled_job", depth: 1,
              blobFields: ["data"],
              fetch: { id, ctx in glFirst(#Predicate<JobAttachment> { $0.syncID == id }, ctx) },
              make: { JobAttachment() },
              link: { record, parentID, ctx in
                  record.job = GLSyncParentLookup.scheduledJob(parentID, ctx)
              },
              blobs: { attachment in
                  var blobs: [String: Data] = [:]
                  blobs["data"] = attachment.data
                  return blobs
              },
              setBlob: { attachment, field, bytes in
                  if field == "data" { attachment.data = bytes }
              }),

        entry(SubPayment.self, key: "sub_payment", parent: "subcontractor", depth: 1,
              fetch: { id, ctx in glFirst(#Predicate<SubPayment> { $0.syncID == id }, ctx) },
              make: { SubPayment() },
              link: { record, parentID, ctx in
                  record.subcontractor = GLSyncParentLookup.subcontractor(parentID, ctx)
              }),

        // ---- depth 2 -------------------------------------------------------------

        entry(EstimateGroup.self, key: "estimate_group", parent: "estimate", depth: 2,
              fetch: { id, ctx in glFirst(#Predicate<EstimateGroup> { $0.syncID == id }, ctx) },
              make: { EstimateGroup() },
              link: { record, parentID, ctx in
                  record.estimate = GLSyncParentLookup.estimate(parentID, ctx)
              },
              children: { group in
                  (group.lineItems ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "estimate_line_item", id: $0) } }
              }),

        entry(InvoiceGroup.self, key: "invoice_group", parent: "invoice", depth: 2,
              fetch: { id, ctx in glFirst(#Predicate<InvoiceGroup> { $0.syncID == id }, ctx) },
              make: { InvoiceGroup() },
              link: { record, parentID, ctx in
                  record.invoice = GLSyncParentLookup.invoice(parentID, ctx)
              },
              children: { group in
                  (group.lineItems ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "invoice_line_item", id: $0) } }
              }),

        entry(InvoicePayment.self, key: "invoice_payment", parent: "invoice", depth: 2,
              appendOnly: true,
              fetch: { id, ctx in glFirst(#Predicate<InvoicePayment> { $0.syncID == id }, ctx) },
              make: { InvoicePayment() },
              link: { record, parentID, ctx in
                  record.invoice = GLSyncParentLookup.invoice(parentID, ctx)
              }),

        entry(ChangeOrder.self, key: "change_order", parent: "invoice", depth: 2,
              fetch: { id, ctx in glFirst(#Predicate<ChangeOrder> { $0.syncID == id }, ctx) },
              make: { ChangeOrder() },
              link: { record, parentID, ctx in
                  record.invoice = GLSyncParentLookup.invoice(parentID, ctx)
              },
              children: { order in
                  // `invoiceGroup` is a SwiftData cascade child but NOT a manifest one: an
                  // invoice_group's server parent is the INVOICE. Naming it here would fail
                  // the Worker's parentage walk and refuse the whole delete, so un-applying a
                  // change order enqueues that group as its OWN delete op
                  // (GLSyncEngine.enqueueDelete handles this pairing).
                  (order.lineItems ?? []).compactMap { child in
                      child.syncID.map { GLSyncChildRef(type: "change_order_line_item", id: $0) } }
              }),

        // ---- depth 3 -------------------------------------------------------------

        entry(EstimateLineItem.self, key: "estimate_line_item", parent: "estimate_group", depth: 3,
              fetch: { id, ctx in glFirst(#Predicate<EstimateLineItem> { $0.syncID == id }, ctx) },
              make: { EstimateLineItem() },
              link: { record, parentID, ctx in
                  record.group = GLSyncParentLookup.estimateGroup(parentID, ctx)
              }),

        entry(InvoiceLineItem.self, key: "invoice_line_item", parent: "invoice_group", depth: 3,
              fetch: { id, ctx in glFirst(#Predicate<InvoiceLineItem> { $0.syncID == id }, ctx) },
              make: { InvoiceLineItem() },
              link: { record, parentID, ctx in
                  record.group = GLSyncParentLookup.invoiceGroup(parentID, ctx)
              }),

        entry(ChangeOrderLineItem.self, key: "change_order_line_item", parent: "change_order", depth: 3,
              fetch: { id, ctx in glFirst(#Predicate<ChangeOrderLineItem> { $0.syncID == id }, ctx) },
              make: { ChangeOrderLineItem() },
              link: { record, parentID, ctx in
                  record.changeOrder = GLSyncParentLookup.changeOrder(parentID, ctx)
              }),
    ]

    // MARK: - Entry factory
    //
    // Generic so each entry above is a table ROW, not a page of boilerplate. Everything the
    // engine calls is erased to `GLSyncRecord` here; the concrete type is captured once, in
    // this one function, which is also the only place a wrong cast could live.

    private static func entry<T: PersistentModel & GLSyncMappable>(
        _ type: T.Type,
        key: String,
        parent: String?,
        depth: Int,
        singleton: Bool = false,
        appendOnly: Bool = false,
        blobFields: [String] = [],
        // `UUID?`, not `UUID`: `syncID` is optional, and a `#Predicate` comparing `UUID?`
        // against a non-optional does not type-check. The public `fetch` below still takes a
        // plain `UUID` — the promotion happens here, once.
        fetch: @escaping (UUID?, ModelContext) -> T?,
        make: @escaping () -> T,
        partialPayload: ((T, Set<String>) -> GLSyncPayload)? = nil,
        link: @escaping (T, UUID?, ModelContext) -> Void = { _, _, _ in },
        children: @escaping (T) -> [GLSyncChildRef] = { _ in [] },
        blobs: @escaping (T) -> [String: Data] = { _ in [:] },
        setBlob: @escaping (T, String, Data) -> Void = { _, _, _ in }
    ) -> GLSyncTypeEntry {
        GLSyncTypeEntry(
            key: key,
            entityName: Schema.entityName(for: T.self),
            parentType: parent,
            depth: depth,
            isSingleton: singleton,
            isAppendOnly: appendOnly,
            blobFields: blobFields,
            fetch: { id, context in fetch(id, context) },
            fetchAll: { context in
                ((try? context.fetch(FetchDescriptor<T>())) ?? []).map { $0 as GLSyncRecord }
            },
            fetchRows: { rows, context in
                glFetchRows(T.self, rows, context).map { $0 as GLSyncRecord }
            },
            payload: { record, fields in
                guard let typed = record as? T else { return [:] }
                guard let fields else { return typed.glSyncPayload() }
                if let partialPayload { return partialPayload(typed, fields) }
                return typed.glSyncPayload().filter { fields.contains($0.key) }
            },
            count: { context in (try? context.fetchCount(FetchDescriptor<T>())) ?? 0 },
            createEmpty: { context in
                let record = make()
                context.insert(record)
                return record
            },
            delete: { record, context in
                guard let typed = record as? T else { return }
                context.delete(typed)
            },
            linkParent: { record, parentID, context in
                guard let typed = record as? T else { return }
                link(typed, parentID, context)
            },
            children: { record in
                guard let typed = record as? T else { return [] }
                return children(typed)
            },
            blobBytes: { record in
                guard let typed = record as? T else { return [:] }
                // Drop empty/absent blobs here rather than in ten call sites: a zero-byte
                // upload is refused (`bad_body`) and would park a row for no reason.
                return blobs(typed).filter { !$0.value.isEmpty }
            },
            setBlobBytes: { record, field, bytes in
                guard let typed = record as? T else { return }
                setBlob(typed, field, bytes)
            })
    }
}

// MARK: - Parent lookups
//
// Only the ten types that are somebody's cascade parent need one. Concrete per type for the
// `#Predicate` reason in the file header; nil is a NORMAL answer — a child can arrive before
// its parent, and leaving the link nil (rather than minting a stub parent) lets the next pull
// wire it up. A stub would be a phantom customer in the customer list.

@MainActor
private enum GLSyncParentLookup {
    static func businessProfile(_ id: UUID?, _ ctx: ModelContext) -> BusinessProfile? {
        guard let id else { return nil }
        return glFirst(#Predicate<BusinessProfile> { $0.syncID == id }, ctx)
    }
    static func customer(_ id: UUID?, _ ctx: ModelContext) -> Customer? {
        guard let id else { return nil }
        return glFirst(#Predicate<Customer> { $0.syncID == id }, ctx)
    }
    static func employee(_ id: UUID?, _ ctx: ModelContext) -> Employee? {
        guard let id else { return nil }
        return glFirst(#Predicate<Employee> { $0.syncID == id }, ctx)
    }
    static func scheduledJob(_ id: UUID?, _ ctx: ModelContext) -> ScheduledJob? {
        guard let id else { return nil }
        return glFirst(#Predicate<ScheduledJob> { $0.syncID == id }, ctx)
    }
    static func subcontractor(_ id: UUID?, _ ctx: ModelContext) -> Subcontractor? {
        guard let id else { return nil }
        return glFirst(#Predicate<Subcontractor> { $0.syncID == id }, ctx)
    }
    static func estimate(_ id: UUID?, _ ctx: ModelContext) -> Estimate? {
        guard let id else { return nil }
        return glFirst(#Predicate<Estimate> { $0.syncID == id }, ctx)
    }
    static func invoice(_ id: UUID?, _ ctx: ModelContext) -> Invoice? {
        guard let id else { return nil }
        return glFirst(#Predicate<Invoice> { $0.syncID == id }, ctx)
    }
    static func estimateGroup(_ id: UUID?, _ ctx: ModelContext) -> EstimateGroup? {
        guard let id else { return nil }
        return glFirst(#Predicate<EstimateGroup> { $0.syncID == id }, ctx)
    }
    static func invoiceGroup(_ id: UUID?, _ ctx: ModelContext) -> InvoiceGroup? {
        guard let id else { return nil }
        return glFirst(#Predicate<InvoiceGroup> { $0.syncID == id }, ctx)
    }
    static func changeOrder(_ id: UUID?, _ ctx: ModelContext) -> ChangeOrder? {
        guard let id else { return nil }
        return glFirst(#Predicate<ChangeOrder> { $0.syncID == id }, ctx)
    }
}

/// The rows with these identities, in chunks so no single query carries thousands of
/// bound values. A query that fails falls back to the whole table, filtered: slower, but a
/// fold that loaded nothing would leave the person's edit out of the outbox.
@MainActor
private func glFetchRows<T: PersistentModel>(_ type: T.Type, _ rows: Set<PersistentIdentifier>,
                                             _ context: ModelContext) -> [T] {
    guard !rows.isEmpty else { return [] }
    let ids = Array(rows)
    var found: [T] = []
    var start = 0
    while start < ids.count {
        let chunk = Array(ids[start..<min(start + glFetchRowsChunk, ids.count)])
        start += chunk.count
        let descriptor = FetchDescriptor<T>(predicate: #Predicate { chunk.contains($0.persistentModelID) })
        do {
            found += try context.fetch(descriptor)
        } catch {
            Logger.data.error("glsync row fetch failed: \(error.localizedDescription, privacy: .public)")
            let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
            return all.filter { rows.contains($0.persistentModelID) }
        }
    }
    return found
}

private let glFetchRowsChunk = 500

/// One fetch, limit 1. File-private so it cannot collide with the mapper files' own copies.
@MainActor
private func glFirst<T: PersistentModel>(_ predicate: Predicate<T>, _ context: ModelContext) -> T? {
    var descriptor = FetchDescriptor<T>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}
