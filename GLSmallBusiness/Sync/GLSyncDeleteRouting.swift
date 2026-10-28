//
//  GLSyncDeleteRouting.swift
//  GLSmallBusiness
//
//  THE ONE WAY THE APP DELETES A SYNCED RECORD.
//
//  A bare `context.delete(record)` still reaches the server — the history fold recovers the id
//  from the tombstone — but it reaches it as one INDEPENDENT delete op per row, with no parent
//  and no cascade. gl-business-api then:
//
//    • REFUSES `invoice_payment` outright (`append_only`): a payment has no delete of its own
//      on the wire, it dies only inside its parent's verified cascade;
//    • REFUSES the parent invoice (`conflict`): a live child the op never named is, as far as
//      the Worker can tell, a payment somebody recorded on another device, and it will not
//      vaporize one;
//    • APPLIES the leaves, because a leaf has no children to be refused over.
//
//  What lands is therefore the line items and nothing else, and every other device then shows
//  an invoice with no line items and the original payments still attached — a negative balance
//  on a real customer's books. The cascade has to be read WHILE THE RECORD STILL EXISTS, which
//  is what this file is: enqueue first, delete second, in one call the order cannot be got
//  wrong in.
//
//  `GLSyncDeleteRoutingTests` walks the app sources and fails if a bare `.delete(` on a model
//  context reappears outside `Sync/`, so the rule is a gate rather than a habit.
//

import Foundation
import SwiftData

// MARK: - The app-facing call

@MainActor
extension ModelContext {

    /// Delete a synced record: queue the delete op — with the cascade subtree read off the
    /// live object graph — and only then remove it.
    ///
    /// Safe for a record that has never been saved (`syncID` still nil): there is nothing on
    /// the server to tell about, so the queue step declines and the delete happens anyway.
    func deleteSynced<T: PersistentModel & GLSyncMappable>(_ record: T) {
        GLSyncDeleteQueue.enqueue(record, in: self)
        delete(record)
    }
}

// MARK: - The queue

/// Writing a delete op. Shared by the app's `deleteSynced` and the sync engine's own
/// `GLSyncLocalStore.enqueueDelete`, so there is exactly ONE implementation of "what does a
/// delete look like on the wire" and the two can never drift.
@MainActor
enum GLSyncDeleteQueue {

    /// Queue a delete for a live record. Returns false when the record cannot be named (no
    /// `syncID`) or its type is not in the manifest — in both cases there is nothing the
    /// server could be told.
    @discardableResult
    static func enqueue<T: PersistentModel & GLSyncMappable>(
        _ record: T, in context: ModelContext
    ) -> Bool {
        guard let recordID = record.glSyncID else { return false }
        return enqueue(record, recordID: recordID, type: T.glSyncType, in: context)
    }

    /// The type-erased body. `type` is the MANIFEST key, resolved by the caller.
    ///
    /// The subtree follows the MANIFEST's parent chain, not SwiftData's delete rules, because
    /// that is what the Worker verifies: every cascade id must chain to the delete root
    /// through `parent_id`, and a nullify hop refuses the whole op (`bad_parent`).
    @discardableResult
    static func enqueue(
        _ record: GLSyncRecord, recordID: UUID, type: String, in context: ModelContext
    ) -> Bool {
        guard GLSyncRegistry.entry(for: type) != nil else { return false }

        let subtree = self.subtree(of: record, recordID: recordID, in: context)

        // Pending edits to anything in the subtree are moot — the rows are going away.
        for id in [recordID] + subtree.map(\.id) {
            if let row = GLSyncOutboxEntry.entry(for: id, in: context) { context.delete(row) }
        }

        let row = GLSyncOutboxEntry(
            recordID: recordID,
            recordType: type,
            parentID: record.glSyncParentID,
            baseVersion: GLSyncRecordVersion.row(for: recordID, in: context)?.version ?? 0,
            fieldsJSON: "{}",
            isDelete: true)
        row.cascade = subtree.map(\.id)
        context.insert(row)

        // An APPLIED change order also owns an InvoiceGroup on the invoice. SwiftData
        // cascade-deletes it locally, but its SERVER parent is the invoice, not the change
        // order — naming it in the cascade would fail the Worker's parentage walk. So it gets
        // its own top-level delete op, exactly as the "un-approve a change order" flow already
        // models it (gl-business-api README §6).
        if type == "change_order", let order = record as? ChangeOrder,
           let group = order.invoiceGroup, let groupID = group.syncID {
            _ = enqueue(group, recordID: groupID, type: "invoice_group", in: context)
        }
        return true
    }

    /// The delete op's `cascade`: every manifest descendant of `record`, breadth-first. Also what
    /// `DeletionService` counts against the Worker's per-op cap before it deletes anything, so the
    /// count and the op can never disagree.
    static func subtree(of record: GLSyncRecord, recordID: UUID,
                        in context: ModelContext) -> [GLSyncChildRef] {
        var subtree: [GLSyncChildRef] = []
        var frontier: [GLSyncRecord] = [record]
        var seen: Set<UUID> = [recordID]
        while let current = frontier.popLast() {
            guard let currentType = manifestType(of: current),
                  let currentEntry = GLSyncRegistry.entry(for: currentType) else { continue }
            for child in currentEntry.children(current) where !seen.contains(child.id) {
                seen.insert(child.id)
                subtree.append(child)
                if let childEntry = GLSyncRegistry.entry(for: child.type),
                   let childRecord = childEntry.fetch(child.id, context) {
                    frontier.append(childRecord)
                }
            }
        }
        return subtree
    }

    /// Every id already spoken for by a queued delete's cascade.
    ///
    /// The history fold consults this: once a routed delete has named the whole subtree in ONE
    /// op, SwiftData still emits a tombstone per cascaded row, and folding those into their own
    /// independent delete ops is exactly the corruption `deleteSynced` exists to prevent — the
    /// `invoice_payment` one would come back `refused: append_only` and park a row forever.
    static func cascadeCoveredIDs(in context: ModelContext) -> Set<UUID> {
        var covered: Set<UUID> = []
        for row in GLSyncOutboxEntry.all(in: context) where row.isDelete {
            covered.formUnion(row.cascade)
        }
        return covered
    }

    /// The manifest key for a live record. Routed through the ENTITY name rather than
    /// `type(of:).glSyncType`: reading a static protocol member off an existential needs the
    /// type opened, and the registry already owns that translation.
    static func manifestType(of record: GLSyncRecord) -> String? {
        GLSyncRegistry.entry(entityName: record.persistentModelID.entityName)?.key
    }
}
