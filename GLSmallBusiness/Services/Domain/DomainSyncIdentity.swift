//
//  DomainSyncIdentity.swift
//  GLSmallBusiness
//
//  Every record the assistant can name is named by its `syncID`. Rows written before Phase 0, or
//  pulled from a build that never minted one, can still have none until the next-launch
//  `SyncIdentityBackfill` — so a read that hands a record out mints the id first and saves it,
//  rather than returning a record nobody can refer to again.
//
//  Through `saveChanges()` like every write, which also stamps `updatedAt` on the minted row. That
//  is a (harmless) difference from the launch backfill, which leaves `updatedAt` nil on purpose.
//  While the app is read-only (lapsed or offline) the id is minted but NOT saved: a save would
//  stamp the row and queue a sync op, and nothing goes to the server while read-only. The next
//  allowed save (or the launch backfill) keeps it.
//

import Foundation
import SwiftData

@MainActor
enum DomainSyncIdentity {

    /// The record's `syncID`, minting and saving one if it has none. A record not in a context (or
    /// deleted) is refused: an id minted on it could never be saved.
    @discardableResult
    static func ensure<T: PersistentModel & GLSyncIdentified>(_ record: T, in context: ModelContext,
                                                               subscription: SubscriptionManager? = nil) throws -> UUID {
        guard record.modelContext != nil, !record.isDeleted else { throw DomainError.recordNotFound }
        if let id = record.syncID { return id }
        let id = UUID()
        record.syncID = id
        if !ReadOnlyGate.isReadOnly(subscription) { context.saveChanges() }
        return id
    }
}
