//
//  PriceSheetRoundTripTests.swift
//  GLSmallBusinessTests
//
//  QA finding F3 (2026-10-03): the Price Sheet never left the phone. It was not a sync type, so
//  no edit reached the outbox, the sign-out warning (which counts the outbox) never fired, and
//  the sign-out wipe deleted the catalog for good — while What's New promised "Sign back in and
//  they come back". These tests walk the whole road an item takes: saved on the phone → read out
//  of history into the outbox → pushed → wiped at sign-out → pulled back at sign-in.
//
//  THE STUB SERVER. `GLSyncEngine` builds its own transport and token provider (see the header of
//  GLSyncEngineTests.swift), so the engine's cycle cannot be pointed at a fake from here. What
//  the cycle does between the store and the wire is two calls — `pendingOps` out, `applyResults`
//  and `applyChanges` in — and `PriceSheetStubServer` stands in for gl-business-api between them:
//  it reads each op's patch the way the Worker does (JSON text), keeps the merged payload, answers
//  `applied`, and serves its rows back as a pull. Every value therefore crosses a real JSON
//  encode/decode, the same trip it takes over the network.
//

import Foundation
import SwiftData
import Testing
import GoldLifeCloud
@testable import GLSmallBusiness

/// gl-business-api, reduced to what a round trip needs: the records it holds for one account.
@MainActor
private final class PriceSheetStubServer {
    private var rows: [UUID: (type: String, version: Int, seq: Int, deleted: Bool, payload: [String: Any])] = [:]
    private var seq = 0

    /// Accept a push. Every op applies — this server refuses nothing.
    func accept(_ ops: [GLSyncPendingOp]) throws -> [UUID: GLSyncOpResult] {
        var results: [UUID: GLSyncOpResult] = [:]
        for op in ops {
            seq += 1
            var row = rows[op.recordID] ?? (op.recordType, 0, seq, false, [:])
            if op.isDelete {
                row.deleted = true
                row.payload = [:]
            } else {
                let patch = try JSONSerialization.jsonObject(with: Data(op.patchJSON.utf8))
                let fields = try #require(patch as? [String: Any], "a patch is a JSON object")
                row.payload.merge(fields) { _, new in new }
            }
            row.version += 1
            row.seq = seq
            rows[op.recordID] = row
            results[op.opID] = SyncFix.result(.applied, version: row.version)
        }
        return results
    }

    /// What a sign-in pull hands back: every row, live or tombstoned, in write order.
    func pull() -> [GLSyncRecordRow] {
        rows.sorted { $0.value.seq < $1.value.seq }.map { id, row in
            row.deleted
                ? GLSyncRecordRow(id: id, type: row.type, parentID: nil, version: row.version,
                                  seq: row.seq, deletedAt: 1_787_000_000_000, payload: .null)
                : SyncFix.liveRow(id, type: row.type, version: row.version, seq: row.seq,
                                  payload: row.payload)
        }
    }

    func liveCount(of type: String) -> Int {
        rows.values.filter { $0.type == type && !$0.deleted }.count
    }
}

@MainActor
@Suite(.serialized)
struct PriceSheetRoundTripTests {
    private static var retained: [ModelContainer] = []

    private static func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PriceSheetRoundTripTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func consent() throws -> GLAIConsent {
        let defaults = try #require(UserDefaults(suiteName: "PriceSheetRoundTripTests.\(UUID().uuidString)"))
        return GLAIConsent(key: "mb.ai.consent.version", requiredVersion: 3, defaults: defaults)
    }

    private static func items(in container: ModelContainer) throws -> [PriceSheetItem] {
        try ModelContext(container).fetch(FetchDescriptor<PriceSheetItem>(sortBy: [SortDescriptor(\.name)]))
    }

    /// Two items that differ from the model's defaults in every field, so a field the mapper
    /// dropped would come back wrong instead of coinciding with a default.
    private static let tile = PriceItemDraft(
        name: "Tile install", category: "Tile", details: "Thinset, 12x24 porcelain",
        unit: .squareFoot, unitPrice: 12.5, defaultQuantity: 250, kind: .labor,
        isTaxable: false, discountType: .percentage, discountValue: 10)
    private static let haul = PriceItemDraft(
        name: "Haul away", category: "Demo", details: "One trailer load",
        unit: .lumpSum, unitPrice: 95.25, defaultQuantity: 2, kind: .material,
        isTaxable: true, discountType: .fixed, discountValue: 5)

    @Test("a Price Sheet built on this iPhone is backed up, survives the sign-out wipe, and the next sign-in brings it back")
    func thePriceSheetComesBackAfterSignOut() throws {
        let savedWipeFlag = UserDefaults.standard.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        defer {
            if let savedWipeFlag { UserDefaults.standard.set(savedWipeFlag, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
        }
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = "price-sheet-\(UUID().uuidString)"
        let server = PriceSheetStubServer()

        // Signed in: the person's own store, with sync's history watermark already set.
        let before = UserScopedStore.shared.container(for: person, appSupport: root)
        Self.retained.append(before)
        let context = before.mainContext
        context.autosaveEnabled = false
        let store = SyncFix.store(before)
        store.establishHistoryBaseline()
        let baseline = store.persistedState()

        // The owner builds a Price Sheet with two items, through the form's own save path.
        let saved = try DomainState.subscribed.run {
            [try PriceSheetService.create(Self.tile, origin: .screen, in: context),
             try PriceSheetService.create(Self.haul, origin: .screen, in: context)]
        }
        let ids = Set(saved.compactMap(\.syncID))
        #expect(ids.count == 2, "every saved item carries its own sync id")

        // The next sync cycle reads the saves out of history into the outbox…
        let fold = try store.fold(since: baseline.historyToken, writtenUnder: baseline.historyFingerprint)
        #expect(fold.enqueued == 2, "both Price Sheet saves must reach the outbox — at HEAD neither did")
        #expect(MBSessionPurge.unsyncedChangeCount(in: ModelContext(before)) == 2,
                "until they're backed up, signing out warns that they'd be lost")

        // …and pushes them.
        let ops = store.pendingOps(limit: 50)
        #expect(Set(ops.filter { $0.recordType == "price_sheet_item" }.map(\.recordID)) == ids)
        #expect(ops.allSatisfy { $0.parentID == nil }, "a catalog item belongs to the account, not to a parent")
        _ = store.applyResults(try server.accept(ops), for: ops)
        #expect(server.liveCount(of: "price_sheet_item") == 2, "the server now holds the Price Sheet")
        #expect(MBSessionPurge.unsyncedChangeCount(in: ModelContext(before)) == 0,
                "backed up: nothing left for the sign-out warning to count")

        // Sign out: the whole local copy goes.
        MBSessionPurge.run(.sessionEnded, store: .shared, consent: try Self.consent(),
                           appSupport: root, temporary: root.appendingPathComponent("tmp"))

        // Sign back in: an empty store for the same person…
        let after = UserScopedStore.shared.container(for: person, appSupport: root)
        Self.retained.append(after)
        #expect(try Self.items(in: after).isEmpty, "the wipe really emptied this iPhone")

        // …and the sign-in pull brings the same two items back, every field intact.
        _ = SyncFix.store(after).applyChanges(server.pull())
        let back = try Self.items(in: after)
        #expect(back.count == 2, "the Price Sheet must come back after signing in — at HEAD it was gone for good")
        #expect(Set(back.compactMap(\.syncID)) == ids, "the same records, not look-alikes")
        for (item, draft) in zip(back, [Self.haul, Self.tile]) {
            #expect(PriceItemDraft(item) == draft, "\(item.name) came back changed")
        }
        UserScopedStore.shared.wipeOnAccountDeletion(appSupport: root)
    }

    @Test("deleting a Price Sheet item tells the server, so it doesn't come back on the next pull")
    func aDeleteRidesTheWireAsATombstone() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let item = try DomainState.subscribed.run {
            try PriceSheetService.create(Self.tile, origin: .screen, in: context)
        }
        let id = try #require(item.syncID)

        _ = try DomainState.subscribed.run { try DeletionService.delete([.priceItem(item)], in: context) }

        #expect(try context.fetchCount(FetchDescriptor<PriceSheetItem>()) == 0)
        let row = try #require(GLSyncOutboxEntry.entry(for: id, in: context),
                               "the delete must be queued for the server (deleteSynced)")
        #expect(row.isDelete && row.recordType == "price_sheet_item")
    }

    @Test("an item deleted on another device is removed here by the pull")
    func aPulledTombstoneRemovesTheItem() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let item = PriceSheetItem(name: "Grout")
        let id = UUID()
        item.syncID = id
        context.insert(item)
        try context.save()

        let store = SyncFix.store(container)
        _ = store.applyChanges([SyncFix.tombstone(id, type: "price_sheet_item", seq: 5)])

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PriceSheetItem>()) == 0)
    }

    @Test("items saved before this update get an id at launch and upload on the first sync")
    func legacyItemsUploadOnTheFirstCycle() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let legacy = PriceSheetItem(name: "Old grout", unitPrice: 4)
        context.insert(legacy)
        try context.save()
        #expect(legacy.syncID == nil, "precondition: an item from before ids were minted")

        SyncIdentityBackfill.run(context)
        let id = try #require(legacy.syncID, "the launch backfill gives every Price Sheet item an id")

        // A new build re-bootstraps (GLSyncLocalStore.rebaselineHistory), and the bootstrap
        // uploads every local record the server doesn't have.
        let store = SyncFix.store(container)
        #expect(store.enqueueEverything(pulled: [:]) == 1)
        let row = try #require(SyncFix.outboxRow(id, in: container))
        #expect(row.recordType == "price_sheet_item" && !row.isDelete && row.baseVersion == 0)
    }
}
