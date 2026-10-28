//
//  GLSyncEngineTests.swift
//  GLSmallBusinessTests
//
//  The regression net for GLSync's DECISION MAKING (GLSYNC-SPEC.md §5, §8). The merge brain
//  is server-side; what is tested here is the set of client rules that decide whether a
//  person's edit survives — get one of them backwards and unsynced work is destroyed
//  silently, on the one device that holds a real business's books.
//
//  WHAT IS UNDER TEST. `GLSyncLocalStore` is where every one of those rules actually lives:
//  pull-overwrites-clean / pull-skips-dirty, the mass-delete circuit breaker, outbox
//  coalescing, delete enqueue + cascade, the per-record version table, push-result
//  application, and the bootstrap upload. It takes a `ModelContainer` and nothing else — no
//  network, no token, no clock — so every test below drives real SwiftData through the real
//  code path and asserts on real persisted state.
//
//  WHOLE CYCLES. `GLSyncEngine.init(container:tokens:cloud:documents:)` takes a token
//  provider and a road out over a stub session, so `GLSyncCycleOwnerTests` (bottom of this
//  file) drives real cycles against an in-memory server: whose session each request goes out
//  under, and what a sign-out does to a cycle in flight. The rest of this file still tests the
//  store's rules directly, which is where they live.
//
//  HOUSE RULES OBSERVED. Every `ModelContainer` comes from `TestStore.makeContainer()`, which
//  RETAINS it for the life of the test process (a released container SIGTRAPs a later test —
//  project_swiftdata_test_process_trap). Fixtures are always seeded and saved BEFORE the
//  store is built, so the store's private context faults each row exactly once and no
//  assertion can be answered by a stale registered object; read-back always happens through a
//  brand-new `ModelContext`.
//

import Testing
import Foundation
import SwiftData
import GoldLifeCloud
@testable import GLSmallBusiness

// MARK: - Fixtures

@MainActor
enum SyncFix {

    /// A store over an already-seeded container. Built LAST, on purpose — see the file header.
    static func store(_ container: ModelContainer) -> GLSyncLocalStore {
        GLSyncLocalStore(container: container)
    }

    /// Commit whatever the store has staged. The store saves through a private `persist()`;
    /// `persistedState()` is the public call that ends in it, so this is how a test flushes
    /// work queued by a method that deliberately does not save on its own
    /// (`enqueueResolvedDelete`, which `fold` persists for).
    @discardableResult
    static func flush(_ store: GLSyncLocalStore) -> GLSyncPersistedState { store.persistedState() }

    /// A reader that cannot hand back a stale object: nothing is registered in it yet.
    static func reader(_ container: ModelContainer) -> ModelContext { ModelContext(container) }

    // ---- wire shapes ------------------------------------------------------------

    static func liveRow(_ id: UUID, type: String, version: Int, seq: Int,
                        parent: UUID? = nil, payload: [String: Any]) -> GLSyncRecordRow {
        GLSyncRecordRow(id: id, type: type, parentID: parent, version: version, seq: seq,
                        deletedAt: nil, payload: GLSyncJSONValue.from(payload))
    }

    static func tombstone(_ id: UUID, type: String = "customer", seq: Int) -> GLSyncRecordRow {
        GLSyncRecordRow(id: id, type: type, parentID: nil, version: 2, seq: seq,
                        deletedAt: 1_787_000_000_000, payload: .null)
    }

    static func tombstones(_ ids: some Sequence<UUID>, from seq: Int) -> [GLSyncRecordRow] {
        ids.enumerated().map { offset, id in tombstone(id, seq: seq + offset) }
    }

    static func result(_ status: GLSyncOpStatus, version: Int? = nil,
                       conflicts: [GLSyncFieldConflict] = [],
                       lost: [GLSyncFieldLoss] = [],
                       reason: GLSyncRefusalReason? = nil) -> GLSyncOpResult {
        GLSyncOpResult(status: status, version: version, appliedFields: [],
                       lwwLost: lost, conflicts: conflicts, reason: reason, head: nil)
    }

    /// `GLSyncRecentChange.Kind` is deliberately not Equatable (it is a log tag, not a value),
    /// so the two readings a test needs get a name here rather than a `case` dance inline.
    static func isContested(_ kind: GLSyncRecentChange.Kind) -> Bool {
        if case .contested = kind { return true }
        return false
    }

    static func isLostToOtherDevice(_ kind: GLSyncRecentChange.Kind) -> Bool {
        if case .lostToOtherDevice = kind { return true }
        return false
    }

    static func outcome(_ verdict: GLSyncPullVerdict) -> GLSyncPullOutcome? {
        if case .applied(let outcome) = verdict { return outcome }
        return nil
    }

    static func refusal(_ verdict: GLSyncPullVerdict) -> (deletions: Int, threshold: Int)? {
        if case .massDeleteRefused(let deletions, let threshold) = verdict {
            return (deletions, threshold)
        }
        return nil
    }

    // ---- local seeding ----------------------------------------------------------

    /// `count` customers with minted ids, saved. Returns their `syncID`s in creation order;
    /// each is named `<prefix><index>` so an assertion can say which one it means.
    @discardableResult
    static func customers(_ count: Int, in context: ModelContext, prefix: String) -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            ids.append(newCustomer(named: "\(prefix)\(index)", in: context))
        }
        context.saveChanges()
        return ids
    }

    /// One customer with a minted id. NOT saved — the caller batches the save.
    @discardableResult
    static func newCustomer(named firstName: String, in context: ModelContext) -> UUID {
        let customer = Customer(firstName: firstName, lastName: "Row")
        let id = UUID()
        customer.syncID = id
        context.insert(customer)
        return id
    }

    /// Save an object graph and mint a `syncID` for every record in it, including the ones
    /// pulled in through relationships.
    static func seed(_ context: ModelContext) {
        try? context.save()
        SyncIdentityBackfill.run(context)
    }

    /// One queued outbox row, saved. This is what "the record has an unsynced edit" means to
    /// every rule in `GLSyncLocalStore` — the pull-skip set is exactly this table.
    @discardableResult
    static func outbox(record id: UUID, type: String, base: Int = 0,
                       fields: GLSyncPayload = [:], parent: UUID? = nil,
                       isDelete: Bool = false, dirtiedAt: Date = .now,
                       in context: ModelContext) -> GLSyncOutboxEntry {
        let row = GLSyncOutboxEntry(recordID: id, recordType: type, parentID: parent,
                                    baseVersion: base, fieldsJSON: "", isDelete: isDelete,
                                    firstDirtiedAt: dirtiedAt)
        row.fields = fields
        context.insert(row)
        context.saveChanges()
        return row
    }

    /// A fixed, unmistakably-not-now instant, so "this timestamp was re-stamped" is a visible
    /// failure rather than a sub-millisecond judgement call.
    static let firstDirtied = Date(timeIntervalSince1970: 1_700_000_000)

    static func stampVersionRow(_ id: UUID, _ version: Int, in context: ModelContext) {
        context.insert(GLSyncRecordVersion(recordID: id, version: version))
        context.saveChanges()
    }

    // ---- read-back --------------------------------------------------------------

    // `#Predicate` needs a concrete OPTIONAL binding: `syncID` is `UUID?`, and comparing it
    // against a non-optional `UUID` does not type-check (the same limitation GLSyncRegistry
    // and SyncIdentityBackfill both document).

    static func loadCustomer(_ id: UUID, in container: ModelContainer) -> Customer? {
        let match: UUID? = id
        var descriptor = FetchDescriptor<Customer>(predicate: #Predicate { $0.syncID == match })
        descriptor.fetchLimit = 1
        return try? reader(container).fetch(descriptor).first
    }

    static func loadInvoice(_ id: UUID, in container: ModelContainer) -> Invoice? {
        let match: UUID? = id
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.syncID == match })
        descriptor.fetchLimit = 1
        return try? reader(container).fetch(descriptor).first
    }

    static func customerCount(_ container: ModelContainer) -> Int {
        (try? reader(container).fetchCount(FetchDescriptor<Customer>())) ?? 0
    }

    static func outboxRows(_ container: ModelContainer) -> [GLSyncOutboxEntry] {
        GLSyncOutboxEntry.all(in: reader(container))
    }

    static func outboxRow(_ id: UUID, in container: ModelContainer) -> GLSyncOutboxEntry? {
        GLSyncOutboxEntry.entry(for: id, in: reader(container))
    }

    static func storedVersion(_ id: UUID, in container: ModelContainer) -> Int? {
        GLSyncRecordVersion.row(for: id, in: reader(container))?.version
    }
}

// MARK: - 1. The non-obvious pull rule (GLSYNC-SPEC.md §5.4)

@MainActor
struct GLSyncPullRuleTests {

    /// A pulled row lands on a CLEAN record. Nothing local is at risk, so the server's copy
    /// wins outright — the direction that keeps two devices converging.
    @Test func pulledRowOverwritesACleanLocalRecord() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Clean").first)

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 5, seq: 11,
                            payload: ["firstName": "Ada", "lastName": "Lovelace"])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1)
        #expect(outcome.skipped == 0)

        let customer = try #require(SyncFix.loadCustomer(id, in: container))
        #expect(customer.firstName == "Ada", "a pulled row did not overwrite a clean record")
        #expect(customer.lastName == "Lovelace")
        #expect(SyncFix.storedVersion(id, in: container) == 5,
                "the server version must be stamped in the same save as the payload it describes")
    }

    /// THE rule that destroys work when it is backwards: a record with a queued outbox row is
    /// SKIPPED. The local value must still be the person's unsent edit afterwards.
    @Test func pulledRowIsSkippedForARecordWithAPendingOutboxEntry() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = SyncFix.newCustomer(named: "Unsent", in: context)
        context.saveChanges()
        SyncFix.outbox(record: id, type: "customer",
                       fields: ["firstName": "Unsent"], in: context)

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 9, seq: 12,
                            payload: ["firstName": "Server", "lastName": "Overwrote"])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.skipped == 1)
        #expect(outcome.applied == 0)

        let customer = try #require(SyncFix.loadCustomer(id, in: container))
        #expect(customer.firstName == "Unsent",
                "a pulled row overwrote a record with an unsent edit — that edit is now gone")
        #expect(customer.lastName == "Row", "the skip must be whole-record, not per-field")
        #expect(SyncFix.storedVersion(id, in: container) == nil,
                "a skipped row must not stamp a version the local record does not carry")
    }

    /// Both directions in ONE page, which is the shape a real pull arrives in. Getting the
    /// pair right is the whole point: the clean neighbour must not be held back by the dirty
    /// one, and the dirty one must not be flattened by the clean one.
    @Test func onePageAppliesTheCleanRowAndSkipsTheDirtyOne() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(2, in: context, prefix: "Mixed")
        let clean = ids[0]
        let dirty = ids[1]
        SyncFix.outbox(record: dirty, type: "customer",
                       fields: ["firstName": "Mine"], in: context)

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(clean, type: "customer", version: 2, seq: 20,
                            payload: ["firstName": "ServerClean"]),
            SyncFix.liveRow(dirty, type: "customer", version: 3, seq: 21,
                            payload: ["firstName": "ServerDirty"]),
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1)
        #expect(outcome.skipped == 1)
        #expect(SyncFix.loadCustomer(clean, in: container)?.firstName == "ServerClean")
        #expect(SyncFix.loadCustomer(dirty, in: container)?.firstName == "Mixed1",
                "the dirty record must keep its local value, not the server's")
    }

    /// A row for an id this device has never seen creates the record. Without this a second
    /// device never learns anything, and "sync" is only ever a one-way overwrite.
    @Test func pulledRowForAnUnknownIDCreatesTheRecord() throws {
        let container = try TestStore.makeContainer()
        let id = UUID()

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 1, seq: 3,
                            payload: ["firstName": "Brand", "lastName": "New"])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1)
        let created = try #require(SyncFix.loadCustomer(id, in: container))
        #expect(created.firstName == "Brand")
        #expect(created.syncID == id, "a created record must carry the SERVER's id, not a fresh one")
    }

    /// A pulled TOMBSTONE is subject to the same skip. A queued edit means the record is
    /// contested, and a delete that lands anyway takes the unsent edit with it.
    @Test func pulledTombstoneIsSkippedForARecordWithAPendingEdit() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(2, in: context, prefix: "Tomb")
        let contested = ids[0]
        let quiet = ids[1]
        SyncFix.outbox(record: contested, type: "customer",
                       fields: ["firstName": "StillEditing"], in: context)

        let store = SyncFix.store(container)
        let verdict = store.applyChanges(SyncFix.tombstones([contested, quiet], from: 30))

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.deleted == 1)
        #expect(outcome.skipped == 1)
        #expect(SyncFix.loadCustomer(contested, in: container) != nil,
                "a pulled delete removed a record that still had an unsent edit")
        #expect(SyncFix.loadCustomer(quiet, in: container) == nil,
                "an uncontested tombstone must actually delete")
    }

    /// A type this build has never heard of is counted, never guessed at. A newer build's
    /// record must not be able to land as an empty row of some other type.
    @Test func pulledRowOfAnUnknownTypeIsCountedAndNotApplied() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        let verdict = store.applyChanges([
            SyncFix.liveRow(UUID(), type: "warranty_claim", version: 1, seq: 4,
                            payload: ["title": "From a newer build"])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.unknownType == 1)
        #expect(outcome.applied == 0)
        #expect(SyncFix.customerCount(container) == 0)
    }

    /// The parent id rides in the op ENVELOPE, so relinking is the store's job, not a
    /// mapper's — and seq is write order, not tree order, so a child can precede its parent
    /// inside one page and must still end up attached.
    @Test func aChildPulledAheadOfItsParentIsStillLinkedWithinTheSamePage() throws {
        let container = try TestStore.makeContainer()
        let customerID = UUID()
        let invoiceID = UUID()

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            // The parent is LATER in the stream. Payloads land in pass one, links in pass two.
            SyncFix.liveRow(invoiceID, type: "invoice", version: 1, seq: 40, parent: customerID,
                            payload: ["number": "INV-0100", "jobTitle": "Backsplash"]),
            SyncFix.liveRow(customerID, type: "customer", version: 1, seq: 41,
                            payload: ["firstName": "Late", "lastName": "Parent"]),
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 2)
        #expect(outcome.unlinked.isEmpty,
                "the parent arrived in the same page, so nothing should be left unlinked")

        let invoice = try #require(SyncFix.loadInvoice(invoiceID, in: container))
        #expect(invoice.customer?.syncID == customerID, "a pulled child was left orphaned")
    }

    /// A child whose parent has not arrived at all is REPORTED, not dropped and not attached
    /// to a stub. A phantom customer in the customer list is worse than a link that lands on
    /// the next page.
    @Test func pulledChildWithAMissingParentIsReturnedAsUnlinked() throws {
        let container = try TestStore.makeContainer()
        let invoiceID = UUID()
        let absentParent = UUID()

        let store = SyncFix.store(container)
        let verdict = store.applyChanges([
            SyncFix.liveRow(invoiceID, type: "invoice", version: 1, seq: 41,
                            parent: absentParent,
                            payload: ["number": "INV-0101", "jobTitle": "Orphan"]),
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1, "the payload still lands; only the link is deferred")
        #expect(outcome.unlinked.count == 1)
        #expect(outcome.unlinked.first?.recordID == invoiceID)
        #expect(outcome.unlinked.first?.parentID == absentParent)
        #expect(SyncFix.customerCount(container) == 0, "a stub parent must never be minted")
    }
}

// MARK: - 2. Mass-delete circuit breaker (GLSYNC-SPEC.md §5)

@MainActor
struct GLSyncMassDeleteBreakerTests {

    /// 30 local records → threshold `max(25, 3) == 25`. 26 tombstones is over it, so the
    /// WHOLE page is refused and NOTHING is deleted: a server bug costs one paused device,
    /// not a wiped business.
    @Test func aPullOverTheThresholdIsRefusedWholeAndDeletesNothing() throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Breaker")

        let store = SyncFix.store(container)
        let verdict = store.applyChanges(SyncFix.tombstones(ids.prefix(26), from: 100))

        let refusal = try #require(SyncFix.refusal(verdict))
        #expect(refusal.deletions == 26)
        #expect(refusal.threshold == 25, "the floor is 25 records, not 10% of a small store")
        #expect(SyncFix.customerCount(container) == 30,
                "the breaker tripped but rows were deleted anyway — the refusal must be whole-page")
    }

    /// The other half of the same rule: a breaker that always trips is as broken as one that
    /// never does. 25 of 30 is exactly AT the threshold and must apply.
    @Test func aPullAtTheThresholdAppliesNormally() throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Under")

        let store = SyncFix.store(container)
        let verdict = store.applyChanges(SyncFix.tombstones(ids.prefix(25), from: 200))

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.deleted == 25)
        #expect(SyncFix.customerCount(container) == 5,
                "a legitimate cleanup just under the threshold must go through")
    }

    /// The 10% arm, which is what protects a store big enough that 25 rows is noise. 300
    /// records → threshold 30: 31 refuses, 30 applies.
    @Test func thresholdScalesToTenPercentOnALargeStore() throws {
        let refusing = try TestStore.makeContainer()
        let refusingIDs = SyncFix.customers(300, in: SyncFix.reader(refusing), prefix: "Big")
        let refusingStore = SyncFix.store(refusing)
        let refused = try #require(SyncFix.refusal(
            refusingStore.applyChanges(SyncFix.tombstones(refusingIDs.prefix(31), from: 300))))
        #expect(refused.deletions == 31)
        #expect(refused.threshold == 30, "10% of 300, which is larger than the 25 floor")
        #expect(SyncFix.customerCount(refusing) == 300)

        let applying = try TestStore.makeContainer()
        let applyingIDs = SyncFix.customers(300, in: SyncFix.reader(applying), prefix: "Big")
        let applyingStore = SyncFix.store(applying)
        let outcome = try #require(SyncFix.outcome(
            applyingStore.applyChanges(SyncFix.tombstones(applyingIDs.prefix(30), from: 400))))
        #expect(outcome.deleted == 30)
        #expect(SyncFix.customerCount(applying) == 270)
    }

    /// A refused page must leave the whole page unapplied, LIVE rows included — a partial
    /// apply is the worst of both worlds, and a version stamped for a row that never landed
    /// is a lie the next push acts on.
    @Test func aRefusedPullAppliesNoneOfItsLiveRowsEither() throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Refused")
        let survivor = ids[0]

        let store = SyncFix.store(container)
        var rows = [
            SyncFix.liveRow(survivor, type: "customer", version: 7, seq: 500,
                            payload: ["firstName": "ShouldNotLand"])
        ]
        rows += SyncFix.tombstones(ids.suffix(26), from: 501)
        let verdict = store.applyChanges(rows)

        #expect(SyncFix.refusal(verdict) != nil)
        #expect(SyncFix.loadCustomer(survivor, in: container)?.firstName == "Refused0",
                "a live row from a refused page was applied anyway")
        #expect(SyncFix.storedVersion(survivor, in: container) == nil)
        #expect(SyncFix.customerCount(container) == 30)
    }

    /// Tombstones for CONTESTED records are skipped before the count is taken, so a page that
    /// would only delete uncontested rows is judged on that smaller number.
    @Test func tombstonesForRecordsWithPendingEditsDoNotCountTowardTheThreshold() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(30, in: context, prefix: "Contested")
        for id in ids.prefix(2) {
            SyncFix.outbox(record: id, type: "customer", fields: ["firstName": "Mine"], in: context)
        }

        let store = SyncFix.store(container)
        // 27 tombstones, 2 of them contested → 25 real deletions, exactly at the threshold.
        let verdict = store.applyChanges(SyncFix.tombstones(ids.prefix(27), from: 600))

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.deleted == 25)
        #expect(outcome.skipped == 2)
        #expect(SyncFix.loadCustomer(ids[0], in: container) != nil)
        #expect(SyncFix.loadCustomer(ids[1], in: container) != nil)
        #expect(SyncFix.customerCount(container) == 5)
    }

    /// A tombstone for a record this device never had is not a deletion. Counting it would
    /// let a long tombstone backlog trip the breaker on a device with nothing to lose.
    @Test func tombstonesForRecordsThisDeviceDoesNotHaveAreNotCountedAsDeletions() throws {
        let container = try TestStore.makeContainer()
        SyncFix.customers(30, in: SyncFix.reader(container), prefix: "Ghost")

        let store = SyncFix.store(container)
        let verdict = store.applyChanges(SyncFix.tombstones((0..<200).map { _ in UUID() }, from: 700))

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.deleted == 0)
        #expect(SyncFix.customerCount(container) == 30)
    }
}

// MARK: - 3. Outbox coalescing (GLSYNC-SPEC.md §2, §3)

@MainActor
struct GLSyncOutboxCoalescingTests {

    /// Eight offline hours editing one invoice thirty times is ONE row carrying the LAST value
    /// of each touched field. An op log here would push thirty ops and contest itself.
    @Test func manyEditsToOneRecordCoalesceIntoOneRowWithTheLastValuePerField() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoiceID = UUID()
        let row = SyncFix.outbox(record: invoiceID, type: "invoice", base: 4,
                                 fields: ["jobTitle": "Kitchen", "taxRatePercent": 7.0],
                                 dirtiedAt: SyncFix.firstDirtied, in: context)
        let firstOpID = try #require(row.opID)

        for step in 1...30 {
            row.coalesce(["taxRatePercent": Double(step)], parentID: nil)
        }
        row.coalesce(["customerNotes": "Call before 8"], parentID: nil)
        context.saveChanges()

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "thirty-one edits produced \(rows.count) outbox rows, not one")
        let saved = try #require(rows.first)
        #expect(GLSyncValue.double(saved.fields, "taxRatePercent") == 30,
                "the LAST value of a repeatedly-edited field must win")
        #expect(GLSyncValue.string(saved.fields, "jobTitle") == "Kitchen",
                "a field nobody touched again was dropped by coalescing")
        #expect(GLSyncValue.string(saved.fields, "customerNotes") == "Call before 8",
                "a field first touched mid-window never made it into the patch")
        #expect(saved.baseVersion == 4, "coalescing moved base_version")
        #expect(saved.firstDirtiedAt == SyncFix.firstDirtied,
                "coalescing re-stamped first-dirtied-at, which is the outbox's push-order key")
        #expect(saved.opID != firstOpID,
                "the patch bytes changed, so the idempotency key must be re-minted — replaying the old id returns the OLD cached result")
    }

    /// `base_version` is captured when the record FIRST goes dirty and never moves. A newer
    /// server version arriving while the row waits must not be folded in: re-stamping it
    /// claims "nobody touched this since" for edits the device never saw.
    @Test func baseVersionIsCapturedAtFirstDirtyAndSurvivesALaterVersionStamp() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoiceID = UUID()
        let row = SyncFix.outbox(record: invoiceID, type: "invoice", base: 4,
                                 fields: ["jobTitle": "Bath"], in: context)

        // The server acknowledged this record at version 12 while the row sat queued.
        SyncFix.stampVersionRow(invoiceID, 12, in: context)
        row.coalesce(["jobTitle": "Bath — revised"], parentID: nil)
        context.saveChanges()

        let saved = try #require(SyncFix.outboxRow(invoiceID, in: container))
        #expect(saved.baseVersion == 4,
                "base_version followed the newest known version instead of staying at first-dirty")
        #expect(GLSyncValue.string(saved.fields, "jobTitle") == "Bath — revised")
    }

    /// The complement: a row created AFTER the server acknowledged the record picks that
    /// version up. First-dirty means "the version at the moment the row was written", not 0.
    @Test func aRowCreatedAfterAnAcknowledgementCapturesTheKnownVersion() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        SyncFix.stampVersionRow(id, 11, in: context)

        let store = SyncFix.store(container)
        #expect(store.enqueueResolvedDelete(recordID: id, type: "invoice"))
        SyncFix.flush(store)

        #expect(SyncFix.outboxRow(id, in: container)?.baseVersion == 11,
                "a newly dirty record pushed base_version 0 and will contest every money field")
    }

    /// A fresh local edit UN-PARKS a row the server had already ruled on. Without this a
    /// conflicted record can never be pushed again and the person's fix never leaves the
    /// device.
    @Test func aFreshEditUnparksARowTheServerHadRuledOn() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoiceID = UUID()
        let row = SyncFix.outbox(record: invoiceID, type: "invoice", base: 3,
                                 fields: ["taxRatePercent": 7.0], in: context)
        row.park("conflict")
        row.attempts = 4
        context.saveChanges()
        #expect(row.isParked)
        #expect(row.isReadyToPush == false)

        row.coalesce(["taxRatePercent": 8.25], parentID: nil)
        context.saveChanges()

        let saved = try #require(SyncFix.outboxRow(invoiceID, in: container))
        #expect(saved.isParked == false, "a fresh edit left the row parked — it will never push")
        #expect(saved.parkReason == nil)
        #expect(saved.attempts == 0)
        #expect(saved.isReadyToPush)
        #expect(GLSyncValue.double(saved.fields, "taxRatePercent") == 8.25)
    }

    /// A parked row is held back from the wire — pushing it re-argues a point the server has
    /// already settled — but it does NOT block the pull.
    ///
    /// This assertion used to read the other way, and that was the bug: a parked row cannot
    /// push, so blocking the pull as well froze the record in BOTH directions. The cursor
    /// advanced past the skipped row, it was never offered again, and every later edit from
    /// every other device was lost permanently. The person's value is not lost by letting the
    /// pull land — parking keeps it in `fieldsJSON`, which is where a side-by-side pick reads
    /// it from. (Full coverage in GLSyncHardeningTests.)
    @Test func aParkedRowIsHeldBackFromPushButDoesNotBlockAPull() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Parked").first)
        let row = SyncFix.outbox(record: id, type: "customer",
                                 fields: ["firstName": "Parked0"], in: context)
        row.park("paid_locked")
        context.saveChanges()

        let store = SyncFix.store(container)
        #expect(store.pendingOps(limit: 50).isEmpty, "a parked row was queued for the wire")

        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 4, seq: 800,
                            payload: ["firstName": "Server"])
        ])
        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1, "a parked record was skipped, freezing it in both directions")
        #expect(SyncFix.loadCustomer(id, in: container)?.firstName == "Server")
        #expect(SyncFix.outboxRow(id, in: container)?.isParked == true,
                "the park itself must survive — it still holds the person's value")
    }

    /// A patch that will not serialize must never read back as an EMPTY patch: an empty patch
    /// is a silently discarded edit. The row parks loudly and keeps its old bytes.
    @Test func anUnencodablePatchParksRatherThanEmptyingTheRow() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        let row = SyncFix.outbox(record: id, type: "invoice", base: 1,
                                 fields: ["jobTitle": "Real work"], in: context)

        row.fields = ["jobTitle": Date()]   // Date is not JSON — JSONSerialization refuses it.
        context.saveChanges()

        let saved = try #require(SyncFix.outboxRow(id, in: container))
        #expect(GLSyncValue.string(saved.fields, "jobTitle") == "Real work",
                "an unencodable write wiped the queued patch")
        #expect(saved.parkReason == "unencodable_patch")
    }

    /// Push order is parent-before-child FIRST, then oldest-first inside a depth. Depth is
    /// what stops `bad_parent`; the age tie-break is what keeps a FIFO settlement's ops in the
    /// order the app wrote them (README §6).
    @Test func pushOrderIsDepthThenOldestFirst() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let newerParent = UUID()
        let olderParent = UUID()
        let child = UUID()
        // Inserted youngest-first so a stable-but-unsorted implementation would fail.
        SyncFix.outbox(record: child, type: "invoice_line_item", fields: ["unitPrice": 1.0],
                       dirtiedAt: SyncFix.firstDirtied, in: context)
        SyncFix.outbox(record: newerParent, type: "invoice", fields: ["jobTitle": "Newer"],
                       dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(60), in: context)
        SyncFix.outbox(record: olderParent, type: "invoice", fields: ["jobTitle": "Older"],
                       dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(10), in: context)

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)

        #expect(ops.map(\.recordID) == [olderParent, newerParent, child],
                "push order was \(ops.map(\.recordType)) — a child ahead of its parent is refused bad_parent and parks a row that was never wrong")
    }

    /// The chunk cap is honoured, and it takes the FRONT of that order — otherwise a full
    /// outbox would push children first forever.
    @Test func pendingOpsHonoursTheChunkLimitFromTheFrontOfThePushOrder() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let parents = (0..<3).map { _ in UUID() }
        let children = (0..<3).map { _ in UUID() }
        for (index, id) in children.enumerated() {
            SyncFix.outbox(record: id, type: "invoice_line_item", fields: ["unitPrice": 1.0],
                           dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(Double(index)),
                           in: context)
        }
        for (index, id) in parents.enumerated() {
            SyncFix.outbox(record: id, type: "invoice", fields: ["jobTitle": "P\(index)"],
                           dirtiedAt: SyncFix.firstDirtied.addingTimeInterval(Double(index)),
                           in: context)
        }

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 3)

        #expect(ops.count == 3)
        #expect(Set(ops.map(\.recordID)) == Set(parents),
                "the first chunk must be the three parents, not whatever the fetch returned first")
    }

    /// A row that can be neither named nor routed can never be pushed, and leaving it queued
    /// would block that record from ever being PULLED (§5.4). It is swept.
    @Test func pendingOpsSweepsRowsItCanNeitherNameNorRoute() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let good = UUID()
        SyncFix.outbox(record: good, type: "customer", fields: ["firstName": "Fine"], in: context)
        SyncFix.outbox(record: UUID(), type: "warranty_claim", fields: ["x": 1.0], in: context)
        let nameless = GLSyncOutboxEntry(recordID: nil, recordType: "customer",
                                         parentID: nil, baseVersion: 0, fieldsJSON: "{}")
        context.insert(nameless)
        context.saveChanges()
        #expect(SyncFix.outboxRows(container).count == 3)

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)

        #expect(ops.count == 1)
        #expect(ops.first?.recordID == good)
        #expect(SyncFix.outboxRows(container).count == 1,
                "unroutable rows were left queued, blocking their records from ever pulling")
    }
}

// MARK: - 4. Delete enqueue (GLSYNC-SPEC.md §5, §2a)

@MainActor
struct GLSyncDeleteEnqueueTests {

    /// The history-driven path: the record is already gone, so the op is written from the
    /// tombstone's `syncID` alone — no parent (parentage only gates creates) and no cascade
    /// (each cascaded row arrives as its OWN tombstone).
    @Test func aHistoryDrivenDeleteCarriesTheRecoveredSyncIDAndTheKnownVersion() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let gone = UUID()
        SyncFix.stampVersionRow(gone, 6, in: context)

        let store = SyncFix.store(container)
        #expect(store.enqueueResolvedDelete(recordID: gone, type: "invoice"))
        SyncFix.flush(store)

        let row = try #require(SyncFix.outboxRow(gone, in: container))
        #expect(row.isDelete)
        #expect(row.recordID == gone, "the delete must name the record the SERVER knows")
        #expect(row.recordType == "invoice")
        #expect(row.parentID == nil)
        #expect(row.cascade.isEmpty)
        #expect(row.fieldsJSON == "{}")
        #expect(row.baseVersion == 6)
        #expect(SyncFix.storedVersion(gone, in: container) == nil,
                "the record is gone for good; a stale version row can only ever be wrong")
    }

    /// A queued EDIT for a record that has since been deleted is moot and must be dropped —
    /// pushing it would resurrect an argument about a dead row.
    @Test func aHistoryDrivenDeleteDropsThePendingEditForThatRecord() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let gone = UUID()
        SyncFix.outbox(record: gone, type: "customer",
                       fields: ["firstName": "Edited then deleted"], in: context)

        let store = SyncFix.store(container)
        #expect(store.enqueueResolvedDelete(recordID: gone, type: "customer"))
        SyncFix.flush(store)

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "the pending edit and the delete both queued for one record")
        #expect(rows.first?.isDelete == true)
        #expect(rows.first?.fields.isEmpty == true, "the dead record's field patch survived")
    }

    /// Re-enqueuing a delete already queued is a no-op. It must not re-mint the op id — that
    /// key is what makes a lost response replay as `cached` instead of double-applying.
    @Test func aSecondHistoryDrivenDeleteForTheSameRecordIsANoOp() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        let gone = UUID()

        #expect(store.enqueueResolvedDelete(recordID: gone, type: "customer"))
        SyncFix.flush(store)
        let firstOpID = SyncFix.outboxRow(gone, in: container)?.opID
        #expect(firstOpID != nil)

        #expect(store.enqueueResolvedDelete(recordID: gone, type: "customer") == false)
        SyncFix.flush(store)

        #expect(SyncFix.outboxRows(container).count == 1)
        #expect(SyncFix.outboxRow(gone, in: container)?.opID == firstOpID,
                "re-queuing an unchanged delete re-minted its idempotency key")
    }

    /// A delete for a type this build cannot route is refused rather than queued as a row that
    /// could never be pushed.
    @Test func aDeleteForAnUnknownTypeIsRefused() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        #expect(store.enqueueResolvedDelete(recordID: UUID(), type: "warranty_claim") == false)
        SyncFix.flush(store)
        #expect(SyncFix.outboxRows(container).isEmpty)
    }

    /// The live-record path walks the MANIFEST's parent chain while the rows still exist and
    /// ships ONE op carrying the whole subtree — the Worker verifies every cascade id chains
    /// to the delete root through `parent_id`.
    @Test func deletingAnInvoiceEnqueuesOneOpCarryingItsWholeCascadeSubtree() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let customer = Customer(firstName: "Cascade", lastName: "Owner")
        let invoice = TS.invoice(number: "INV-0200", lines: [(100, false), (200, false)])
        invoice.customer = customer
        TS.pay(invoice, 50)
        context.insert(customer)
        context.insert(invoice)
        SyncFix.seed(context)

        let invoiceID = try #require(invoice.syncID)
        let customerID = try #require(customer.syncID)
        let groupID = try #require(invoice.groups?.first?.syncID)
        let lineIDs = Set((invoice.groups?.first?.lineItems ?? []).compactMap(\.syncID))
        let paymentID = try #require(invoice.payments?.first?.syncID)
        #expect(lineIDs.count == 2)

        let store = SyncFix.store(container)
        #expect(store.enqueueDelete(recordID: invoiceID, type: "invoice"))

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "a cascade delete must be ONE op, not one per row")
        let row = try #require(rows.first)
        #expect(row.isDelete)
        #expect(row.recordType == "invoice")
        #expect(row.parentID == customerID, "the delete op must carry the record's cascade parent")
        let cascade = Set(row.cascade)
        #expect(cascade.count == 4, "expected group + 2 line items + payment, got \(cascade.count)")
        #expect(cascade.contains(groupID))
        #expect(cascade.isSuperset(of: lineIDs))
        #expect(cascade.contains(paymentID))
        #expect(cascade.contains(invoiceID) == false,
                "the delete ROOT must not also appear inside its own cascade")
    }

    /// Every pending edit anywhere in the subtree dies with it. Leaving one queued would push
    /// a patch for a row the same chunk deletes.
    @Test func deletingAnInvoiceDropsPendingEditsForEveryRowInTheSubtree() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoice = TS.invoice(number: "INV-0201", lines: [(100, false)])
        context.insert(invoice)
        SyncFix.seed(context)

        let invoiceID = try #require(invoice.syncID)
        let groupID = try #require(invoice.groups?.first?.syncID)
        let lineID = try #require(invoice.groups?.first?.lineItems?.first?.syncID)
        SyncFix.outbox(record: invoiceID, type: "invoice", fields: ["jobTitle": "x"], in: context)
        SyncFix.outbox(record: groupID, type: "invoice_group", fields: ["name": "y"], in: context)
        SyncFix.outbox(record: lineID, type: "invoice_line_item",
                       fields: ["unitPrice": 9.0], in: context)
        #expect(SyncFix.outboxRows(container).count == 3)

        let store = SyncFix.store(container)
        #expect(store.enqueueDelete(recordID: invoiceID, type: "invoice"))

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "a subtree edit survived the delete that removes its row")
        #expect(rows.first?.isDelete == true)
        #expect(rows.first?.recordID == invoiceID)
    }

    /// The one place SwiftData's cascade and the MANIFEST's disagree. An applied change order
    /// owns an InvoiceGroup locally, but that group's SERVER parent is the INVOICE — naming it
    /// in the change order's cascade fails the Worker's parentage walk, so it gets its own
    /// top-level delete op.
    @Test func deletingAnAppliedChangeOrderAlsoEnqueuesItsInvoiceGroupAsItsOwnOp() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let invoice = TS.invoice(number: "INV-0202", lines: [(500, false)])
        let order = TS.changeOrder(invoice, status: .approved, applied: true, lines: [(75, false)])
        let billed = InvoiceGroup(name: "Change order CO-0001", sortIndex: 9)
        billed.invoice = invoice
        order.invoiceGroup = billed
        context.insert(invoice)
        context.insert(order)
        context.insert(billed)
        SyncFix.seed(context)

        let orderID = try #require(order.syncID)
        let billedID = try #require(billed.syncID)
        let orderLineIDs = Set((order.lineItems ?? []).compactMap(\.syncID))
        #expect(orderLineIDs.count == 1)

        let store = SyncFix.store(container)
        #expect(store.enqueueDelete(recordID: orderID, type: "change_order"))

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 2,
                "an applied change order deletes as TWO top-level ops, got \(rows.count)")
        #expect(Set(rows.map(\.recordType)) == ["change_order", "invoice_group"])

        let orderRow = try #require(rows.first { $0.recordType == "change_order" })
        #expect(orderRow.recordID == orderID)
        #expect(orderRow.isDelete)
        #expect(Set(orderRow.cascade) == orderLineIDs,
                "the change order's cascade must be its own line items only")
        #expect(orderRow.cascade.contains(billedID) == false,
                "the billed group is NOT a manifest child — naming it refuses the whole delete")

        let groupRow = try #require(rows.first { $0.recordType == "invoice_group" })
        #expect(groupRow.recordID == billedID)
        #expect(groupRow.isDelete)
    }

    /// The history path emits ONE tombstone per cascaded row, so folding it produces one
    /// delete op per row — the complement of the single-op live path above.
    @Test func aHistoryFoldOfACascadeProducesOneDeleteOpPerRow() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        let parent = UUID()
        let child = UUID()
        let grandchild = UUID()

        // Children before parents, exactly the order SwiftData reports a cascade in.
        #expect(store.enqueueResolvedDelete(recordID: grandchild, type: "invoice_line_item"))
        #expect(store.enqueueResolvedDelete(recordID: child, type: "invoice_group"))
        #expect(store.enqueueResolvedDelete(recordID: parent, type: "invoice"))
        SyncFix.flush(store)

        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.isDelete })
        #expect(rows.allSatisfy { $0.cascade.isEmpty },
                "a tombstone-driven delete names only itself; children arrive on their own")
        #expect(Set(rows.compactMap(\.recordID)) == [parent, child, grandchild])
    }

    /// A delete for a record that is no longer here cannot walk a cascade, so the live path
    /// declines rather than queuing a subtree-less op that would orphan children server-side.
    @Test func theLiveDeletePathDeclinesWhenTheRecordIsAlreadyGone() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        #expect(store.enqueueDelete(recordID: UUID(), type: "invoice") == false)
        #expect(SyncFix.outboxRows(container).isEmpty)
    }
}

// MARK: - 5. The per-record version cache (GLSYNC-SPEC.md §5.3)

@MainActor
struct GLSyncVersionCacheTests {

    /// The whole reason this is a TABLE and not a dictionary in the engine: the engine's
    /// memory dies with the process. Write it, drop the in-memory state (a second store over
    /// the same container IS a cold start), read it back.
    @Test func aStampedVersionSurvivesAColdStart() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Cold").first)

        let first = SyncFix.store(container)
        _ = first.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 5, seq: 900,
                            payload: ["firstName": "Stamped"])
        ])
        #expect(SyncFix.storedVersion(id, in: container) == 5)

        // Cold start: nothing of the first store's cache survives.
        let second = SyncFix.store(container)
        #expect(second.enqueueResolvedDelete(recordID: id, type: "customer"))
        SyncFix.flush(second)

        let row = try #require(SyncFix.outboxRow(id, in: container))
        #expect(row.baseVersion == 5,
                "after a cold launch the first op carried base_version \(row.baseVersion) — 0 tells the server 'I have never seen this record' and contests every money field")
    }

    /// MAX-merge, never plain assignment. A push result and a pulled row for the same record
    /// can land in either order inside one cycle; moving a version BACKWARDS re-contests
    /// fields the server has already merged.
    @Test func anOutOfOrderPulledVersionNeverMovesTheVersionBackwards() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Max").first)

        let store = SyncFix.store(container)
        _ = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 9, seq: 910,
                            payload: ["firstName": "Nine"])
        ])
        #expect(SyncFix.storedVersion(id, in: container) == 9)

        _ = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 4, seq: 911,
                            payload: ["firstName": "Four"])
        ])
        #expect(SyncFix.storedVersion(id, in: container) == 9,
                "a late-arriving older version moved the record's version backwards")
    }

    /// The same MAX rule on the OTHER writer: a push result reporting an older version must
    /// not undo a newer one a pull already stamped.
    @Test func anOutOfOrderPushResultNeverMovesTheVersionBackwards() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        SyncFix.stampVersionRow(id, 9, in: context)
        SyncFix.outbox(record: id, type: "customer", base: 9,
                       fields: ["firstName": "Later"], in: context)

        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 10)
        let op = try #require(ops.first)
        _ = store.applyResults([op.opID: SyncFix.result(.applied, version: 3)], for: ops)

        #expect(SyncFix.storedVersion(id, in: container) == 9,
                "an out-of-order push result moved the version backwards")
    }

    /// A pulled tombstone drops the version row. uuids are never reused, so a version for a
    /// dead record can only ever be wrong.
    @Test func aPulledTombstoneDropsTheRecordsVersionRow() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Dead").first)
        SyncFix.stampVersionRow(id, 12, in: context)

        let store = SyncFix.store(container)
        _ = store.applyChanges(SyncFix.tombstones([id], from: 920))

        #expect(SyncFix.loadCustomer(id, in: container) == nil)
        #expect(SyncFix.storedVersion(id, in: container) == nil,
                "the version row outlived the record it describes")
    }

    /// A record the server has never acknowledged reads as 0, which is exactly what the wire
    /// calls a create — "no row" and "version 0" must be the same answer.
    @Test func anUnknownRecordReadsAsVersionZero() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        let id = UUID()

        #expect(store.enqueueResolvedDelete(recordID: id, type: "customer"))
        SyncFix.flush(store)

        #expect(SyncFix.outboxRow(id, in: container)?.baseVersion == 0)
    }
}

// MARK: - 6. Applying push results (GLSYNC-SPEC.md §5.3)

@MainActor
struct GLSyncPushResultTests {

    /// One queued invoice edit, ready to be judged. `taxRatePercent` is a manifest-protected
    /// money field, so it is exactly the shape that comes back contested.
    private func queuedInvoiceEdit(_ container: ModelContainer)
    throws -> (store: GLSyncLocalStore, id: UUID, ops: [GLSyncPendingOp]) {
        let context = SyncFix.reader(container)
        let id = UUID()
        SyncFix.outbox(record: id, type: "invoice", base: 4,
                       fields: ["taxRatePercent": 8.25, "jobTitle": "Master bath"],
                       in: context)
        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)
        #expect(ops.count == 1)
        return (store, id, ops)
    }

    /// `applied` clears the row and stamps the new version. Anything less and the same edit is
    /// pushed forever.
    @Test func appliedClearsTheOutboxRowAndStampsTheVersion() throws {
        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults(
            [op.opID: SyncFix.result(.applied, version: 5)], for: fixture.ops)

        #expect(outcome.cleared == 1)
        #expect(outcome.parked == 0)
        #expect(outcome.messages.isEmpty)
        #expect(SyncFix.outboxRow(fixture.id, in: container) == nil,
                "the applied row was not cleared and will push again")
        #expect(SyncFix.storedVersion(fixture.id, in: container) == 5)
    }

    /// `cached` is a REPLAY of a result the server already produced — not a new fact. It must
    /// behave identically to `applied`, or a push whose response was lost strands its row.
    @Test func cachedBehavesIdenticallyToApplied() throws {
        let appliedContainer = try TestStore.makeContainer()
        let appliedFixture = try queuedInvoiceEdit(appliedContainer)
        let appliedOp = try #require(appliedFixture.ops.first)
        let appliedOutcome = appliedFixture.store.applyResults(
            [appliedOp.opID: SyncFix.result(.applied, version: 5)], for: appliedFixture.ops)

        let cachedContainer = try TestStore.makeContainer()
        let cachedFixture = try queuedInvoiceEdit(cachedContainer)
        let cachedOp = try #require(cachedFixture.ops.first)
        let cachedOutcome = cachedFixture.store.applyResults(
            [cachedOp.opID: SyncFix.result(.cached, version: 5)], for: cachedFixture.ops)

        #expect(cachedOutcome.cleared == appliedOutcome.cleared)
        #expect(cachedOutcome.parked == appliedOutcome.parked)
        #expect(cachedOutcome.messages.count == appliedOutcome.messages.count)
        #expect(cachedOutcome.recentChanges.count == appliedOutcome.recentChanges.count)
        #expect(SyncFix.outboxRow(cachedFixture.id, in: cachedContainer) == nil,
                "a replayed result left the row queued — it will push forever")
        #expect(SyncFix.storedVersion(cachedFixture.id, in: cachedContainer) == 5)
        #expect(SyncFix.storedVersion(appliedFixture.id, in: appliedContainer) == 5)
    }

    /// `conflict` PARKS the value and badges the record. The one thing it must never do is
    /// discard the number the person typed — parking is what makes a side-by-side pick
    /// possible later.
    @Test func conflictParksTheValueAndBadgesRatherThanDiscarding() throws {
        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults([
            op.opID: SyncFix.result(.conflict, version: 6, conflicts: [
                GLSyncFieldConflict(field: "taxRatePercent",
                                    serverValue: .number(7), serverVersion: 6)
            ])
        ], for: fixture.ops)

        #expect(outcome.parked == 1)
        #expect(outcome.cleared == 0)

        let row = try #require(SyncFix.outboxRow(fixture.id, in: container))
        #expect(row.isParked)
        #expect(row.parkReason == "conflict")
        #expect(GLSyncValue.double(row.fields, "taxRatePercent") == 8.25,
                "the contested value was discarded instead of parked")
        #expect(GLSyncValue.string(row.fields, "jobTitle") == "Master bath",
                "the uncontested half of the patch was thrown away with the contested half")

        #expect(outcome.recentChanges.count == 1, "a conflict must badge the record")
        let change = try #require(outcome.recentChanges.first)
        #expect(change.recordID == fixture.id)
        #expect(change.recordType == "invoice")
        #expect(change.field == "taxRatePercent")
        #expect(change.serverValue == "7")
        #expect(SyncFix.isContested(change.kind),
                "a conflict was logged as \(change.kind), not .contested")
    }

    /// A whole-record conflict (delete vs. edit, a singleton that already exists) carries no
    /// field list and must still badge — a silent conflict is a lost argument.
    @Test func aConflictWithNoFieldListStillBadgesTheRecord() throws {
        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults(
            [op.opID: SyncFix.result(.conflict, version: 6)], for: fixture.ops)

        #expect(outcome.parked == 1)
        #expect(outcome.recentChanges.count == 1)
        #expect(outcome.recentChanges.first?.field == "")
        #expect(SyncFix.outboxRow(fixture.id, in: container)?.isParked == true)
    }

    /// `refused: paid_locked` surfaces the sentence GLSYNC-SPEC.md §5 specifies, verbatim, and
    /// keeps the value. The person gets a real next step — not a machine reason, not silence.
    ///
    /// The sentence names BOTH halves of the lock on purpose: the same reason now arrives for a
    /// refused CUSTOMER delete (`paidInvoiceInSubtree`), where invoice-only copy would be false.
    @Test func refusedPaidLockedSurfacesThePlainEnglishMessageAndKeepsTheValue() throws {
        // The sentence is localized now, so it resolves against the CHOSEN language. Pin it,
        // or this assertion silently becomes "whatever language the test sim happens to be in".
        // Safe to mutate the global here: the setter is MainActor-only and this body never
        // suspends, so no other test can observe the pinned value.
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en

        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults([
            op.opID: SyncFix.result(.refused, reason: .paidLocked)
        ], for: fixture.ops)

        #expect(outcome.parked == 1)
        #expect(outcome.cleared == 0)
        #expect(outcome.messages.count == 1)
        let message = try #require(outcome.messages.first)
        #expect(message.text == "A paid invoice can’t be changed or deleted, and neither can the customer it belongs to. Add a change order to correct it.")
        #expect(message.recordID == fixture.id)
        #expect(message.recordType == "invoice")

        let row = try #require(SyncFix.outboxRow(fixture.id, in: container))
        #expect(row.parkReason == "paid_locked")
        #expect(GLSyncValue.double(row.fields, "taxRatePercent") == 8.25,
                "a refusal lost the value the person typed")
        #expect(GLSyncValue.string(row.fields, "jobTitle") == "Master bath")
    }

    /// An unrecognized refusal reason keeps the refusal and falls back to generic copy. A
    /// newer Worker's reason must never surface as a blank alert or a raw snake_case token.
    @Test func anUnrecognizedRefusalStillParksAndStillSaysSomethingUseful() throws {
        // Same reason as the paid_locked test above: the fallback sentence is localized.
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en

        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults(
            [op.opID: SyncFix.result(.refused)], for: fixture.ops)

        #expect(outcome.parked == 1)
        #expect(outcome.messages.first?.text
                == "Something didn't sync. Updating the app should fix it.")
        #expect(SyncFix.outboxRow(fixture.id, in: container)?.parkReason == "refused")
    }

    /// A field this device LOST on last-writer-wins is a quiet Recent Changes entry, never a
    /// modal — and the row still clears, because the server did apply the op.
    @Test func aLostFieldIsLoggedQuietlyAndTheRowStillClears() throws {
        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults([
            op.opID: SyncFix.result(.applied, version: 7, lost: [
                GLSyncFieldLoss(field: "jobTitle", serverValue: .string("Guest bath"))
            ])
        ], for: fixture.ops)

        #expect(outcome.cleared == 1)
        #expect(outcome.messages.isEmpty, "an LWW loss must never produce a user-facing message")
        #expect(outcome.recentChanges.count == 1)
        let change = try #require(outcome.recentChanges.first)
        #expect(change.field == "jobTitle")
        #expect(change.serverValue == "Guest bath")
        #expect(SyncFix.isLostToOtherDevice(change.kind),
                "an LWW loss was logged as \(change.kind), not .lostToOtherDevice")
        #expect(SyncFix.outboxRow(fixture.id, in: container) == nil)
    }

    /// An op MISSING from the results map was not judged. Assuming success is how an unsent
    /// edit disappears: the row stays exactly as it was, with its attempt counted.
    @Test func anUnjudgedOpLeavesItsRowExactlyAsItWas() throws {
        let container = try TestStore.makeContainer()
        let fixture = try queuedInvoiceEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults([:], for: fixture.ops)

        #expect(outcome.cleared == 0)
        #expect(outcome.parked == 0)
        let row = try #require(SyncFix.outboxRow(fixture.id, in: container))
        #expect(row.opID == op.opID, "an unjudged row was re-minted")
        #expect(row.isParked == false, "an unjudged row must stay pushable")
        #expect(row.attempts == 1)
        #expect(GLSyncValue.double(row.fields, "taxRatePercent") == 8.25)
        #expect(SyncFix.storedVersion(fixture.id, in: container) == nil,
                "a version was stamped for an op the server never judged")
    }

    /// A fresh edit that lands WHILE the push is in flight re-mints the op id. Clearing the
    /// row on the old id's success would throw that edit away — the exact window in which an
    /// offline job-site save vanishes.
    @Test func anEditThatLandsMidFlightIsNotClearedByTheOldOpsSuccess() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = UUID()
        let row = SyncFix.outbox(record: id, type: "invoice", base: 4,
                                 fields: ["taxRatePercent": 8.25], in: context)
        let sentOpID = try #require(row.opID)
        let inFlight = GLSyncPendingOp(
            opID: sentOpID, recordID: id, recordType: "invoice", parentID: nil,
            baseVersion: 4, patchJSON: row.fieldsJSON, isDelete: false, cascade: [],
            clientTS: 1_787_000_000_000)

        // The person keeps working while the request is on the wire.
        row.coalesce(["taxRatePercent": 9.5], parentID: nil)
        context.saveChanges()

        let store = SyncFix.store(container)
        let outcome = store.applyResults(
            [sentOpID: SyncFix.result(.applied, version: 6)], for: [inFlight])

        #expect(outcome.cleared == 0, "the in-flight result cleared a row holding a NEWER edit")
        let saved = try #require(SyncFix.outboxRow(id, in: container))
        #expect(GLSyncValue.double(saved.fields, "taxRatePercent") == 9.5)
        #expect(SyncFix.storedVersion(id, in: container) == 6,
                "the version the server reported is still a fact worth keeping")
    }

    /// An accepted DELETE drops the version rows for the record AND its whole cascade subtree
    /// — every one of those rows is gone server-side too.
    @Test func anAcceptedDeleteDropsVersionRowsForTheWholeSubtree() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let parent = UUID()
        let child = UUID()
        SyncFix.stampVersionRow(parent, 4, in: context)
        SyncFix.stampVersionRow(child, 2, in: context)
        let row = SyncFix.outbox(record: parent, type: "invoice", base: 4,
                                 isDelete: true, in: context)
        let opID = try #require(row.opID)
        let op = GLSyncPendingOp(opID: opID, recordID: parent, recordType: "invoice",
                                 parentID: nil, baseVersion: 4, patchJSON: "{}",
                                 isDelete: true, cascade: [child], clientTS: 1_787_000_000_000)

        let store = SyncFix.store(container)
        let outcome = store.applyResults(
            [opID: SyncFix.result(.applied, version: 99)], for: [op])

        #expect(outcome.cleared == 1)
        #expect(SyncFix.storedVersion(parent, in: container) == nil)
        #expect(SyncFix.storedVersion(child, in: container) == nil,
                "a cascaded row kept a version for a record that no longer exists")
    }
}

// MARK: - 7. Bootstrap (GLSYNC-SPEC.md §5)

@MainActor
struct GLSyncBootstrapTests {

    /// A store built for the first time has not bootstrapped, and its device id is minted
    /// once. The server breaks LWW ties on that id, so a device that re-minted it every
    /// launch would be a different loser each time.
    @Test func aVirginStoreHasNotBootstrappedAndMintsOneStableDeviceID() throws {
        let container = try TestStore.makeContainer()

        let first = SyncFix.store(container)
        let initial = first.persistedState()
        #expect(initial.bootstrapComplete == false)
        #expect(initial.cursor == 0)
        #expect(initial.historyToken == nil)

        let second = SyncFix.store(container)
        #expect(second.persistedState().deviceID == initial.deviceID,
                "the device id changed across a cold start — every LWW tie now breaks differently")
        #expect((try? SyncFix.reader(container).fetchCount(FetchDescriptor<GLSyncState>())) == 1,
                "a second sync-state row makes the cursor non-deterministic")
    }

    /// THE MIGRATION: the device's store is already a complete replica, so the first run
    /// enqueues every local record as a create, PARENT BEFORE CHILD. A child that lands first
    /// is refused `bad_parent` and parks a row that was never wrong.
    @Test func theFirstRunEnqueuesEveryLocalRecordParentBeforeChild() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let customer = Customer(firstName: "Bootstrap", lastName: "Owner")
        let invoice = TS.invoice(number: "INV-0300", lines: [(400, false)])
        invoice.customer = customer
        context.insert(customer)
        context.insert(invoice)
        SyncFix.seed(context)

        let store = SyncFix.store(container)
        #expect(store.persistedState().bootstrapComplete == false,
                "the first run is defined by this flag being false")
        let enqueued = store.enqueueEverything(pulled: [:])
        #expect(enqueued == 4, "expected customer + invoice + group + line item, got \(enqueued)")

        let ops = store.pendingOps(limit: 100)
        #expect(ops.count == 4)
        #expect(ops.allSatisfy { $0.baseVersion == 0 }, "a bootstrap op must be a create")
        #expect(ops.allSatisfy { !$0.isDelete })

        let order = ops.map(\.recordType)
        let depths = order.map { GLSyncRegistry.depth(of: $0) }
        #expect(depths == depths.sorted(),
                "bootstrap order is not parent-before-child: \(order)")
        let customerIndex = try #require(order.firstIndex(of: "customer"))
        let invoiceIndex = try #require(order.firstIndex(of: "invoice"))
        let groupIndex = try #require(order.firstIndex(of: "invoice_group"))
        let lineIndex = try #require(order.firstIndex(of: "invoice_line_item"))
        #expect(customerIndex < invoiceIndex)
        #expect(invoiceIndex < groupIndex)
        #expect(groupIndex < lineIndex)
    }

    /// Pulled records reconcile as a PER-FIELD DIFF at the pulled version (root fix
    /// 2026-08-30 night). Three truths, each with its own assertion here:
    /// - a pulled row whose local copy DIFFERS pushes ONLY the differing fields — the
    ///   rebaseline-orphan case (an edit whose history died un-folded) still reaches
    ///   the wire;
    /// - a pulled row that is byte-identical enqueues NOTHING — the full-payload echo
    ///   was the clobber half of the name bug (a fresh install pushed its just-pulled
    ///   blank profile straight back over the server copy, v-bumping it forever);
    /// - an un-pulled row is still a create at version 0.
    @Test func recordsAlreadyPulledReconcileAsFieldDiffs() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(3, in: context, prefix: "Snap")
        // The pull's write-through version cache, as the real pull records it.
        context.insert(GLSyncRecordVersion(recordID: ids[0], version: 7))
        context.insert(GLSyncRecordVersion(recordID: ids[1], version: 9))
        try context.save()

        let store = SyncFix.store(container)
        // Server payloads as the pull delivered them: ids[0]'s server copy is MISSING the
        // local first name (the orphaned-edit case); ids[1]'s matches its local row
        // byte-for-byte (the fresh-install echo case).
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        let locals = Dictionary(uniqueKeysWithValues: entry.fetchAll(context).map { ($0.glSyncID!, $0.glSyncPayload()) })
        var stale = locals[ids[0]]!
        stale["firstName"] = ""                       // the server never got the name
        let pulled: [UUID: [String: Any]] = [ids[0]: stale, ids[1]: locals[ids[1]]!]

        let enqueued = store.enqueueEverything(pulled: pulled)

        #expect(enqueued == 2, "differing pulled row + un-pulled create; the identical row must be skipped")
        let ops = store.pendingOps(limit: 50)
        let byID = Dictionary(uniqueKeysWithValues: ops.map { ($0.recordID, $0) })
        #expect(byID[ids[0]]?.baseVersion == 7, "a differing pulled row is an UPDATE at its pulled version")
        #expect(byID[ids[0]]?.patchJSON.contains("firstName") == true,
                "the orphaned local edit must be in the patch")
        #expect(byID[ids[0]]?.patchJSON.contains("lastName") == false,
                "fields the server already holds must NOT be echoed")
        #expect(byID[ids[1]] == nil, "a byte-identical pulled row enqueues nothing — no echo, ever")
        #expect(byID[ids[2]]?.baseVersion == 0, "an un-pulled row is still a create")
    }

    /// ROOT FIX (2026-08-30 night) regression net, half one: after
    /// `establishHistoryBaseline`, the persisted watermark is NON-NIL — the old nil-token
    /// regime purged all history before reading it on EVERY cycle and could never leave
    /// nil, which is why no field edit ever reached the outbox.
    @Test func establishHistoryBaselineMovesTheWatermarkOffNil() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        #expect(store.persistedState().historyToken == nil, "a fresh store starts nil")
        store.establishHistoryBaseline()
        let state = store.persistedState()
        #expect(state.historyToken != nil, "the baseline must move the watermark off nil")
        #expect(state.historyFingerprint == GLSyncHistory.schemaFingerprint,
                "the token and the shape it was written under are ONE fact")
        // Idempotent: a second call must not move an established watermark.
        let first = state.historyToken
        store.establishHistoryBaseline()
        #expect(store.persistedState().historyToken == first)
    }

    /// Half two: an edit made AFTER the baseline folds into the outbox with its changed
    /// field — the end-to-end mechanism the name bug proved missing (history destroyed
    /// unread, nothing enqueued).
    @Test func anEditAfterTheBaselineFoldsIntoTheOutbox() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(1, in: context, prefix: "Fold")
        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let token = store.persistedState().historyToken

        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        let customer = try #require(entry.fetchAll(context).first { $0.glSyncID == ids[0] } as? Customer)
        customer.firstName = "Adrian"
        try context.save()

        let result = try store.fold(since: token, writtenUnder: GLSyncHistory.schemaFingerprint)
        #expect(result.enqueued == 1, "the edit must fold into exactly one outbox row")
        let ops = store.pendingOps(limit: 10)
        #expect(ops.first?.recordID == ids[0])
        #expect(ops.first?.patchJSON.contains("Adrian") == true,
                "the edited value must be in the pushed patch")
        #expect(result.newHistoryToken != nil, "the watermark must advance past the edit")
    }

    /// The fingerprint gate regression (root fix half three): a valid token presented
    /// WITHOUT its fingerprint used to throw .schemaChanged on every cycle — dropping the
    /// watermark, re-bootstrapping, and landing back in the nil regime. With the
    /// fingerprint plumbed through, the same fold succeeds.
    @Test func foldPassesTheFingerprintSoAValidTokenSurvives() throws {
        let container = try TestStore.makeContainer()
        _ = SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Fp")
        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let token = store.persistedState().historyToken
        #expect(throws: Never.self) {
            _ = try store.fold(since: token, writtenUnder: GLSyncHistory.schemaFingerprint)
        }
        #expect(throws: GLSyncHistoryError.self) {
            _ = try store.fold(since: token, writtenUnder: nil)
        }
    }

    /// The migration must be safe to re-run: a second pass over a queue that already holds a
    /// record adds nothing, so a crash mid-bootstrap does not double every op.
    @Test func aSecondBootstrapPassEnqueuesNothing() throws {
        let container = try TestStore.makeContainer()
        SyncFix.customers(3, in: SyncFix.reader(container), prefix: "Twice")

        let store = SyncFix.store(container)
        #expect(store.enqueueEverything(pulled: [:]) == 3)
        #expect(store.enqueueEverything(pulled: [:]) == 0,
                "re-running the migration duplicated the queue")
        #expect(SyncFix.outboxRows(container).count == 3)
    }

    /// A record with no `syncID` has no identity the server can key on, so it waits for the
    /// next cycle rather than going up under an invented one.
    @Test func aRecordWithoutASyncIDIsNotEnqueued() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let named = Customer(firstName: "Has", lastName: "Id")
        let namedID = UUID()
        named.syncID = namedID
        let nameless = Customer(firstName: "No", lastName: "Id")
        context.insert(named)
        context.insert(nameless)
        try context.save()          // bare save: nothing mints an id, like a pre-sync build
        nameless.syncID = nil
        try context.save()

        let store = SyncFix.store(container)
        #expect(store.enqueueEverything(pulled: [:]) == 1)
        #expect(store.pendingOps(limit: 50).map(\.recordID) == [namedID])
    }

    /// Completing the bootstrap flips the flag and MAX-merges the cursor. A cursor that went
    /// backwards would re-pull a window; one that went forwards would skip one.
    @Test func markingBootstrapCompleteNeverLowersTheCursor() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        store.markBootstrapComplete(cursor: 42)
        var state = store.persistedState()
        #expect(state.bootstrapComplete)
        #expect(state.cursor == 42)

        store.markBootstrapComplete(cursor: 10)
        state = store.persistedState()
        #expect(state.cursor == 42, "a later bootstrap dragged the cursor backwards")
    }

    /// Checksum drift, a seq gap, and an untrustworthy history bookmark are three different
    /// reasons to start over, and each clears exactly its own piece of state.
    @Test func rebootstrapRequestsClearTheRightStateAndNothingElse() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        store.advance(cursor: 77, historyToken: Data([9, 9, 9]))
        store.markBootstrapComplete(cursor: 77)
        let deviceID = store.persistedState().deviceID

        store.requestRebootstrap()
        var state = store.persistedState()
        #expect(state.bootstrapComplete == false)
        #expect(state.cursor == 77, "checksum drift must not throw away the pull cursor")
        #expect(state.historyToken == Data([9, 9, 9]))

        store.resetCursorForFullResync()
        state = store.persistedState()
        #expect(state.cursor == 0, "a seq gap must reset the cursor")
        #expect(state.bootstrapComplete == false)

        store.dropHistoryTokenAndRebootstrap()
        state = store.persistedState()
        #expect(state.historyToken == nil, "an untrustworthy bookmark must be dropped")
        #expect(state.bootstrapComplete == false)
        #expect(state.deviceID == deviceID, "starting over must not change this device's identity")
    }
}

// MARK: - 8. Signed out (GLSYNC-SPEC.md §4)

@MainActor
struct GLSyncSignedOutTests {

    /// Signed out is a STATE, not a failure. The engine stops claiming to be backed up and
    /// nothing else changes — no nag, no block, nothing lost.
    @Test func signingOutMovesTheEngineToTheSignedOutStateAndTouchesNothingLocal() async throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(3, in: context, prefix: "Local")
        let queued = try #require(ids.first)
        SyncFix.outbox(record: queued, type: "customer",
                       fields: ["firstName": "Unsent while signed out"], in: context)

        let engine = GLSyncEngine(container: container)
        let initial = await engine.state
        #expect(initial == .idle, "a freshly built engine is idle, not syncing")

        await engine.signedOut()
        let state = await engine.state
        #expect(state == .signedOut)

        // Fully usable, local-only: every record still here, the queue intact, and nothing
        // stamped as backed up.
        #expect(SyncFix.customerCount(container) == 3)
        let rows = SyncFix.outboxRows(container)
        #expect(rows.count == 1, "signing out discarded queued work")
        #expect(GLSyncValue.string(rows[0].fields, "firstName") == "Unsent while signed out")
        let states = (try? SyncFix.reader(container).fetch(FetchDescriptor<GLSyncState>())) ?? []
        #expect(states.allSatisfy { $0.lastSyncAt == nil },
                "a signed-out engine claimed a backup that never happened")

        await engine.stop()
    }

    /// Building an engine must not mutate the store. It is constructed during launch, before
    /// anyone knows whether there is a session at all.
    @Test func buildingAnEngineWritesNothingToTheStore() async throws {
        let container = try TestStore.makeContainer()
        SyncFix.customers(2, in: SyncFix.reader(container), prefix: "Untouched")

        let engine = GLSyncEngine(container: container)
        let state = await engine.state
        #expect(state == .idle)

        let reader = SyncFix.reader(container)
        #expect((try? reader.fetchCount(FetchDescriptor<GLSyncState>())) == 0,
                "the engine wrote sync state before it knew whether it could sync")
        #expect((try? reader.fetchCount(FetchDescriptor<GLSyncOutboxEntry>())) == 0)
        #expect(SyncFix.customerCount(container) == 2)

        await engine.stop()
    }

    /// The transport's own vocabulary agrees with the state machine: signing out and backing
    /// off are silent, and every failure a person could see carries a next step.
    @Test func signedOutAndRateLimitedAreSilentWhileRealFailuresSpeakPlainly() {
        // The sentences are catalog keys now, so pin the language — otherwise this asserts
        // against whatever the test sim's device language happens to be.
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en

        #expect(GLSyncTransportError.signedOut.userMessage == nil,
                "signed out is a state, not something to tell the user off about")
        #expect(GLSyncTransportError.rateLimited(retryAfter: 30).userMessage == nil,
                "a backoff must never surface as a banner")
        #expect(GLSyncTransportError.documentKeyUnavailable.userMessage == nil)
        #expect(GLSyncTransportError.offline.userMessage
                == "You're offline. Your work is saved here and will sync when you reconnect.")
        #expect(GLSyncTransportError.unauthorized.userMessage == "Sign in again to keep syncing.")
        #expect(GLSyncTransportError.signedOut.isTransient == false)
        #expect(GLSyncTransportError.offline.isTransient)
        #expect(GLSyncTransportError.badRequest.isTransient == false,
                "a client bug retried forever only burns the rate bucket")
    }

    /// The Worker's `subscription_lapsed` is PERMANENT until the person acts, and the client
    /// has to read it off the ENVELOPE — 403 alone falls through to `.server`, which is
    /// transient.
    ///
    /// This is the bug this test stands against, and it was live: an attachment upload
    /// refused for a lapsed subscription came back 403 `{"error":"subscription_lapsed"}`,
    /// matched nothing in the `code` switch, was classified transient — and so was retried on
    /// every cycle forever AND thrown out of `uploadBlobs`, which aborted the whole push. Ops
    /// that had never touched an attachment stopped syncing because one document could not.
    @Test func aLapsedSubscriptionRefusalIsPermanentAndReadFromTheEnvelope() {
        let body = Data(#"{"error":"subscription_lapsed"}"#.utf8)
        let mapped = GLSyncTransport.error(status: 403, retryAfter: nil, body: body)

        guard case .subscriptionLapsed = mapped else {
            Issue.record("403 subscription_lapsed mapped to \(mapped), not .subscriptionLapsed")
            return
        }
        #expect(mapped.isTransient == false,
                "retrying a refusal only a reactivation can answer burns the rate bucket forever")

        // The status alone must NOT be what decides it: the Worker uses 403 for one thing
        // today, and a second 403 without this word would be a `.server` — retryable — rather
        // than silently inheriting the lapsed handling.
        let bare = GLSyncTransport.error(status: 403, retryAfter: nil, body: Data("{}".utf8))
        if case .subscriptionLapsed = bare {
            Issue.record("a bare 403 was read as a subscription refusal on the status alone")
        }
    }

    /// One machine word, one sentence. The Worker answers `subscription_lapsed` on two
    /// channels — the per-op `/sync` refusal reason and the `{error:…}` envelope of
    /// `/attachments` and `/account/export` — and the person must read the same words either
    /// way. Asserted as identity, not as two equal literals: two copies drift, and only one
    /// of them would be in the catalog.
    @Test func theLapsedSentenceIsTheSameOnBothChannels() {
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }

        for language in [MBAppLanguage.en, .es] {
            MBLocalization.shared.language = language
            #expect(GLSyncTransportError.subscriptionLapsed.userMessage
                    == GLSyncRefusalReason.subscriptionLapsed.userMessage,
                    "the two channels disagree in \(language)")
        }

        MBLocalization.shared.language = .en
        let english = GLSyncRefusalReason.subscriptionLapsed.userMessage
        // It has to name the cause, reassure that nothing is lost, and give the ONE action
        // that changes the answer — and it must NOT be the "update the app" advice the
        // missing case used to fall back to, which sends the person to the App Store instead
        // of to their subscription.
        #expect(english.contains("subscription"))
        #expect(english.contains("reactivate"), "the sentence names no next step")
        #expect(!english.contains("Updating the app"))
    }

    /// Every refusal sentence is really TRANSLATED, not merely routed through the catalog.
    ///
    /// The bug this stands against shipped once already: the nine sentences were plain Swift
    /// literals, so they were never extracted and a Spanish reader got English no matter what
    /// the in-app language switch said. Routing them through `MBLocalization` fixes that only
    /// if the Spanish values actually exist — a missing key falls back to the English source
    /// SILENTLY, which looks exactly like working code. So the assertion is Spanish ≠ English,
    /// over `allCases`: a reason added later without a translation fails here.
    @Test func everyRefusalReasonSpeaksSpanishInSpanish() {
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }

        MBLocalization.shared.language = .en
        let english = Dictionary(uniqueKeysWithValues:
            GLSyncRefusalReason.allCases.map { ($0, $0.userMessage) })

        MBLocalization.shared.language = .es
        for reason in GLSyncRefusalReason.allCases {
            let spanish = reason.userMessage
            #expect(!spanish.isEmpty, "\(reason.rawValue) has no sentence at all")
            #expect(spanish != english[reason],
                    "\(reason.rawValue) falls back to English — its es value is missing from Localizable.xcstrings")
        }
    }
}

// MARK: - Cursor / token bookkeeping (GLSYNC-SPEC.md §5.5)

@MainActor
struct GLSyncAdvanceBookkeepingTests {

    /// The cursor and the history token move TOGETHER, in one save, only after the round trip
    /// lands. Advancing one without the other loses a window of edits or replays one forever.
    @Test func cursorAndHistoryTokenAdvanceTogetherAndSurviveARelaunch() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        store.advance(cursor: 120, historyToken: Data([1, 2, 3]))

        let cold = SyncFix.store(container).persistedState()
        #expect(cold.cursor == 120)
        #expect(cold.historyToken == Data([1, 2, 3]))
    }

    /// A nil token means "history had nothing new — KEEP the one you have". Writing nil would
    /// re-fold the entire history next cycle.
    @Test func advancingWithNoNewTokenKeepsTheExistingBookmark() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        store.advance(cursor: 120, historyToken: Data([1, 2, 3]))

        store.advance(cursor: 200, historyToken: nil)

        let state = store.persistedState()
        #expect(state.cursor == 200)
        #expect(state.historyToken == Data([1, 2, 3]),
                "a cycle with no new history wiped the bookmark and will now re-fold everything")
    }

    /// Extra state rows are a bug elsewhere (two engines, a restored backup). One row wins and
    /// the rest are deleted rather than left to make the cursor non-deterministic.
    @Test func extraSyncStateRowsAreCollapsedToOne() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        context.insert(GLSyncState())
        context.insert(GLSyncState())
        context.insert(GLSyncState())
        try context.save()

        let store = SyncFix.store(container)
        let first = store.persistedState()

        #expect((try? SyncFix.reader(container).fetchCount(FetchDescriptor<GLSyncState>())) == 1,
                "duplicate sync-state rows survived — the cursor is now whichever is read first")
        #expect(SyncFix.store(container).persistedState().deviceID == first.deviceID,
                "the surviving row must be the one every later read finds")
    }

    /// `stampSynced` is the "backed up" claim the UI reads. It has to actually persist.
    @Test func stampingASyncPersistsTheTimestamp() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)
        #expect(store.persistedState().lastSyncAt == nil)

        store.stampSynced()

        let cold = SyncFix.store(container).persistedState()
        let stamped = try #require(cold.lastSyncAt)
        #expect(abs(stamped.timeIntervalSinceNow) < 60)
    }

    /// The checksum clock is separate from the sync clock: a self-heal that re-stamped
    /// `lastSyncAt` would claim a backup, and one that never stamped its own would re-run
    /// every cycle.
    @Test func theChecksumClockIsSeparateFromTheSyncClock() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        store.stampChecksumChecked()

        let cold = SyncFix.store(container).persistedState()
        #expect(cold.lastChecksumAt != nil)
        #expect(cold.lastSyncAt == nil, "a checksum check claimed a backup it did not perform")
    }
}

// MARK: - 9. Edits still only in history (QA 2026-10-03 F16)
//
// A user edit reaches the outbox only when a fold reads it out of history. Until then the
// outbox does not know about it, so a pull that judged "dirty" from the outbox alone
// overwrote it: the server's echo of this device's OWN earlier write reverted the newer
// value, and the next fold then pushed the reverted value to every device. These tests run
// the store calls in the order the engine makes them (the engine itself has no injection
// point for a transport — see the file header).

@MainActor
struct GLSyncUnfoldedEditTests {

    private static func customer(_ id: UUID, in context: ModelContext) throws -> Customer {
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        return try #require(entry.fetchAll(context).first { $0.glSyncID == id } as? Customer)
    }

    private static func patch(_ op: GLSyncPendingOp) -> GLSyncPayload {
        (op.patchJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? GLSyncPayload) ?? [:]
    }

    /// The weak-signal case. Edit one is folded and on the wire; edit two is saved while the
    /// request is still out. The reply clears edit one's op and the pull echoes edit one's
    /// row back. Edit two must survive that echo AND be what the next push carries.
    @Test func anEditSavedBetweenPendingOpsAndApplyChangesSurvivesAndIsPushed() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(2, in: context, prefix: "Echo")
        let edited = ids[0]
        let clean = ids[1]
        SyncFix.stampVersionRow(edited, 1, in: context)
        SyncFix.stampVersionRow(clean, 1, in: context)

        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let baseline = store.persistedState()

        // Edit one: folded, then handed to the wire.
        let customer = try Self.customer(edited, in: context)
        customer.firstName = "Sixty"
        try context.save()
        let firstFold = try store.fold(since: baseline.historyToken,
                                       writtenUnder: baseline.historyFingerprint)
        #expect(firstFold.enqueued == 1, "precondition: edit one must be in the outbox")
        let sent = try #require(store.pendingOps(limit: 50).first { $0.recordID == edited })
        let echo = customer.glSyncPayload()   // the server echoes this device's own write

        // Edit two lands while that request is in flight.
        customer.firstName = "SeventyFive"
        try context.save()

        // The reply: edit one applied at v2, and the pull carries its echo plus another
        // device's change to a clean record.
        let cleanCustomer = try Self.customer(clean, in: context)
        var otherDevice = cleanCustomer.glSyncPayload()
        otherDevice["firstName"] = "FromElsewhere"
        _ = store.applyResults([sent.opID: SyncFix.result(.applied, version: 2)], for: [sent])
        let verdict = store.applyChanges([
            SyncFix.liveRow(edited, type: "customer", version: 2, seq: 20, payload: echo),
            SyncFix.liveRow(clean, type: "customer", version: 2, seq: 21, payload: otherDevice)
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.skipped == 1, "the record with an unfolded edit must be skipped")
        #expect(outcome.applied == 1, "a clean record must still take the pulled row")
        #expect(SyncFix.loadCustomer(edited, in: container)?.firstName == "SeventyFive",
                "the echo of edit one overwrote edit two — the person's newest value is gone")
        #expect(SyncFix.loadCustomer(clean, in: container)?.firstName == "FromElsewhere",
                "the guard skipped a record nobody edited here")

        // The next fold carries edit two, never the reverted value.
        let nextFold = try store.fold(since: firstFold.newHistoryToken ?? baseline.historyToken,
                                      writtenUnder: GLSyncHistory.schemaFingerprint)
        #expect(nextFold.enqueued >= 1)
        let resend = try #require(store.pendingOps(limit: 50).first { $0.recordID == edited },
                                  "edit two never reached the outbox")
        #expect(GLSyncValue.string(Self.patch(resend), "firstName") == "SeventyFive",
                "the next push carries the reverted value and spreads it to every device")
    }

    /// The re-bootstrap case (checksum drift re-arms bootstrap). An edit still only in history
    /// meets a snapshot page carrying the server's older copy. The page must not overwrite it,
    /// so the bootstrap's field diff still finds it and queues it.
    @Test func aBootstrapPageDoesNotOverwriteAnEditStillOnlyInHistory() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = try #require(SyncFix.customers(1, in: context, prefix: "Drift").first)
        SyncFix.stampVersionRow(id, 3, in: context)
        let customer = try Self.customer(id, in: context)
        let server = customer.glSyncPayload()   // what the server already holds

        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        store.markBootstrapComplete(cursor: 30)

        // The edit is saved; no fold has read it yet.
        customer.firstName = "Unfolded"
        try context.save()

        store.requestRebootstrap()
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "customer", version: 3, seq: 30, payload: server)
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.skipped == 1)
        #expect(SyncFix.loadCustomer(id, in: container)?.firstName == "Unfolded",
                "a snapshot page overwrote an edit no fold had read yet")

        #expect(store.enqueueEverything(pulled: [id: server]) == 1,
                "the bootstrap diff found nothing to send — the edit is lost on every device")
        let op = try #require(store.pendingOps(limit: 50).first { $0.recordID == id })
        #expect(GLSyncValue.string(Self.patch(op), "firstName") == "Unfolded")
        #expect(op.baseVersion == 3, "a reconciling update goes at the pulled version")
    }
}


// MARK: - A cycle belongs to the account that started it (QA 2026-10-03 F18)

/// Answers every request from the test's handler; nothing reaches the network.
private final class CycleOwnerStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Every request the stub server saw: its path and the credential it carried.
nonisolated final class CycleOwnerRequestLog: @unchecked Sendable {
    nonisolated struct Entry: Sendable {
        let path: String
        let authorization: String
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Person A signs out while a cycle of theirs is still running, and person B signs in on the
/// same phone. Whatever the old cycle still had to send must never go out under B: B's
/// account would keep A's customers forever, and A's W-9 would be sealed with B's key.
@MainActor
@Suite(.serialized)
struct GLSyncCycleOwnerTests {

    /// A JWT-shaped string whose payload carries `sub` (the provider reads it unverified).
    nonisolated private static func jwt(sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    // Stytch session subjects and the Gold Life IDs the mint answers for them: two different
    // namespaces, exactly as in production.
    nonisolated private static let sessionA = jwt(sub: "stytch-session-a")
    nonisolated private static let sessionB = jwt(sub: "stytch-session-b")
    nonisolated private static let appTokenA = jwt(sub: "glid-a")
    nonisolated private static let appTokenB = jwt(sub: "glid-b")

    nonisolated private static func bearer(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "Authorization") ?? ""
    }

    /// The identity Worker's mint and gl-business-api's endpoints, answered in memory. The
    /// mint answers for whichever session sent it, as the real one does. `onSnapshot` runs
    /// while the first bootstrap page is on the wire: the moment the old cycle is mid-flight.
    nonisolated private static func server(log: CycleOwnerRequestLog,
                               onSnapshot: @escaping @Sendable () -> Void) -> (URLRequest) -> (Int, String) {
        return { request in
            let path = request.url?.path ?? ""
            let auth = bearer(request)
            log.append(.init(path: path, authorization: auth))
            if path.hasSuffix("auth/app-token") {
                let token = auth.contains(sessionB) ? appTokenB : appTokenA
                return (200, #"{"token":"\#(token)","expires_in":900}"#)
            }
            if path.hasSuffix("/snapshot") {
                onSnapshot()
                return (200, #"{"records":[]}"#)
            }
            if path.hasSuffix("/sync") {
                return (200, #"{"results":{},"changes":[],"new_cursor":1}"#)
            }
            if path.hasSuffix("/checksums") {
                return (200, #"{"types":{},"tombstones":0}"#)
            }
            return (404, #"{"error":"not_found"}"#)
        }
    }

    private static func engine(_ container: ModelContainer) -> GLSyncEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CycleOwnerStubProtocol.self]
        let cloud = GLCloudTransport(session: URLSession(configuration: config),
                                     sessionEngine: GLSessionEngine())
        let session: @Sendable () -> String? = { GLSessionEngine.mockJwt }
        return GLSyncEngine(
            container: container,
            tokens: GLSyncTokenProvider(transport: cloud, storedSessionJWT: session,
                                        onSessionExpired: {}),
            cloud: cloud,
            documents: GLSyncDocumentCrypto(transport: cloud, storedSessionJWT: session,
                                            onSessionExpired: {}))
    }

    private static func reset() {
        CycleOwnerStubProtocol.handler = nil
        GLSessionEngine.mockJwt = nil
    }

    /// The defect (F18): the cycle bound its owner once, then re-minted a token for WHATEVER
    /// session was live on every request. A switches to B while the first page is on the
    /// wire; the old cycle then minted for B and pushed A's three customers into B's account.
    @Test func aCycleThatOutlivesItsSessionSendsNothingUnderTheNextPerson() async throws {
        defer { Self.reset() }
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(3, in: SyncFix.reader(container), prefix: "PersonA")

        let log = CycleOwnerRequestLog()
        GLSessionEngine.mockJwt = Self.sessionA
        CycleOwnerStubProtocol.handler = Self.server(log: log) {
            // A signs out and B signs in on this phone, mid-cycle.
            GLSessionEngine.mockJwt = Self.sessionB
        }

        let engine = Self.engine(container)
        await engine.sync(trigger: .manual)

        let entries = log.all
        #expect(entries.contains { $0.path.hasSuffix("/snapshot") },
                "precondition: the cycle must have started under A")
        let underB = entries.filter {
            $0.authorization.contains(Self.sessionB) || $0.authorization.contains(Self.appTokenB)
        }
        #expect(underB.isEmpty, """
            the old cycle sent \(underB.map(\.path)) under the NEXT person's session — it minted \
            a token for B and kept going
            """)
        #expect(!entries.contains { $0.path.hasSuffix("/sync") }, """
            A's \(ids.count) customers were pushed after A's session ended — under B's token \
            they land in B's account
            """)
        let state = await engine.state
        #expect(state == .signedOut, "a cycle stopped by a change of person is signed out, not failed")
        await engine.stop()
    }

    /// Signing out ends the running cycle there and then. Before, `signedOut()` only dropped
    /// the caches and the cycle carried on to push; now it is cancelled between rounds.
    @Test func signingOutCancelsTheRunningCycleBeforeItsPush() async throws {
        defer { Self.reset() }
        let container = try TestStore.makeContainer()
        SyncFix.customers(2, in: SyncFix.reader(container), prefix: "Leaving")

        let log = CycleOwnerRequestLog()
        GLSessionEngine.mockJwt = Self.sessionA
        let holder = EngineHolder()
        CycleOwnerStubProtocol.handler = Self.server(log: log) {
            // The person taps Sign Out while the first page is still downloading.
            guard let engine = holder.engine else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await engine.signedOut()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
        }

        let engine = Self.engine(container)
        holder.engine = engine
        await engine.sync(trigger: .manual)

        #expect(log.all.contains { $0.path.hasSuffix("/snapshot") },
                "precondition: the cycle must have been running when the person signed out")
        #expect(!log.all.contains { $0.path.hasSuffix("/sync") },
                "the cycle kept going after sign-out and pushed")
        let state = await engine.state
        #expect(state == .signedOut,
                "the cancelled cycle's last error overwrote the signed-out state")
        await engine.stop()
    }

    /// The provider half: a call bound to a cycle's session never mints for another one. B is
    /// live, the cycle was A's, so the answer is "signed out" and nothing goes on the wire.
    @Test func aBoundTokenRequestNeverMintsForANewSession() async throws {
        defer { Self.reset() }
        let log = CycleOwnerRequestLog()
        CycleOwnerStubProtocol.handler = Self.server(log: log) {}
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CycleOwnerStubProtocol.self]
        let cloud = GLCloudTransport(session: URLSession(configuration: config),
                                     sessionEngine: GLSessionEngine())
        let tokens = GLSyncTokenProvider(transport: cloud,
                                         storedSessionJWT: { GLSessionEngine.mockJwt },
                                         onSessionExpired: {})

        GLSessionEngine.mockJwt = Self.sessionA
        let binding = try #require(try await tokens.cycleBinding())
        #expect(binding.owner == "glid-a")
        #expect(log.all.count == 1, "one mint for A")

        GLSessionEngine.mockJwt = Self.sessionB
        let answer = try await tokens.token(boundTo: binding)
        #expect(answer == .signedOut)
        #expect(log.all.count == 1, "a token was minted for B in the middle of A's cycle")

        // The bound TRANSPORT refuses too, before a byte leaves the device.
        let transport = GLSyncTransport(tokens: tokens, cloud: cloud).bound(to: binding)
        await #expect(throws: GLSyncTransportError.signedOut) {
            _ = try await transport.checksums()
        }
        #expect(log.all.count == 1, "the bound transport sent a request under B")

        // Unbound callers (the Stripe client, account deletion) keep following the live session.
        let unbound = try await tokens.token()
        #expect(unbound == .token(Self.appTokenB, subject: "glid-b"))
    }
}

/// Lets the stub server reach the engine the test built after the handler was installed.
nonisolated final class EngineHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GLSyncEngine?
    var engine: GLSyncEngine? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - Sync refusals: lapsed edits are never stranded (QA 2026-10-03 C22: F17, F57, F88)

/// The Worker refuses a lapsed account's writes and deliberately does not cache the refusal:
/// "the client retries the very same op_ids" once the person renews (gl-business-api README,
/// "Neither refusal is cached"). These tests hold the client to that half of the contract.
@MainActor
struct GLSyncLapsedRefusalTests {

    private func queuedCustomerEdit(_ container: ModelContainer)
    -> (store: GLSyncLocalStore, id: UUID, ops: [GLSyncPendingOp]) {
        let id = UUID()
        SyncFix.outbox(record: id, type: "customer", base: 3,
                       fields: ["firstName": "Edited after renewing"], in: SyncFix.reader(container))
        let store = SyncFix.store(container)
        return (store, id, store.pendingOps(limit: 50))
    }

    /// F17. A lapsed refusal is not a verdict on the record, so it must not park it: parked rows
    /// never push again, and the edit stayed on this phone after the person renewed.
    @Test func aLapsedRefusalThenARenewalPushesTheSameOp() throws {
        let container = try TestStore.makeContainer()
        let fixture = queuedCustomerEdit(container)
        let op = try #require(fixture.ops.first)

        let refused = fixture.store.applyResults(
            [op.opID: SyncFix.result(.refused, reason: .subscriptionLapsed)], for: fixture.ops)
        #expect(refused.parked == 0, "a lapsed refusal parked the row — it would never push again")
        #expect(refused.messages.count == 1, "the person must be told once why it did not back up")
        let held = try #require(SyncFix.outboxRow(fixture.id, in: container))
        #expect(!held.isParked)
        #expect(GLSyncValue.string(held.fields, "firstName") == "Edited after renewing")

        // Renewed: the next cycle offers the SAME op id (the Worker never cached the refusal).
        let retry = fixture.store.pendingOps(limit: 50)
        #expect(retry.map(\.opID) == [op.opID], """
            the held edit was not offered again with its own op id — after renewing it stays on \
            this phone forever
            """)
        let applied = fixture.store.applyResults(
            [op.opID: SyncFix.result(.applied, version: 4)], for: retry)
        #expect(applied.cleared == 1)
        #expect(SyncFix.outboxRow(fixture.id, in: container) == nil)
    }

    /// Still lapsed: the retry is refused again, and the person is not told a second time.
    @Test func aRepeatedLapsedRefusalIsReportedOnce() throws {
        let container = try TestStore.makeContainer()
        let fixture = queuedCustomerEdit(container)
        let op = try #require(fixture.ops.first)
        let verdict = [op.opID: SyncFix.result(.refused, reason: .subscriptionLapsed)]

        _ = fixture.store.applyResults(verdict, for: fixture.ops)
        let again = fixture.store.applyResults(verdict, for: fixture.store.pendingOps(limit: 50))

        #expect(again.messages.isEmpty, "the same lapse was announced on every cycle")
        #expect(again.parked == 0)
        #expect(SyncFix.outboxRow(fixture.id, in: container)?.isParked == false)
    }

    /// Every other refusal is still a verdict on the record and still parks.
    @Test func otherRefusalsStillPark() throws {
        let container = try TestStore.makeContainer()
        let fixture = queuedCustomerEdit(container)
        let op = try #require(fixture.ops.first)

        let outcome = fixture.store.applyResults(
            [op.opID: SyncFix.result(.refused, reason: .paidLocked)], for: fixture.ops)

        #expect(outcome.parked == 1)
        #expect(SyncFix.outboxRow(fixture.id, in: container)?.parkReason == "paid_locked")
    }
}

/// Edits parked by older builds, held ops inside one cycle, conflicts, and the "backed up" stamp.
@MainActor
struct GLSyncRefusalBookkeepingTests {

    /// 3.2.0 parked every refusal, the lapse included, so its edits never pushed again. This
    /// build releases them with their op ids intact (the Worker never cached the refusal).
    @Test func anEditParkedForALapseByAnOlderBuildIsReleasedWithItsOpID() throws {
        let container = try TestStore.makeContainer()
        let id = UUID()
        let row = SyncFix.outbox(record: id, type: "customer", base: 2,
                                 fields: ["firstName": "Stranded"], in: SyncFix.reader(container))
        let opID = try #require(row.opID)
        row.park("subscription_lapsed")
        row.modelContext?.saveChanges()
        let store = SyncFix.store(container)
        #expect(store.pendingOps(limit: 50).isEmpty, "precondition: a parked row does not push")

        #expect(store.releaseLapseParks() == 1)

        #expect(store.pendingOps(limit: 50).map(\.opID) == [opID])
        #expect(SyncFix.outboxRow(id, in: container)?.isHeld == true)
    }

    /// Only the lapse is released: every other park is still the server's settled answer.
    @Test func otherParksAreNotReleased() throws {
        let container = try TestStore.makeContainer()
        let row = SyncFix.outbox(record: UUID(), type: "invoice", fields: ["taxRatePercent": 7],
                                 in: SyncFix.reader(container))
        row.park("paid_locked")
        row.modelContext?.saveChanges()
        let store = SyncFix.store(container)

        #expect(store.releaseLapseParks() == 0)
        #expect(store.pendingOps(limit: 50).isEmpty)
    }

    /// A held op goes again on the NEXT cycle, not round after round of the one that was just
    /// refused (a lapsed account with 50+ edits would otherwise spin to the round cap).
    @Test func anOpHeldThisCycleIsNotOfferedAgainInIt() throws {
        let container = try TestStore.makeContainer()
        SyncFix.outbox(record: UUID(), type: "customer", fields: ["firstName": "Held"],
                       in: SyncFix.reader(container))
        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)
        let op = try #require(ops.first)
        let outcome = store.applyResults(
            [op.opID: SyncFix.result(.refused, reason: .subscriptionLapsed)], for: ops)

        #expect(outcome.heldOpIDs == [op.opID])
        #expect(store.pendingOps(limit: 50, excluding: outcome.heldOpIDs).isEmpty)
        #expect(store.pendingOps(limit: 50).map(\.opID) == [op.opID], "the next cycle retries it")
    }

    /// F87. A contested edit is said out loud. The pull still lands the server's value (a parked
    /// row that blocked the pull froze its record in both directions, GLSYNC-SPEC.md §5.4), and
    /// it never overwrites the parked row: the person's value stays in the outbox.
    @Test func aConflictIsToldAndAPullNeverOverwritesTheParkedValue() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let id = SyncFix.newCustomer(named: "Mine", in: context)
        context.saveChanges()
        SyncFix.outbox(record: id, type: "customer", base: 1, fields: ["firstName": "Mine"],
                       in: context)
        let store = SyncFix.store(container)
        let ops = store.pendingOps(limit: 50)
        let op = try #require(ops.first)

        let outcome = store.applyResults([op.opID: SyncFix.result(.conflict, version: 2)], for: ops)
        #expect(outcome.messages.map(\.text) == [GLSyncLocalStore.conflictMessage],
                "a contested edit reverted with nothing said")

        _ = store.applyChanges([SyncFix.liveRow(id, type: "customer", version: 2, seq: 9,
                                                payload: ["firstName": "Theirs", "lastName": "Row"])])

        let parked = try #require(SyncFix.outboxRow(id, in: container))
        #expect(parked.isParked)
        #expect(GLSyncValue.string(parked.fields, "firstName") == "Mine",
                "the pull overwrote the person's parked value")
    }

    /// F88. "Backed up" is stamped only when nothing but parked rows is left.
    @Test func backedUpIsStampedOnlyWhenNothingIsLeftToSend() throws {
        let container = try TestStore.makeContainer()
        let row = SyncFix.outbox(record: UUID(), type: "customer", fields: ["firstName": "Unsent"],
                                 in: SyncFix.reader(container))
        let store = SyncFix.store(container)

        #expect(store.stampSyncedIfDrained() == false)
        #expect(store.persistedState().lastSyncAt == nil, "an unsent edit was reported backed up")

        row.park("paid_locked")
        row.modelContext?.saveChanges()
        #expect(store.stampSyncedIfDrained() == true, "a settled refusal must not hold the stamp forever")
        #expect(store.persistedState().lastSyncAt != nil)
    }

    /// The baseline mint stamps its own field, never the backup time.
    @Test func theHistoryBaselineDoesNotClaimABackup() throws {
        let container = try TestStore.makeContainer()
        let store = SyncFix.store(container)

        store.establishHistoryBaseline()

        let state = try #require((try? SyncFix.reader(container).fetch(FetchDescriptor<GLSyncState>()))?.first)
        #expect(state.lastSyncAt == nil)
        #expect(state.historyBaselineAt != nil)
        #expect(state.lastHistoryTokenData != nil)
    }
}

/// Whole cycles against the in-memory Worker (`GLSyncStubServer`).
@MainActor
@Suite(.serialized)
struct GLSyncLapsedCycleTests {

    /// One customer with a photo: the shape whose upload `/attachments` refuses when lapsed.
    @discardableResult
    private static func customerWithPhoto(in container: ModelContainer) -> UUID {
        let context = SyncFix.reader(container)
        let id = SyncFix.newCustomer(named: "Photo", in: context)
        let match: UUID? = id
        let customer = try? context.fetch(
            FetchDescriptor<Customer>(predicate: #Predicate { $0.syncID == match })).first
        customer?.profileImageData = Data("face".utf8)
        context.saveChanges()
        return id
    }

    private static func lastSyncAt(_ container: ModelContainer) -> Date? {
        let states = (try? SyncFix.reader(container).fetch(FetchDescriptor<GLSyncState>())) ?? []
        return states.first?.lastSyncAt
    }

    /// F57 + F17 on the wire. Lapsed: the attachment's 403 must not abort the cycle (it used to
    /// read as a transient `.server(403)`, so `/sync` never ran and nothing pulled), and the
    /// refused op is held. Renewed: the next cycle sends the very same op id and it lands.
    @Test func aLapsedUploadDoesNotAbortThePushAndTheEditLandsAfterRenewal() async throws {
        let server = GLSyncStubServer(lapsed: true)
        server.install()
        defer { GLSyncStubServer.uninstall() }
        let container = try TestStore.makeContainer()
        let id = Self.customerWithPhoto(in: container)
        let engine = server.engine(container)

        await engine.sync(trigger: .manual)

        #expect(server.paths.contains { $0.hasSuffix("/attachments") },
                "precondition: the photo upload must have been tried")
        let firstPush = try #require(server.syncedOpIDs.first, """
            the lapsed attachment 403 aborted the cycle before /sync — nothing pushed and \
            nothing pulled. Paths: \(server.paths)
            """)
        #expect(firstPush.count == 1)
        let held = try #require(SyncFix.outboxRow(id, in: container), "the refused edit was dropped")
        #expect(!held.isParked, "a lapsed refusal parked the edit — it would never push again")
        #expect(Self.lastSyncAt(container) == nil,
                "a cycle whose only edit was refused claimed a backup (F88)")

        // The person renews.
        server.lapsed = false
        await engine.sync(trigger: .manual)

        #expect(server.syncedOpIDs.count == 2, "the held edit was never offered again")
        #expect(server.syncedOpIDs.last == firstPush,
                "the retry must carry the same op id the Worker refused (it never cached it)")
        #expect(SyncFix.outboxRow(id, in: container) == nil, "the renewed push did not land")
        #expect(Self.lastSyncAt(container) != nil, "a cycle that drained the outbox must stamp")
        await engine.stop()
    }

    /// F88. The history baseline is minted before the first pull. It used to write `lastSyncAt`
    /// to get a transaction, so a first sign-in whose bootstrap failed read "Backup 10:41 AM".
    @Test func aFailedBootstrapLeavesLastSyncAtUnset() async throws {
        let server = GLSyncStubServer(lapsed: false)
        server.snapshotStatus = 500
        server.install()
        defer { GLSyncStubServer.uninstall() }
        let container = try TestStore.makeContainer()
        SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Weak")
        let engine = server.engine(container)

        await engine.sync(trigger: .manual)

        #expect(server.paths.contains { $0.hasSuffix("/snapshot") }, "precondition: bootstrap ran")
        #expect(!server.paths.contains { $0.hasSuffix("/sync") }, "precondition: bootstrap failed")
        #expect(Self.lastSyncAt(container) == nil,
                "a first sync that pulled and pushed nothing claimed a backup time")
        let states = (try? SyncFix.reader(container).fetch(FetchDescriptor<GLSyncState>())) ?? []
        #expect(states.first?.lastHistoryTokenData != nil,
                "the baseline itself must still be minted — that is what makes edits fold")
        await engine.stop()
    }
}

/// The subscription changing mid-session (QA 2026-10-03 F17).
@MainActor
@Suite(.serialized)
struct GLSyncEntitlementChangeTests {

    /// The mint stamps the standing into the token, and the token is cached for 15 minutes. A
    /// renewal drops it and pushes now: the held edit goes under a freshly minted token.
    @Test func aRenewalDropsTheCachedTokenAndPushesTheHeldEdit() async throws {
        let server = GLSyncStubServer(lapsed: true)
        server.install()
        defer { GLSyncStubServer.uninstall() }
        let container = try TestStore.makeContainer()
        let id = SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Renew")[0]
        let engine = server.engine(container)

        await engine.sync(trigger: .manual)
        #expect(server.mints == 1)
        #expect(SyncFix.outboxRow(id, in: container)?.isHeld == true, "precondition: held")

        server.lapsed = false
        await engine.entitlementChanged(
            to: GLSyncEntitlement(isSubscribed: true, serverEntitled: false, isLapsed: false))

        #expect(server.mints == 2, "the renewal pushed under the token minted while lapsed")
        #expect(SyncFix.outboxRow(id, in: container) == nil, "the renewal did not push the held edit")
        await engine.stop()
    }

    /// Lapsing drops the token too, but there is nothing to push.
    @Test func aLapseDropsTheTokenWithoutACycle() async throws {
        let server = GLSyncStubServer(lapsed: false)
        server.install()
        defer { GLSyncStubServer.uninstall() }
        let container = try TestStore.makeContainer()
        SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Lapse")
        let engine = server.engine(container)
        await engine.sync(trigger: .manual)
        let requests = server.paths.count

        await engine.entitlementChanged(
            to: GLSyncEntitlement(isSubscribed: false, serverEntitled: false, isLapsed: true))

        #expect(server.paths.count == requests, "a lapse started a cycle")
        await engine.sync(trigger: .manual)
        #expect(server.mints == 2, "the next cycle reused the token minted before the lapse")
        await engine.stop()
    }

    /// F87. The lapse sentence reaches the screen's queue, once, however many edits it refused.
    @Test func aLapsedCycleQueuesItsSentenceOnce() async throws {
        let server = GLSyncStubServer(lapsed: true)
        server.install()
        GLSyncStatus.shared.clearMessages()
        defer {
            GLSyncStubServer.uninstall()
            GLSyncStatus.shared.clearMessages()
        }
        let container = try TestStore.makeContainer()
        SyncFix.customers(3, in: SyncFix.reader(container), prefix: "Many")
        let engine = server.engine(container)

        await engine.sync(trigger: .manual)
        for _ in 0..<50 where GLSyncStatus.shared.pendingMessages.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(GLSyncStatus.shared.pendingMessages
                == [GLSyncRefusalReason.subscriptionLapsed.userMessage],
                "three refused edits must be one sentence on screen, and it must be there")
        await engine.stop()
    }
}

// MARK: - Fold cost tracks the edit, not the table (QA 2026-10-03 F91)

/// The fold runs on the main actor about 5 s after every save. It used to load EVERY row of
/// each touched type to find the few that history names, so one edit on a large account
/// loaded the whole table (and built payloads that re-hashed every profile document).
@MainActor
struct GLSyncFoldScaleTests {

    @Test func foldingOneEditOnATwoThousandRowTableLoadsOneRow() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let ids = SyncFix.customers(2_000, in: context, prefix: "Big")
        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let token = store.persistedState().historyToken

        let target: UUID? = ids[1_234]
        var descriptor = FetchDescriptor<Customer>(predicate: #Predicate { $0.syncID == target })
        descriptor.fetchLimit = 1
        let customer = try #require(try context.fetch(descriptor).first)
        customer.firstName = "Edited"
        try context.save()

        let result = try store.fold(since: token, writtenUnder: GLSyncHistory.schemaFingerprint)
        #expect(result.enqueued == 1)
        #expect(store.lastFoldRowsFetched == 1,
                "one edit must load one row, not the whole customer table")
        let ops = store.pendingOps(limit: 10)
        #expect(ops.count == 1)
        #expect(ops.first?.recordID == ids[1_234])
        #expect(ops.first?.patchJSON.contains("Edited") == true)
    }

    /// More edits than one row query carries (500): every edited row is still found and queued,
    /// and nothing else is loaded.
    @Test func editsPastOneQueryChunkAreAllFoundAndQueued() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        SyncFix.customers(1_200, in: context, prefix: "Wide")
        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let token = store.persistedState().historyToken

        let all = try context.fetch(FetchDescriptor<Customer>())
        for customer in all.prefix(612) { customer.lastName = "Changed" }
        try context.save()

        let result = try store.fold(since: token, writtenUnder: GLSyncHistory.schemaFingerprint)
        #expect(result.enqueued == 612)
        #expect(store.lastFoldRowsFetched == 612)
        #expect(store.pendingOps(limit: 1_000).count == 612)
    }

    /// Bytes no other test hashes, so "was it hashed?" reads cleanly from the shared cache.
    /// Shared with `GLSyncBlobHashCacheTests` below.
    fileprivate static func uniqueBlob(_ size: Int = 4_096) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    /// A new invoice bumps the profile's `lastInvoiceNumber`. That fold ships the counter
    /// alone and must not hash the logos and compliance documents to build it.
    @Test func aCounterBumpOnTheProfileShipsTheCounterWithoutHashingItsDocuments() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let logo = Self.uniqueBlob()
        let license = Self.uniqueBlob()
        let profile = BusinessProfile()
        let profileID = UUID()
        profile.syncID = profileID
        profile.logoData = logo
        profile.licenseDocumentData = license
        context.insert(profile)
        try context.save()
        SyncFix.stampVersionRow(profileID, 3, in: context)
        let store = SyncFix.store(container)
        store.establishHistoryBaseline()
        let token = store.persistedState().historyToken

        profile.lastInvoiceNumber += 1
        try context.save()

        let result = try store.fold(since: token, writtenUnder: GLSyncHistory.schemaFingerprint)
        #expect(result.enqueued == 1)
        let patch = try #require(store.pendingOps(limit: 10).first?.patchJSON)
        #expect(patch.contains("lastInvoiceNumber"))
        #expect(!patch.contains("logoData") && !patch.contains("licenseDocumentData"))
        #expect(GLSyncBlobHashCache.remembered(logo) == nil, "the logo was hashed for a counter bump")
        #expect(GLSyncBlobHashCache.remembered(license) == nil, "a document was hashed for a counter bump")
    }

    /// The partial build is the full payload, filtered: same keys, same values, field by field.
    @Test func theProfilesPartialPayloadMatchesTheFullOneFieldByField() throws {
        let profile = BusinessProfile()
        profile.syncID = UUID()
        profile.businessName = "Gold Life"
        profile.lastInvoiceNumber = 41
        profile.logoData = Self.uniqueBlob()
        profile.proofOfInsuranceData = Self.uniqueBlob()
        profile.proofOfInsuranceName = "coi.pdf"
        let full = profile.glSyncPayload()
        #expect(NSDictionary(dictionary: profile.glSyncPayload(only: nil)).isEqual(to: full))
        for key in full.keys {
            let partial = profile.glSyncPayload(only: [key])
            #expect(partial.count == 1, "\(key) built extra fields")
            #expect(NSDictionary(dictionary: partial).isEqual(to: full.filter { $0.key == key }),
                    "\(key) differs from the full payload")
        }
        let entry = try #require(GLSyncRegistry.entry(for: "business_profile"))
        let routed = entry.payload(profile, ["businessName", "logoData"])
        #expect(NSDictionary(dictionary: routed).isEqual(
            to: full.filter { ["businessName", "logoData"].contains($0.key) }))
    }
}

/// The process-wide blob-hash cache (QA 2026-10-03 F91, repair round 1). It holds the signed-in
/// person's document bytes as keys, so sign-out empties it and the tax-class W-9 never enters it.
///
/// Serialized so these tests never interleave with each other. Sign-out tests in OTHER suites can
/// still empty the shared cache at any moment; that can only make a "nil" check pass, so every
/// check that expects a remembered hash re-hashes and re-reads (`hashAndRemember`) rather than
/// failing on a clear it did not cause.
@MainActor
@Suite(.serialized)
struct GLSyncBlobHashCacheTests {

    /// Hashes through the cache and reads the answer back from `probe`, retrying when a sign-out
    /// in another suite emptied the cache in between. A cache that never remembers fails all tries.
    private static func hashAndRemember(_ blob: Data, probe: Data? = nil) -> (hex: String, remembered: String?) {
        var hex = ""
        for _ in 0..<5 {
            hex = GLSyncBlobHashCache.sha256(blob)
            if let known = GLSyncBlobHashCache.remembered(probe ?? blob) { return (hex, known) }
        }
        return (hex, nil)
    }

    /// The hash is remembered by the bytes: a second copy of the same bytes (a new buffer, as
    /// a fresh fetch hands back) gets the same answer without hashing again.
    @Test func blobHashesAreRememberedByTheBytes() {
        let blob = GLSyncFoldScaleTests.uniqueBlob()
        #expect(GLSyncBlobHashCache.remembered(blob) == nil)
        let copy = Data(Array(blob))
        let (hex, remembered) = Self.hashAndRemember(blob, probe: copy)
        #expect(hex == glSyncSHA256(blob))
        #expect(remembered == hex)
        var changed = Array(blob)
        changed[changed.count - 1] &+= 1
        #expect(GLSyncBlobHashCache.remembered(Data(changed)) == nil,
                "bytes that differ only at the end must not share a hash")
    }

    /// Sign-out ends the session's caches, this one included: the next person on this phone
    /// must not inherit the previous person's documents sitting in memory.
    @Test func signingOutForgetsEveryRememberedBlob() async throws {
        let container = try TestStore.makeContainer()
        let engine = GLSyncEngine(container: container)
        let blob = GLSyncFoldScaleTests.uniqueBlob()
        let (_, before) = Self.hashAndRemember(blob)
        #expect(before != nil, "the cache never remembered the blob, so this test proves nothing")

        await engine.signedOut()

        #expect(GLSyncBlobHashCache.remembered(blob) == nil,
                "a document hashed before sign-out is still held in memory after it")
        await engine.stop()
    }

    /// A pull compares the local W-9 against the pulled reference. That comparison must never
    /// park the plaintext W-9 (SSN or EIN) in the shared cache, and it gets the same answer.
    @Test func aPulledSubcontractorNeverPutsItsW9InTheCache() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        let w9 = GLSyncFoldScaleTests.uniqueBlob()
        let photo = GLSyncFoldScaleTests.uniqueBlob()
        let id = UUID()
        let sub = Subcontractor()
        sub.syncID = id
        sub.firstName = "Luis"
        sub.w9Data = w9
        sub.profileImageData = photo
        context.insert(sub)
        try context.save()

        let store = SyncFix.store(container)
        let envelopeSHA = glSyncSHA256(GLSyncFoldScaleTests.uniqueBlob())
        let verdict = store.applyChanges([
            SyncFix.liveRow(id, type: "subcontractor", version: 4, seq: 31, payload: [
                "firstName": "Luis",
                "w9Data": ["sha256": envelopeSHA, "name": "w9.pdf"],
                "profileImageData": ["sha256": glSyncSHA256(photo), "name": ""],
            ])
        ])

        let outcome = try #require(SyncFix.outcome(verdict))
        #expect(outcome.applied == 1)
        #expect(GLSyncBlobHashCache.remembered(w9) == nil,
                "the plaintext W-9 was kept in the blob-hash cache")
        // Same answer as before: the envelope hash never matches the plaintext, so it is fetched;
        // the unchanged photo matches and is not.
        #expect(outcome.blobFetches.map(\.field) == ["w9Data"])
    }
}
