//
//  LiveRows.swift — the ONE fence against reading deleted models.
//
//  Reading any property of a deleted @Model traps uncatchably inside SwiftData,
//  and SwiftUI hands covered screens one more render pass over dead rows
//  whenever a save or a synced pull deletes models the UI still holds (the
//  build-43 sign-out crash, the 2026-09-01 estimate-save crash, and the five
//  unguarded twins the 2026-09-02 CRUD audit found). Per-screen guards were
//  whack-a-mole; this filter sits at the MODEL ACCESSORS instead, so every
//  screen, total, and export inherits safety automatically and the bug class
//  cannot be written again.
//
//  A parent whose delete was saved returns no rows at all (`isSavedDelete`): its
//  context is gone, yet its old children are still attached and dead (2026-10-03).
//
//  The filter runs only when the PARENT is managed by a context. An unmanaged
//  object graph (a record still being built, a test fixture) has children with
//  `modelContext == nil` that are perfectly alive — the first version filtered
//  those too and the regression suite caught it the same day (an uninserted
//  fixture's line items vanished). Once the parent is managed, a child with no
//  context can only be a deleted row.
//
//  Every relationship read that feeds UI or math goes through `liveRows(_:)`.
//  A raw `(relationship ?? [])` read outside this file needs a written reason.
//

import Foundation
import SwiftData

extension PersistentModel {
    /// The given relationship rows, minus anything deleted. `modelContext == nil`
    /// on a child of a MANAGED parent means a committed delete (isDeleted reads
    /// false on those — measured 2026-09-01); `isDeleted` catches the pre-save
    /// window. nonisolated: called from the models' own nonisolated accessors.
    nonisolated func liveRows<T: PersistentModel>(_ rows: [T]?) -> [T] {
        // A parent whose delete was SAVED still hands back its old children, and reading one
        // traps (the 2026-10-03 swipe-delete crash in EstimateLineItem.discountType: SwiftUI
        // renders the deleted row once more and the row reads `total`). Nothing it holds is live.
        if isSavedDelete { return [] }
        guard modelContext != nil else { return rows ?? [] }
        return (rows ?? []).filter { $0.modelContext != nil && !$0.isDeleted }
    }

    /// True for a record whose delete was saved: no context, yet a store identity. `isDeleted`
    /// reads false again by then, and a never-saved fixture (also no context) has no store
    /// identifier, so the two are told apart. Reads only `modelContext` and
    /// `persistentModelID`, both safe on a dead record (DeletedRowFenceTests).
    nonisolated var isSavedDelete: Bool {
        modelContext == nil && persistentModelID.storeIdentifier != nil
    }
}
