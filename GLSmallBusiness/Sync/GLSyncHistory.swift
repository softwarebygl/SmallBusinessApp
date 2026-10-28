//
//  GLSyncHistory.swift
//  GLSmallBusiness
//
//  The change-capture half of GLSync (GLSYNC-SPEC.md §2). Reads SwiftData persistent history
//  and hands the engine a flat list of "this record changed, and these fields moved".
//
//  Why history and not `ModelContext.saveChanges`: SwiftUI autosaves bypass our save site
//  entirely, so a save-site hook silently misses edits. History catches every mutation
//  regardless of save path — verified against an autosave-enabled context, not assumed.
//
//  What this SDK actually gives us (iOS 26 SDK, deployment target 26.0 — measured against a
//  real on-disk store, findings written up in GLSYNC-SPEC.md §2a):
//    • `ModelContext.fetchHistory(_:)` works on a plain local store. History tracking is ON by
//      DEFAULT — it is not something CloudKit turns on, so Phase 3's removal of
//      `cloudKitDatabase:` does not switch it off.
//    • Updates DO carry per-attribute detail (`HistoryUpdate.updatedAttributes`), so real
//      per-field merge is on the table — no whole-record fallback needed.
//    • Deletes DO carry the record's `syncID`, recovered from the tombstone — `syncID`
//      is marked `@Attribute(.preserveValueOnDeletion)` precisely so they can.
//

import Foundation
import SwiftData

// MARK: - The change record

/// One record-level change folded out of persistent history.
nonisolated struct GLSyncHistoryChange: Sendable, Equatable {

    nonisolated enum Kind: String, Sendable {
        case insert, update, delete
    }

    /// The SwiftData ENTITY name (`"Invoice"`, `"TimeEntry"`), which is the @Model type's name —
    /// NOT the snake_case manifest key. History has no idea our mappers exist, so translating
    /// this to `GLSyncMappable.glSyncType` is the engine's job (it owns the mapper registry).
    let recordType: String

    /// SwiftData's row identity. Stable and `Codable`, but meaningless to the server — the
    /// engine resolves it to the domain `syncID` before anything is enqueued.
    let recordID: PersistentIdentifier

    let kind: Kind

    /// The deleted record's `syncID`, recovered from the tombstone — `.delete` only.
    ///
    /// `syncID` is the ONLY property in the schema marked
    /// `@Attribute(.preserveValueOnDeletion)`, and a tombstone carries only preserved
    /// attributes, so the single UUID in there is unambiguous. nil means the row predates
    /// that attribute (written by a build before the sync release), and the engine has
    /// nothing to tell the server — those deletes are genuinely unrecoverable.
    let deletedSyncID: UUID?

    /// The stored-property names that moved, for `.update` only.
    ///
    /// `nil` means "treat the whole record as dirty". That happens for inserts (everything is
    /// new), for deletes, and — the case worth knowing about — when an update's key paths
    /// cannot be resolved to schema property names. A whole-record patch is not wrong, only
    /// coarse: concurrent edits to DIFFERENT fields of one record then surface as contests
    /// instead of merging silently, because every field looks touched.
    let changedFields: [String]?

    /// WHEN the write happened — the transaction's own timestamp, not the moment we folded it.
    ///
    /// This is what rides the wire as `client_ts`, and the server breaks last-writer-wins ties
    /// on it (merge.ts §3.4). Nothing else on this device knows the answer: the fold cannot run
    /// while the device is offline past its cached token, so "now" at fold time is really
    /// "when the phone found signal" — and stamping that would hand every argument to whichever
    /// device syncs LAST rather than whoever typed last.
    let at: Date
}

// MARK: - Errors

/// Both cases mean the same thing to the engine: the saved token cannot be trusted, so drop it
/// and re-bootstrap. They are separate cases only so the log says which trap we hit.
nonisolated enum GLSyncHistoryError: LocalizedError {
    /// `lastHistoryTokenData` did not decode — a truncated or hand-edited value.
    case tokenUnreadable
    /// The token belongs to a store that no longer exists (a DEBUG dev-store wipe, a restore
    /// from backup, or the Phase 3 switch creating a fresh store file). This is the trap that
    /// makes the guard mandatory: SwiftData does NOT throw `historyTokenExpired` for a foreign
    /// token — `token > foreignToken` quietly matches ZERO rows, so without this check the app
    /// would report "nothing changed" forever and never sync again.
    case tokenFromAnotherStore
    /// The stored token was written under a DIFFERENT model shape, so its history cannot be
    /// materialized without trapping inside SwiftData. Recoverable, and NOT the person's problem:
    /// the engine resets the watermark and carries on. It is surfaced only in the developer log.
    case schemaChanged

    /// These reach the person: `GLSyncEngine` turns a history error into a user message. So they
    /// go through the catalog — `MBLocalization.string`, not `mbLoc`, because this enum is
    /// `nonisolated` and cannot hop to the MainActor helper.
    var errorDescription: String? {
        switch self {
        case .tokenUnreadable:
            return MBLocalization.string("The sync bookmark couldn't be read.")
        case .tokenFromAnotherStore:
            return MBLocalization.string("The sync bookmark is from an older copy of your data.")
        case .schemaChanged:
            // Deliberately no sentence. The app updated, the engine re-baselines itself, and
            // nothing is lost — telling someone about it would be alarming noise about a
            // mechanism they cannot act on. The developer gets it from the log line instead.
            return nil
        }
    }
}

// MARK: - History reader

nonisolated enum GLSyncHistory {

    /// Stamp this on the `ModelContext` used to apply PULLED server changes
    /// (`context.author = GLSyncHistory.applyAuthor`). Writes made under it are skipped here,
    /// so applying a pulled change cannot echo back into the outbox as a fresh local edit.
    static let applyAuthor = "gl-sync"

    /// The shape of the models this build reads history against.
    ///
    /// Deliberately the BUILD identity, not a computed attribute list. The change that shipped the
    /// crash — adding `@Attribute(.preserveValueOnDeletion)` to an existing `syncID` — does not
    /// alter any attribute NAME, so a name-derived hash would have matched and read the poisoned
    /// history anyway. Any new build invalidates; the cost is one skipped history window per
    /// upgrade, and the outbox (not history) is what actually holds unsent work, so nothing is
    /// lost by skipping it. Cheap insurance against a class of crash that cannot be caught.
    static var schemaFingerprint: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)(\(build))"
    }

    /// Whether the history written under `fingerprint` can be READ by this build.
    ///
    /// Nil is never safe: it means the token predates the fingerprint, which is precisely the
    /// state every device upgrading into the fix is in.
    static func canReadHistory(writtenUnder fingerprint: String?) -> Bool {
        fingerprint == schemaFingerprint
    }

    /// Every change since `token`, plus the token to persist once the push succeeds.
    ///
    /// `newToken == nil` means "history had nothing new — KEEP the token you already have".
    /// It never means "reset": advancing to nil would re-fold the entire history next cycle.
    ///
    /// Advance the token only AFTER the push lands (GLSYNC-SPEC.md §2). Folding is idempotent —
    /// the outbox coalesces per record — so replaying a window is safe; losing one is not.
    static func changes(
        since token: Data?,
        writtenUnder fingerprint: String? = nil,
        in context: ModelContext
    ) throws -> (changes: [GLSyncHistoryChange], newToken: Data?) {

        // SCHEMA GATE — must come BEFORE any fetchHistory. Materializing a transaction written
        // under a different model shape traps inside SwiftData (see
        // GLSyncState.historySchemaFingerprint); it is not catchable, so the only defence is not
        // to read. Skipping forward is safe: the outbox holds unsent work, not history.
        if token != nil, !canReadHistory(writtenUnder: fingerprint) {
            throw GLSyncHistoryError.schemaChanged
        }

        // NIL-TOKEN GATE (build 48's launch trap, 2026-08-29, same stack as build 42). A nil
        // token means read FROM THE BEGINNING — and the fingerprint gate above can't protect
        // it: after a re-baseline the token is nil and the fingerprint freshly stamped, so if
        // the purge FAILED (its catch deliberately falls through) the very next fold walked
        // straight into the poisoned rows and SIGTRAPped uncatchably. So every from-the-
        // beginning read PURGES FIRST: `deleteHistory` never materializes a transaction, which
        // makes it safe on any history, and a nil-token cycle re-uploads the store anyway
        // (bootstrap) — history holds nothing a fresh baseline needs.
        if token == nil {
            try prune(before: .distantFuture, in: context)
        }

        var saved: DefaultHistoryToken?
        if let token {
            guard let decoded = try? JSONDecoder().decode(DefaultHistoryToken.self, from: token) else {
                throw GLSyncHistoryError.tokenUnreadable
            }
            saved = decoded
        }

        // The store-identity guard. A token is a per-store watermark; against a different store
        // it silently matches nothing rather than failing loudly, so we check the identity
        // ourselves. When history is empty there is no identity to read and nothing to fold —
        // the next cycle, once any write lands, catches the mismatch.
        if let saved, let live = try liveStoreIdentifier(in: context),
           saved.tokenValue?[live] == nil {
            throw GLSyncHistoryError.tokenFromAnotherStore
        }

        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let saved {
            descriptor.predicate = #Predicate { $0.token > saved }
        }
        descriptor.sortBy = [SortDescriptor(\DefaultHistoryTransaction.transactionIdentifier, order: .forward)]

        let transactions = try context.fetchHistory(descriptor)

        // The watermark comes from the UNFILTERED window, so our own apply-writes are skipped
        // once and never re-examined. Filtering by author in the predicate instead is a trap:
        // it runs as SQL, where `author != 'gl-sync'` drops every NULL-author row — i.e. all of
        // the user's own edits. Measured, not guessed. So: filter here, in memory.
        let newToken = try transactions.map(\.token).max().map { try JSONEncoder().encode($0) }

        var changes: [GLSyncHistoryChange] = []
        for transaction in transactions where transaction.author != applyAuthor {
            // The transaction's own clock — the instant the write landed on this device. See
            // `GLSyncHistoryChange.at` for why "now" is not an acceptable substitute.
            let at = transaction.timestamp
            for change in transaction.changes {
                let id = change.changedPersistentIdentifier
                switch change {
                case .insert:
                    changes.append(.init(recordType: id.entityName, recordID: id,
                                         kind: .insert, deletedSyncID: nil, changedFields: nil,
                                         at: at))
                case .update(let update):
                    changes.append(.init(recordType: id.entityName, recordID: id,
                                         kind: .update, deletedSyncID: nil,
                                         changedFields: fieldNames(update, in: context.container.schema),
                                         at: at))
                // A delete tells us which ROW went away, and — because `syncID` carries
                // `@Attribute(.preserveValueOnDeletion)` — the tombstone still carries the id
                // the server knows the record by. Without that attribute the tombstone is
                // empty and deletes cannot sync at all; proven both ways by the migration
                // harness (GLSchema.swift records the gates).
                case .delete(let delete):
                    changes.append(.init(recordType: id.entityName, recordID: id,
                                         kind: .delete,
                                         deletedSyncID: Self.preservedSyncID(from: delete),
                                         changedFields: nil, at: at))
                @unknown default:
                    // A change kind added by a future OS. Over-send rather than lose the edit.
                    changes.append(.init(recordType: id.entityName, recordID: id,
                                         kind: .update, deletedSyncID: nil, changedFields: nil,
                                         at: at))
                }
            }
        }

        return (changes, newToken)
    }

    /// Drop history older than `cutoff`, which nothing else will do for us: the CloudKit
    /// mirroring delegate is what trims the table today, and Phase 3 removes it. Call this
    /// after a successful push, with a cutoff comfortably behind the persisted token — a
    /// device that has been offline for months must still find its window intact.
    static func prune(before cutoff: Date, in context: ModelContext) throws {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.predicate = #Predicate { $0.timestamp < cutoff }
        try context.deleteHistory(descriptor)
    }

    // MARK: - Internals

    /// The identifier of the store history is actually being written to, read from the newest
    /// transaction. `nil` when history is empty.
    private static func liveStoreIdentifier(in context: ModelContext) throws -> String? {
        var probe = HistoryDescriptor<DefaultHistoryTransaction>()
        probe.fetchLimit = 1
        probe.sortBy = [SortDescriptor(\DefaultHistoryTransaction.transactionIdentifier, order: .reverse)]
        return try context.fetchHistory(probe).first?.storeIdentifier
    }

    /// The property names behind an update's key paths, or `nil` if any of them is unreadable.
    ///
    /// Generic rather than taking `any HistoryUpdate`: `updatedAttributes` is typed on the
    /// protocol's `Model`, so it is only reachable by opening the existential, which Swift does
    /// when it is passed to a generic function.
    private static func fieldNames<U: HistoryUpdate>(_ update: U, in schema: Schema) -> [String]? {
        guard let entity = schema.entitiesByName[update.changedPersistentIdentifier.entityName] else {
            return nil
        }
        let known = Set(entity.attributesByName.keys).union(entity.relationshipsByName.keys)

        var names: [String] = []
        for keyPath in update.updatedAttributes {
            // One unreadable key path taints the whole set: a PARTIAL field list would look
            // authoritative and quietly drop a real edit, where a whole-record patch only costs
            // precision.
            guard let name = propertyName(of: keyPath, knownTo: known) else { return nil }
            names.append(wireField(for: name))
        }
        return names.isEmpty ? nil : Array(Set(names))
    }

    /// PROPERTY name → WIRE field. The push filter intersects changedFields with payload
    /// KEYS (GLSyncEngine, `payload.filter { changed.contains($0.key) }`), and the flat
    /// address columns don't appear in any payload — the mappers fold them into the nested
    /// "address"/"customerAddress"/"serviceAddress" objects. Without this translation an
    /// address-only edit filtered down to an updatedAt-only patch and the address itself
    /// NEVER SYNCED (live since build 49 for UserProfile's flats; would have covered all
    /// eight flattened composites after 2026-09-01). Explicit list on purpose: a rename
    /// here must be a conscious act, not a suffix heuristic surprise.
    private static func wireField(for property: String) -> String {
        switch property {
        case "addressStreet1", "addressStreet2", "addressCity",
             "addressState", "addressPostalCode":
            return "address"
        case "customerAddressStreet1", "customerAddressStreet2", "customerAddressCity",
             "customerAddressState", "customerAddressPostalCode":
            return "customerAddress"
        case "serviceAddressStreet1", "serviceAddressStreet2", "serviceAddressCity",
             "serviceAddressState", "serviceAddressPostalCode":
            return "serviceAddress"
        default:
            return property
        }
    }

    /// Swift renders a key path as `\Invoice.total`, and there is no public key-path-to-name
    /// API, so that rendering is the only bridge. Every candidate is checked against the
    /// schema's own property names, so a build whose reflection metadata is stripped degrades
    /// to a whole-record patch instead of inventing a field name the mappers have never heard of.
    private static func propertyName(of keyPath: AnyKeyPath, knownTo known: Set<String>) -> String? {
        let parts = String(describing: keyPath).split(separator: ".")
        guard parts.count > 1 else { return nil }
        for index in 1..<parts.count {
            let candidate = parts[index...].joined(separator: ".")
            if known.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Pull the preserved `syncID` out of a delete's tombstone.
    ///
    /// `HistoryDelete.tombstone` is typed on `Self.Model`, so `any HistoryDelete` cannot reach
    /// it — the generic inner function is what opens the existential. `HistoryTombstone` is a
    /// `Sequence` of the preserved values, and `syncID` is the only preserved attribute in the
    /// schema, so the first (and only) UUID is it. Searching by type rather than by key path
    /// keeps this free of any per-model generic constraint.
    private static func preservedSyncID(from delete: any HistoryDelete) -> UUID? {
        func read<D: HistoryDelete>(_ typed: D) -> UUID? {
            for value in typed.tombstone {
                if let uuid = value as? UUID { return uuid }
            }
            return nil
        }
        return read(delete)
    }

}
