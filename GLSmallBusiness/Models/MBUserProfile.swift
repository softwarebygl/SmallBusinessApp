//
//  MBUserProfile.swift — per-person app settings row on SwiftData.
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  The person's identity lives ONLY in the Gold Life ID (laws 48 / 48a; audit 2026-10-03
//  F19). This row holds one app setting, `useMyNameInEmails`. All pre-3.3.0 identity
//  columns have been dropped from the schema; SwiftData lightweight migration removes the
//  old columns on existing stores automatically while preserving `syncID`, `updatedAt`,
//  and `useMyNameInEmails`. Pinned by IdentitySourceTests and UserProfileTests.
//

import Foundation
import SwiftData

@SwiftData.Model
final class UserProfile {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`.
    var updatedAt: Date?

    /// When true, customer emails are signed with THIS person's Gold Life ID name
    /// instead of the business owner's (Settings ▸ What customers see ▸ Name in
    /// emails). Per-person and synced (the one field user_profile carries).
    /// Falls back to the owner's name when this person's own name is blank, so
    /// the signature never loses its name line. Default false = owner's name,
    /// the original behavior.
    var useMyNameInEmails: Bool = false

    init() {}
}

extension UserProfile {
    /// Settings ▸ Name in emails. Finds or creates the one row and saves it: a new account
    /// has no row until something writes one, and a write into nothing would look saved and
    /// be gone (law 44). A second copy minted by the sync bootstrap is merged by ProfileDedup
    /// and, server-side, by the singleton head.
    static func setUseMyNameInEmails(_ value: Bool, in context: ModelContext) {
        let row = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first ?? {
            let new = UserProfile()
            context.insert(new)
            return new
        }()
        row.useMyNameInEmails = value
        context.saveChanges()
    }
}
