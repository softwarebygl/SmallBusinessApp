//
//  GLSyncModels.swift
//  GLSmallBusiness
//
//  The three @Models GLSync keeps on device (GLSYNC-SPEC.md §3): the OUTBOX — one coalesced
//  row per dirty record — the singleton sync STATE, and the per-record VERSION map.
//
//  SCHEMA (GLSchema.swift rules 1 and 2b). All three are whole-new @Model types, which is
//  additive, so they fold into GLSchemaV1 rather than forcing a frozen GLSchemaV2. Every
//  property below is optional or a plain scalar with a literal default. `Date` is a plain
//  scalar here in the same sense the shipped `createdAt` fields are — SwiftData stores it as
//  a primitive attribute, not as a composite. Rule 2b bans Codable STRUCT properties without
//  `?` (the `Address` shape that crashed builds 39/40); there are none here, and there must
//  never be: the outbox is the queue that holds a business's unsent edits, so a migration
//  that cannot open it is a migration that loses money.
//
//  CloudKit: these three types need NO CloudKit Production schema deploy, which is the one
//  place they differ from every other model in this app. They exist only to drive the
//  gl-business-api transport, and the SAME release that adds them removes
//  `cloudKitDatabase:` from the container (GLSYNC-SPEC.md §7) — so no row of any of them can
//  ever reach a CloudKit zone.
//

import Foundation
import SwiftData

// MARK: - Outbox

/// One dirty record, waiting to be pushed. **State-based and coalescing** (GLSYNC-SPEC.md
/// §2): eight offline hours editing one invoice thirty times is ONE row carrying the LAST
/// value of each touched field, not thirty ops. `baseVersion` is captured when the record
/// FIRST went dirty and never moves after that — it is the server's "nobody else touched
/// this field since" test, so re-stamping it on a later edit would silently claim edits the
/// device never saw.
@Model
final class GLSyncOutboxEntry {

    /// The domain record's `syncID`. Optional per rule 2 (and because a row whose record was
    /// deleted out from under it must be findable to be swept, not crash on read).
    var recordID: UUID?
    /// snake_case manifest key (gl-business-api/sync-manifest.json). NOT the SwiftData
    /// entity name — `GLSyncRegistry` owns that translation.
    var recordType: String = ""
    /// The CASCADE parent's `syncID`, mirrored from `GLSyncMappable.glSyncParentID` at the
    /// moment the row was written. It rides in the op envelope, never in the patch.
    var parentID: UUID?
    /// The record's server version when it first went dirty. `0` = "this record is new".
    var baseVersion: Int = 0
    /// `{field: value}` — the coalesced patch, JSON. Empty object `{}` for a pure delete.
    var fieldsJSON: String = ""
    var isDelete: Bool = false
    /// `[uuid]` — the client-computed cascade subtree, JSON. Only meaningful with `isDelete`.
    var cascadeJSON: String = ""
    /// When this record FIRST went dirty. Drives push order (oldest first) and never moves.
    var firstDirtiedAt: Date = Date.distantPast
    /// When the person LAST touched this record — the history transaction's own timestamp, not
    /// the moment the fold ran or the push left.
    ///
    /// This is what rides as `client_ts`, and the server breaks last-writer-wins ties on it. It
    /// has to be the LAST edit, not the first: a record that goes dirty at 09:00 and is edited
    /// again at 17:00 carries the 17:00 value in `fieldsJSON`, so shipping 09:00 alongside it
    /// would lose that value to another device's 12:00 edit — the newer value, judged by the
    /// older clock.
    var lastDirtiedAt: Date = Date.distantPast
    /// The idempotency key. Stable across RETRIES of the same attempt-set so a push that
    /// succeeded but whose response was lost replays as `cached` instead of double-applying;
    /// re-minted whenever the patch changes, because that is a genuinely different op.
    var opID: UUID?
    var attempts: Int = 0
    /// Free-text disposition. Never shown raw — read it through `parkReason` / `isParked`.
    var lastError: String = ""

    init(
        recordID: UUID?,
        recordType: String,
        parentID: UUID?,
        baseVersion: Int,
        fieldsJSON: String,
        isDelete: Bool = false,
        cascadeJSON: String = "[]",
        firstDirtiedAt: Date = .now
    ) {
        self.recordID = recordID
        self.recordType = recordType
        self.parentID = parentID
        self.baseVersion = baseVersion
        self.fieldsJSON = fieldsJSON
        self.isDelete = isDelete
        self.cascadeJSON = cascadeJSON
        self.firstDirtiedAt = firstDirtiedAt
        self.lastDirtiedAt = firstDirtiedAt
        self.opID = UUID()
    }
}

// MARK: - Outbox parking
//
// A row that the SERVER has already judged must not be pushed again on the next cycle: a
// `conflict` re-contests forever, and a `refused` re-asks a question already answered no.
// Such a row is PARKED — it keeps the user's value (that is the whole point of parking) and
// waits for either a fresh local edit (which rewrites `fieldsJSON` and un-parks it) or a
// human resolution. A row parked by a NETWORK failure is not parked at all, just retried.

extension GLSyncOutboxEntry {

    /// The `lastError` prefix that marks a server-side verdict, as opposed to a transient
    /// transport failure. A prefix rather than a second stored property so the spec's §3
    /// shape stays byte-for-byte what the contract says.
    static let parkPrefix = "parked:"

    /// True when the server has ruled on this row and re-pushing it would only repeat the
    /// argument. Parked rows still count as PENDING for the pull-skip rule (GLSYNC-SPEC.md
    /// §5.4) — the record is contested, so a pulled row must not quietly overwrite it.
    var isParked: Bool { lastError.hasPrefix(Self.parkPrefix) }

    /// The machine reason behind a park (`conflict`, `paid_locked`, …), or nil.
    var parkReason: String? {
        guard isParked else { return nil }
        return String(lastError.dropFirst(Self.parkPrefix.count))
    }

    func park(_ reason: String) { lastError = Self.parkPrefix + reason }

    /// Ready to go on the wire: never pushed, last failed for a reason the network owns, or
    /// HELD for a lapsed subscription (below) — a held row is retried, with its own op id.
    var isReadyToPush: Bool { !isParked }

    // ---- holding (QA 2026-10-03 F17) ---------------------------------------------
    //
    // `subscription_lapsed` is the one refusal that is not a verdict on the record: nothing is
    // wrong with what the person typed, and the Worker deliberately does not cache the refusal
    // because "the client retries the very same op_ids" once they renew (gl-business-api
    // README, "Neither refusal is cached"). Parking it froze the edit on this phone for good.
    // A HELD row keeps its op id and its value, keeps blocking the pull for its record (the
    // person's value is the newest one), and goes out again on every cycle until it lands.

    /// The `lastError` prefix of a held row.
    static let holdPrefix = "held:"

    /// The refusal reason that holds instead of parking.
    static let lapsedReason = "subscription_lapsed"

    /// True while the row waits for the account to be allowed to write again.
    var isHeld: Bool { lastError.hasPrefix(Self.holdPrefix) }

    /// Hold for `reason`. The op id is NOT re-minted: the retry must be the same op.
    func hold(_ reason: String) { lastError = Self.holdPrefix + reason }

    /// A row an older build PARKED for a lapse. Those builds parked every refusal, so the edit
    /// never pushed again; it is released into a held row instead.
    var isParkedForLapse: Bool { parkReason == Self.lapsedReason }

    // ---- patch/cascade coding ---------------------------------------------------
    //
    // JSON in a String column rather than a Codable struct property, exactly as §3 spells
    // it — and rule 2b is the second reason: a struct here would need `?` and every read
    // would carry an unwrap that means nothing.

    /// The coalesced patch. A malformed/empty column reads as `[:]` rather than throwing:
    /// a row we cannot decode must still be sweepable, and an empty patch is a no-op op,
    /// not a crash.
    var fields: GLSyncPayload {
        get { GLSyncOutboxEntry.decodeObject(fieldsJSON) }
        set {
            guard let text = GLSyncOutboxEntry.encode(newValue) else {
                // Unreachable with mapper-built payloads (every value comes from
                // GLSyncValue), but writing "" here would read back as an EMPTY patch and
                // quietly discard the edit. Park loudly and keep the old bytes instead.
                park("unencodable_patch")
                return
            }
            fieldsJSON = text
        }
    }

    /// The client-computed cascade subtree for a delete.
    var cascade: [UUID] {
        get {
            guard let data = cascadeJSON.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
            return raw.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        }
        set {
            let strings = newValue.map { $0.uuidString.lowercased() }
            cascadeJSON = GLSyncOutboxEntry.encode(strings) ?? "[]"
        }
    }

    /// Merge a newer patch over this row: LAST value wins per field, `baseVersion` and
    /// `firstDirtiedAt` are untouched, and the op id is re-minted because the bytes on the
    /// wire are now different (replaying the old id would return the OLD cached result).
    ///
    /// `at` is when that newer edit actually happened — the history transaction's timestamp,
    /// which the fold passes through. It moves `lastDirtiedAt` (the `client_ts` this row will
    /// ship) forward and nothing else; `firstDirtiedAt` staying put is what keeps push order
    /// stable while a record is being worked on.
    func coalesce(_ patch: GLSyncPayload, parentID newParent: UUID?, at: Date = .now) {
        var merged = fields
        for (key, value) in patch { merged[key] = value }
        fields = merged
        parentID = newParent
        lastDirtiedAt = max(lastDirtiedAt, at)
        opID = UUID()
        attempts = 0
        lastError = ""
    }

    /// `nil` — never `""` — when the value will not serialize, so every caller has to say
    /// out loud what it does about that.
    private static func encode(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeObject(_ text: String) -> GLSyncPayload {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? GLSyncPayload else {
            return [:]
        }
        return object
    }
}

// MARK: - Queries

extension GLSyncOutboxEntry {

    /// Every queued row, oldest first. Push ORDER is not this — the engine re-sorts by
    /// parent-before-child depth (`GLSyncRegistry.depth`) so a child never lands before the
    /// parent the server would refuse it without.
    @MainActor
    static func all(in context: ModelContext) -> [GLSyncOutboxEntry] {
        let descriptor = FetchDescriptor<GLSyncOutboxEntry>(
            sortBy: [SortDescriptor(\.firstDirtiedAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The row for one record, if any. `#Predicate` needs a concrete optional binding —
    /// comparing against a non-optional `UUID` does not type-check against `UUID?`.
    @MainActor
    static func entry(for recordID: UUID, in context: ModelContext) -> GLSyncOutboxEntry? {
        let match: UUID? = recordID
        var descriptor = FetchDescriptor<GLSyncOutboxEntry>(
            predicate: #Predicate { $0.recordID == match })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The record ids with a queued row the server has NOT yet ruled on — the pull-skip set
    /// (GLSYNC-SPEC.md §5.4).
    ///
    /// PARKED rows are deliberately absent, and that is the whole of the fix for a freeze that
    /// had no way out: a parked row cannot push (`isReadyToPush` is false until a fresh local
    /// edit re-mints it), so letting it block the PULL as well froze that record in both
    /// directions — the pull skipped it, the cursor advanced past it, and the row was never
    /// offered again. Every later edit anyone made to that customer on any other device
    /// silently never arrived, permanently.
    ///
    /// Letting the pull land does not lose the parked value: parking keeps it in this row's
    /// `fieldsJSON`, which is where a side-by-side pick reads it from — the domain record was
    /// never its storage.
    ///
    /// HELD rows (a lapsed refusal) stay in the set: they still push on every cycle, so they
    /// freeze nothing, and the person's value is newer than anything a lapsed account's other
    /// devices could have written.
    @MainActor
    static func pendingRecordIDs(in context: ModelContext) -> Set<UUID> {
        Set(all(in: context).filter { !$0.isParked }.compactMap(\.recordID))
    }
}

// MARK: - Sync state

/// One row, ever. Everything the engine must remember across launches.
@Model
final class GLSyncState {

    /// The server pull cursor (`seq` watermark). Advanced with the history token, together,
    /// only after a push+pull round lands (GLSYNC-SPEC.md §5.5).
    var cursor: Int = 0
    /// `JSONEncoder().encode(DefaultHistoryToken)` — ~58 bytes. See GLSYNC-SPEC.md §2a(c).
    var lastHistoryTokenData: Data?
    /// This install's device id, minted once. The server breaks LWW ties on it, so a device
    /// that re-mints it every launch would be a different loser each time.
    var deviceID: UUID?
    /// The last time a cycle ended with nothing left to send but parked rows. The Backup row
    /// reads it as "backed up at", so nothing else may write it (QA 2026-10-03 F88).
    var lastSyncAt: Date?
    var lastChecksumAt: Date?
    /// When the history baseline was minted (`GLSyncLocalStore.establishHistoryBaseline`). The
    /// mint needs one real write of its own to watermark; it used to write `lastSyncAt`, so a
    /// first sign-in whose first pull failed showed a backup time with nothing backed up.
    var historyBaselineAt: Date?
    /// False until the first full `/snapshot` page-through AND the first-run upload of the
    /// existing local store have both completed.
    var bootstrapComplete: Bool = false

    /// The MODEL SHAPE the stored `lastHistoryTokenData` was written under.
    ///
    /// SwiftData's persistent history records a change by ATTRIBUTE NAME, and materializing one
    /// resolves that name back to a KeyPath against the CURRENT schema. When the shape has moved
    /// underneath it, that resolution fails a Swift ASSERTION inside
    /// `Schema.KeyPathCache.validateAndCache` — a SIGTRAP, not a thrown error, so `try` cannot
    /// catch it and the app dies before it draws anything.
    ///
    /// That shipped: 3.0.0 (42) crashed at launch for anyone upgrading from 41, because 41's
    /// history holds `syncID` writes made when the property was a plain `var syncID: UUID?` and
    /// 42 redeclared it `@Attribute(.preserveValueOnDeletion) var syncID: UUID?`. Two crash
    /// reports, identical stacks, 100% reproducible on a device with real history.
    ///
    /// So the token alone is not enough to make a history read safe — it must be paired with the
    /// shape it was written under, and a mismatch means DO NOT READ, ever. Nil means "written
    /// before this field existed", which is exactly the poisoned case.
    var historySchemaFingerprint: String?

    /// WHOSE cursor this is: the app token's verified `sub`, which IS the id gl-business-api
    /// partitions records by (index.ts, `UserDB.userId`).
    ///
    /// Without it, a second person signing in on this device inherited the first person's
    /// cursor and `bootstrapComplete`. `seq` is per-user, so that inherited number is not
    /// merely stale — it is from a different counter, sitting above the new account's entire
    /// history, and the device would pull NOTHING for that account forever while believing it
    /// had nothing to catch up on. Meanwhile the first person's records folded into the outbox
    /// and uploaded into the second person's account. `GLSyncLocalStore.bind(owner:)` is the
    /// one writer.
    var ownerID: String?

    /// When the mass-delete circuit breaker last stopped this device, or nil.
    ///
    /// PERSISTED on purpose. It used to live only in `GLSyncEngine.state`, so a relaunch reset
    /// it to `.idle`, re-pulled the same page from the same un-advanced cursor, and tripped
    /// again — forever, with no override and nothing on screen to say why the backup had
    /// stopped.
    var breakerTrippedAt: Date?
    /// What the breaker saw, so the sentence the person reads names a number.
    var breakerDeletions: Int = 0
    var breakerThreshold: Int = 0
    /// The person reviewed the pause and asked to continue. Spent by the next pull that would
    /// otherwise trip, so a SECOND unexpected wave still stops.
    var breakerOverrideArmed: Bool = false

    /// This store holds a PREVIOUS owner's records, so the first-run upload must not run and
    /// push them into the account that is signed in now. Cleared once that bootstrap finishes,
    /// because a later re-bootstrap (checksum self-heal) must still be able to upload.
    var suppressBootstrapUpload: Bool = false

    init() {}
}

extension GLSyncState {

    /// The singleton, created on first read. Extra rows are a bug elsewhere (two engines,
    /// a restored backup); the OLDEST-by-insertion row wins and the rest are deleted rather
    /// than left to make the cursor non-deterministic.
    @MainActor
    static func singleton(in context: ModelContext) -> GLSyncState {
        let rows = (try? context.fetch(FetchDescriptor<GLSyncState>())) ?? []
        if let first = rows.first {
            for extra in rows.dropFirst() { context.delete(extra) }
            if first.deviceID == nil { first.deviceID = UUID() }
            return first
        }
        let state = GLSyncState()
        state.deviceID = UUID()
        context.insert(state)
        return state
    }
}

// MARK: - Per-record server versions

/// One record's last known SERVER version — the `base_version` it pushes with when it next
/// goes dirty (GLSYNC-SPEC.md §5.3, "stamps the new version").
///
/// It is a table rather than a dictionary in the engine because the engine's memory dies with
/// the process. With an in-memory map, the FIRST edit to an already-synced record after a cold
/// launch pushed `base_version: 0`, which tells the server "I have never seen this record" —
/// so it treats every field as concurrent and the protected money fields (taxRatePercent,
/// unitPrice, amount, …) come back as `conflict` and park. Nothing was lost, but the person
/// was asked a question that did not need asking, on the first edit of every day.
///
/// One row per record the server has acknowledged. Written in the SAME save as the outbox row
/// or pulled payload it belongs to (`GLSyncLocalStore.stampVersion`), because a version that
/// lands without its record — or a record without its version — is exactly the desync this
/// exists to prevent.
@Model
final class GLSyncRecordVersion {

    /// The domain record's `syncID`. Optional per rule 2; a row whose id is nil is
    /// unroutable and gets swept rather than read.
    var recordID: UUID?
    /// The server's version counter for that record. `0` is indistinguishable from "no row",
    /// which is correct — both mean "the server has never acknowledged this record".
    var version: Int = 0

    init(recordID: UUID?, version: Int) {
        self.recordID = recordID
        self.version = version
    }
}

extension GLSyncRecordVersion {

    /// The row for one record, if any. Duplicates cannot arise: this table is written only by
    /// `GLSyncLocalStore`, which inserts only after a miss and then holds the row in its cache,
    /// and it never syncs — so a `fetchLimit` of 1 is a complete answer, not a first guess.
    @MainActor
    static func row(for recordID: UUID, in context: ModelContext) -> GLSyncRecordVersion? {
        let match: UUID? = recordID
        var descriptor = FetchDescriptor<GLSyncRecordVersion>(
            predicate: #Predicate { $0.recordID == match })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

// MARK: - The wire-ready view of an outbox row

/// A `Sendable` snapshot of one outbox row, built on the MainActor (where SwiftData lives)
/// and handed to the engine's networking side. The patch rides as its JSON TEXT rather than
/// a dictionary because `[String: Any]` is not `Sendable` — the transport re-parses it when
/// it builds the request body, which costs one pass over a few hundred bytes and buys a
/// concurrency story with no holes in it.
nonisolated struct GLSyncPendingOp: Sendable, Equatable {
    let opID: UUID
    let recordID: UUID
    let recordType: String
    let parentID: UUID?
    let baseVersion: Int
    let patchJSON: String
    let isDelete: Bool
    let cascade: [UUID]
    /// Unix milliseconds. The server CLAMPS this to its own observed time for LWW, so a
    /// device with a fast clock cannot win by being in the future.
    let clientTS: Int
}
