//
//  RowReconciler.swift — the ONE save path for a document's child rows.
//
//  Editing an estimate, invoice, or change order used to DELETE every group and line
//  item and create them again. Four things went wrong at once: covered screens rendered
//  rows that had just been deleted (the 2026-09-01 estimate-save crash), one edit became
//  N delete + N create sync ops, a paid invoice could not be edited at all (the server
//  refuses the deletes with paid_locked), and every row lost its syncID, so any other
//  device's references to it broke.
//
//  `reconcile` replaces that with an in-place save: a draft that still names a saved row
//  updates it, a draft without one inserts a new row, and a saved row no draft names is
//  deleted. Every property write inside an update closure goes through `setIfChanged`, so
//  a row the person did not touch produces NO SwiftData change — no history row, and
//  therefore no outbox op.
//

import Foundation
import SwiftData
import GoldLifeDocuments

nonisolated enum RowReconciler {

    /// Reconciles the live child rows of a parent against ordered drafts. Drafts that name an
    /// existing live row (by `persistentModelID` or `GLDocumentRowMapping.documentSyncID`) are UPDATED
    /// in place; drafts without a match are INSERTED via `make`; live rows no draft names are handed
    /// to `delete`. Returns the rows in draft order so callers can recurse into nested children.
    ///
    /// Matching reads `existing` only — pass `parent.liveRows(parent.children)`. A row deleted
    /// under the form (a sync pull) is simply absent from it, so its draft inserts fresh and the
    /// dead row is never read (reading a deleted @Model traps). `update(row, draft, index)` runs
    /// for matched AND fresh rows; `index` is the position among the drafts passed in, so filter
    /// out blank drafts BEFORE calling. A row is claimed at most once: a second draft naming the
    /// same id inserts fresh rather than sharing the row.
    @discardableResult
    @MainActor
    static func reconcile<Row: PersistentModel, Draft>(
        existing: [Row], drafts: [Draft], modelID: (Draft) -> PersistentIdentifier?,
        make: (Draft) -> Row, update: (Row, Draft, Int) -> Void, delete: (Row) -> Void
    ) -> [Row] {
        var kept: [Row] = []
        var claimed: Set<PersistentIdentifier> = []
        for (index, draft) in drafts.enumerated() {
            let row: Row
            if let id = modelID(draft), !claimed.contains(id),
               let match = existing.first(where: { $0.persistentModelID == id }) {
                claimed.insert(id)
                row = match
            } else if let docElem = draft as? GLDocumentElement,
                      let match = existing.first(where: { ($0 as? GLDocumentRowMapping)?.documentSyncID == docElem.id && !claimed.contains($0.persistentModelID) }) {
                claimed.insert(match.persistentModelID)
                row = match
            } else {
                row = make(draft)
            }
            update(row, draft, index)
            kept.append(row)
        }
        for row in existing where !claimed.contains(row.persistentModelID) { delete(row) }
        return kept
    }
}

/// Writes `new` to `object[keyPath]` only when it differs. The point is what does NOT happen
/// on an equal value: SwiftData never sees a write, so the row stays out of `changedModels`,
/// gets no history row, and queues no outbox op. Use it for every property write inside a
/// `reconcile` update closure: `setIfChanged(item, \.name, draft.name)`.
nonisolated func setIfChanged<Root: AnyObject, Value: Equatable>(
    _ object: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>, _ new: Value
) {
    if object[keyPath: keyPath] != new { object[keyPath: keyPath] = new }
}

/// Not an option for a @Model property: Swift passes a computed property `inout` by copy-in /
/// copy-out, which runs the setter on the way back out whether or not the value changed, and
/// SwiftData marks the row changed on that equal write (probed 2026-09-02 — `hasChanges` flips
/// true). Unavailable, so a call in that shape fails at compile time with the fix in the message.
@available(*, unavailable, message: "an inout write always runs the @Model setter and dirties the row; use setIfChanged(row, \\.property, value)")
nonisolated func setIfChanged<Value: Equatable>(_ value: inout Value, _ new: Value) {}
