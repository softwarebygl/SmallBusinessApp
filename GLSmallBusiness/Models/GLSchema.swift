//
//  GLSchema.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData
import GoldLifeMoney

// MARK: - Versioned schema
//
// Why this file exists: the app ships to real customers and syncs their data to gl-business-api.
// Every future data-model change MUST let existing users update without crashing or losing data.
// Versioning the schema makes each change explicit and gives migrations a safe, tested path.
//
// ───────────────────────────────────────────────────────────────────────────────────────
//  RULES FOR CHANGING THE DATA MODEL — read before editing any @Model
// ───────────────────────────────────────────────────────────────────────────────────────
//  CloudKit is GONE as of the GLSync cutover (GLSYNC-SPEC.md §7): the store is local-only and the
//  backup is the owner's Gold Life account. The ADDITIVE discipline CloudKit forced on us stays,
//  for two reasons that outlive it — SwiftData's lightweight inference is what upgrades an existing
//  store in place (it can add columns, it cannot rewrite them), and the server's payload contract is
//  additive-only in the same way. So the discipline is unchanged:
//
//  1. ONLY ADD. Add new properties or whole new @Model types. Never rename, retype, or
//     remove a stored property in place.
//  2. New properties MUST have a default value or be optional. New relationships MUST be
//     optional (including to-many: use `[Thing]?`, never `[Thing] = []`). This was CloudKit's rule
//     first and it caused the early crash; lightweight inference needs the same thing — keep it.
//     2b. A new COMPOSITE property (any Codable struct/enum value type, e.g. `Address`) must
//     be OPTIONAL — a `= Address()` default is NOT applied while migrating existing stores,
//     so every updating user crashes at launch with "missing attribute values on mandatory
//     destination attribute" (builds 39/40, UserProfile.address). Defaults are only safe on
//     plain scalars (String/Bool/Int/Double). Structs: optional, always.
//     2c. …and rules 2b + GLSync together mean NO NEW COMPOSITES AT ALL on synced models,
//     and NO OPTIONAL ANYWHERE in a composite's keypath. The real law (corrected
//     2026-09-01, the build-62 crash): a persistent-history UPDATE row cannot be
//     materialized when the keypath to any changed sub-attribute crosses an Optional —
//     the composite PROPERTY being optional ("address.city", build 48) OR any MEMBER
//     inside the struct being optional ("address.street2", build 62 — `Address.street2:
//     String?` made EVERY address update in the app a poison pill; proven by a 5/5-
//     deterministic differential repro). Retyping street2 was tried and REJECTED: an
//     optional→non-optional member fails migration on every existing store ("missing
//     attribute values on mandatory destination attribute", the builds-39/40 class, and
//     the composite default is not applied — measured on a seeded store). The shipped
//     fix is rule 2c's own prescription applied to all eight composites: flat columns
//     behind a façade that keeps the original name (stored property Swift-renamed to
//     `legacy*` with `@Attribute(originalName:)`), plus `AddressFlatsBackfill` at
//     mount. The Address STRUCT is frozen forever — old stores validate against its
//     exact shape. The build-48 line
//     "non-optional composites are unaffected" tested only the property's optionality
//     and was WRONG. An update marks every sub-attribute of the composite as changed,
//     so one optional member poisons writes that never touch it. New structured data =
//     FLAT scalar columns behind a computed façade (the `UserProfile.homeAddress`
//     pattern). ALL NINE composites are now dormant-legacy and WRITE-FORBIDDEN:
//     `UserProfile.address` (build 48) and the eight `legacy*` Address columns on
//     BusinessProfile/Customer/Subcontractor/Estimate/Invoice/ScheduledJob (build 62).
//     Reads are safe; nothing may ever assign one.
//  3. To "rename" a field: add the new one, keep the old one, copy data across in code, and
//     stop reading the old one. Drop it only in a far-future cleanup, never abruptly.
//  4. When a shipped release changes the model, snapshot the new shape as `GLSchemaV2`
//     (then V3, …), add it to `GLMigrationPlan.schemas`, and add a `.lightweight` stage
//     between the previous version and the new one. Point `GLCurrentSchema` at the newest.
//  5. The SERVER is the other half of the contract now. A new stored property that is meant to
//     sync needs three things in the SAME commit: the property here, its line in that type's
//     `GLSyncMapper` (Sync/Mappers), and its entry in gl-business-api's `sync-manifest.json`. Miss
//     any one of the three and the field simply never leaves the device — silently, forever.
//  6. Always test the upgrade path: install the OLD version, add data, then install the NEW
//     version over it and confirm the data survives.
// ───────────────────────────────────────────────────────────────────────────────────────

/// Version 1.0.0 — the initial shipping shape of the data model.
enum GLSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Customer.self,
            CustomerDocument.self,
            Estimate.self,
            EstimateGroup.self,
            EstimateLineItem.self,
            Invoice.self,
            InvoiceGroup.self,
            InvoiceLineItem.self,
            InvoicePayment.self,
            ChangeOrder.self,
            ChangeOrderLineItem.self,
            Receipt.self,
            BusinessProfile.self,
            UserProfile.self,
            Employee.self,
            TimeEntry.self,
            Paycheck.self,
            Subcontractor.self,
            SubPayment.self,
            ScheduledJob.self,
            Project.self,
            JobAttachment.self,
            Contract.self,
            ContractGroup.self,
            ContractLineItem.self,
            PaymentProcessor.self,
            PriceSheetItem.self,
            // My Money Module (GoldLifeMoney) — additive bank, transaction, rule & subscription models
            BankAccount.self,
            BankTransaction.self,
            TransactionCategoryRule.self,
            RecurringSubscription.self,
            // GLSync (platform Phase 3) — local-only bookkeeping, see the note below.
            GLSyncOutboxEntry.self,
            GLSyncState.self,
            GLSyncRecordVersion.self,
        ]
    }
}

// POST-LAUNCH ADDITIVE CHANGES — why these still fold into V1.
//
// `GLSchemaV1.models` references the LIVE @Model types (not frozen per-version copies). A second
// VersionedSchema (e.g. GLSchemaV2) that also lists the live types therefore has the SAME model
// checksum as V1, and SwiftData aborts at launch with "Duplicate version checksums detected." So a real
// GLSchemaV2 only becomes viable once V1's shape is frozen as standalone copies — a large change
// reserved for the first NON-additive edit (a rename / retype / removal).
//
// For purely ADDITIVE changes (new optional or defaulted properties — rule 2), SwiftData's automatic
// lightweight inference adds the columns to an existing store with no migration stage, so they fold
// into V1 exactly like the W-9 fields and `signatureData` did. The Stripe invoice-payment fields
// (`BusinessProfile.stripeConnectedAccountId` / `stripeChargesEnabled` / `stripeAccountClaim` /
// `payLinkInclusionRaw` (retired) / `payLinkDefaultOn`; `Invoice.stripeAppInvoiceId` / `includePayLink` / `stripePaymentLink*` /
// `stripePayLinkStatusRaw` / `stripePayLinkMintCount`; `InvoicePayment.stripePaymentLinkId`)
// are all additive, so they stay in V1. `CustomerDocument` (per-customer Contractor Package extras,
// cascade off `Customer.packageDocuments`) is a whole-new @Model — additive too (rule 1), so it also
// folds into V1; its `CD_CustomerDocument` record type must reach Production the same way. So do the
// `Customer.wcCoiData`/`wcCoiName` fields (the per-customer Workers' Comp COI, which retired
// `BusinessProfile.wcInsuranceData` the same way `proofOfInsuranceData` was retired).
//
// GLSync's three @Models (`GLSyncOutboxEntry`, `GLSyncState`, `GLSyncRecordVersion` —
// GLSyncModels.swift) fold into V1 the same way: whole-new types, rule 1. They are the one group rule 5
// does NOT apply to: they are local-only bookkeeping (outbox, cursor/history token, per-record server
// versions) and are deliberately absent from `sync-manifest.json` — they drive the transport, they never
// ride it. They landed in the same release that removed `cloudKitDatabase:` from the container
// (GLSYNC-SPEC.md §7), so no row of any of them ever reached a CloudKit zone either.
//
// `@Attribute(.preserveValueOnDeletion)` on every model's `syncID` is the one change here that is not an
// ADDITION — it is an OPTION on a property that already exists, which rules 1–3 do not cover, so it gets
// its own note. Without it a delete is unnameable: SwiftData hands persistent history a tombstone that
// is EMPTY, so the record's `syncID` dies with the row and the server can never be told it went away
// (GLSYNC-SPEC.md §2a). The option moves the entity hash, which is the same thing that made builds 39/40
// crash, so it was PROVEN before it shipped rather than reasoned about: a two-binary CLI harness wrote a
// store with the old shape (plain `syncID`, non-optional `Address`, an `.externalStorage` blob and a
// cascade relationship) and a second binary opened that same file with the new shape. The container
// built, every row and value survived, the uuids were the SAME ones the old binary wrote, a write-back
// saved, and the delete then produced a tombstone carrying the uuid — including for the cascade CHILD.
// The negative control (old shape, same delete) printed `syncID = EMPTY`, so the attribute is what
// changed the outcome. It adds no record type and no field — all it changes is that a deleted row's
// `syncID` survives long enough to name the record to the server.
//
// REMINDER (rule 5): the app is LIVE, so a new synced field is not shipped until its mapper line and its
// `sync-manifest.json` entry ship WITH it. There is no CloudKit deploy step any more — that container is
// retained but unused, and is never to be deleted (owner ruling: keep it at least 12 months; it is the
// only copy of anything the cutover failed to upload).

/// The schema version the app currently builds against. Repoint this when you add a new version.
typealias GLCurrentSchema = GLSchemaV1

// MARK: - Migration plan

/// Declares every schema version and how to step between them. Empty `stages` is correct for a
/// single version — add `.lightweight(fromVersion:toVersion:)` entries as new versions appear.
enum GLMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GLSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No explicit stages: additive changes fold into V1 via SwiftData lightweight inference (see the
        // note above GLCurrentSchema). A stage is needed only once a frozen GLSchemaV2 exists for a
        // non-additive change.
        []
    }
}
