//
//  GLSchema.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData

// MARK: - Versioned schema
//
// Why this file exists: the app syncs through CloudKit and ships to real customers. Every
// future data-model change MUST let existing users update without crashing or losing data.
// Versioning the schema makes each change explicit and gives migrations a safe, tested path.
//
// ───────────────────────────────────────────────────────────────────────────────────────
//  RULES FOR CHANGING THE DATA MODEL — read before editing any @Model
// ───────────────────────────────────────────────────────────────────────────────────────
//  CloudKit only supports LIGHTWEIGHT, ADDITIVE migrations (it has no custom-migration hook,
//  and a deployed CloudKit production schema can only ever grow). So the discipline is:
//
//  1. ONLY ADD. Add new properties or whole new @Model types. Never rename, retype, or
//     remove a stored property in place.
//  2. New properties MUST have a default value or be optional. New relationships MUST be
//     optional (including to-many: use `[Thing]?`, never `[Thing] = []`). This is the same
//     CloudKit rule that caused the early crash — keep honoring it.
//  3. To "rename" a field: add the new one, keep the old one, copy data across in code, and
//     stop reading the old one. Drop it only in a far-future cleanup, never abruptly.
//  4. When a shipped release changes the model, snapshot the new shape as `GLSchemaV2`
//     (then V3, …), add it to `GLMigrationPlan.schemas`, and add a `.lightweight` stage
//     between the previous version and the new one. Point `GLCurrentSchema` at the newest.
//  5. Deploy the schema to CloudKit PRODUCTION (CloudKit Dashboard → Deploy Schema Changes)
//     before shipping the build to the App Store. Dev-only schema = sync breaks in prod.
//  6. Always test the upgrade path: install the OLD version, add data, then install the NEW
//     version over it and confirm the data survives.
// ───────────────────────────────────────────────────────────────────────────────────────

/// Version 1.0.0 — the initial shipping shape of the data model.
enum GLSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Customer.self,
            Estimate.self,
            EstimateGroup.self,
            EstimateLineItem.self,
            Invoice.self,
            InvoiceGroup.self,
            InvoiceLineItem.self,
            InvoicePayment.self,
            Receipt.self,
            BusinessProfile.self,
        ]
    }
}

// NOTE: Pre-launch, every model change is still part of V1 (see README §6 rule 3 / §11) — nothing
// has shipped, so there are no production stores to migrate. The W-9 tax fields and saved
// `signatureData` added to `BusinessProfile` are purely additive (defaulted / optional), so they
// fold into V1. The first post-launch model change is when GLSchemaV2 + a lightweight stage land.

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
        // No migrations yet — V1 is the baseline.
        // When GLSchemaV2 lands (first post-launch model change), append e.g.:
        //   .lightweight(fromVersion: GLSchemaV1.self, toVersion: GLSchemaV2.self)
        []
    }
}
