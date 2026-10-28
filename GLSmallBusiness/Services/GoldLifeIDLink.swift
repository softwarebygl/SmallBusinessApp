//
//  GoldLifeIDLink.swift — RETIRED with CloudKit (GLSYNC-SPEC.md §7); `reset()` still runs.
//
//  What it used to do: post this device's CloudKit userRecordID to the Worker alongside the
//  signed-in Gold Life ID, so a future backend migration could claim the right person's existing
//  CloudKit records. That migration is THIS release — the device's own SwiftData store is the
//  replica we bootstrap from, so there is nothing left to claim and nothing left to map.
//
//  Why the body is empty instead of the file being gone: reading the userRecordID needs the iCloud
//  container entitlement, which this release removes — `CKContainer.default()` raises without it,
//  and it was called on every signed-in launch. Emptying the one function that touched CloudKit is
//  the smallest change that cannot crash. `reset()` stays REAL: it clears the per-account
//  "already linked" flags a previous build wrote, so they don't outlive the feature in UserDefaults.
//

import Foundation

enum GoldLifeIDLink {
    /// The legacy per-account "already linked" flag, suffixed with the canonical id.
    /// Nothing writes it any more; `reset()` is what clears the ones already on disk.
    private static let linkedKeyPrefix = "goldLifeAppLinked_"

    /// No-op. Kept so the sign-in flow's call site doesn't need to change in the cutover
    /// release; delete this and `GoldLifeAuth.kickAppLink()` together in a cleanup pass.
    static func runIfNeeded() async {}

    /// Sign-out / account switch: drop the legacy "linked" flags this device may still
    /// carry from before the CloudKit exit, so they don't accumulate one per past user.
    static func reset() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(linkedKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
