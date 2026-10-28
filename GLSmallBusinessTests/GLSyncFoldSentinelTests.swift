//
//  GLSyncFoldSentinelTests.swift
//  GLSmallBusinessTests
//
//  The crash-loop breaker around history reads (GLSyncEngine.swift, "Fold sentinel",
//  2026-09-01 — the build-62 address SIGTRAP). `fetchHistory` traps UNCATCHABLY on a
//  transaction it cannot materialize, so no catch block ever runs; the only defence is a
//  file created before every materializing read and removed after it. A file left behind
//  means the last run died mid-read, and the next launch must PURGE (`deleteHistory` never
//  materializes anything) instead of reading the same row into the same trap.
//
//  Real on-disk stores throughout (`TestStore.makeDiskContainer()`): the sentinel lives
//  beside the store FILE, and an in-memory configuration has no folder to put it in.
//  The engine's own cycle entry is not driveable — `GLSyncEngine.init` builds its token
//  provider over the StytchClient singleton, and `runCycle` returns `.signedOut` before it
//  reaches the sentinel check — so these tests make the store calls `runCycle` makes, in
//  the same order (GLSyncEngine.swift, the `foldSentinelTripped()` branch of `runCycle`).
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct GLSyncFoldSentinelTests {

    // MARK: - Fixtures

    /// Where `GLSyncLocalStore` keeps its sentinel: `<store file>.folding`, beside the store.
    /// Derived from the same fact the store derives it from (`container.configurations.first?.url`)
    /// — and proven to be the store's path rather than this test's guess by
    /// `aTrippedSentinelForcesRebaselineInsteadOfAReadAndClearsItself`, which plants a file
    /// here and watches `foldSentinelTripped()` turn true.
    private static func sentinelURL(of container: ModelContainer) throws -> URL {
        let storeURL = try #require(container.configurations.first?.url,
                                    "a disk container must carry its store URL")
        return storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".folding")
    }

    private static func sentinelExists(for container: ModelContainer) throws -> Bool {
        FileManager.default.fileExists(atPath: try sentinelURL(of: container).path)
    }

    /// One saved customer with a minted `syncID`, so history holds a real user-authored
    /// transaction and the record has an identity the fold can key on. The caller's context
    /// stays alive: the returned object is edited through it later.
    @discardableResult
    private static func seedCustomer(named firstName: String, in context: ModelContext) throws -> Customer {
        let customer = Customer(firstName: firstName, lastName: "Row")
        customer.syncID = UUID()
        context.insert(customer)
        try context.save()
        return customer
    }

    /// Every transaction in persistent history, oldest first, through a fresh context so
    /// nothing registered elsewhere can answer for the store.
    private static func history(of container: ModelContainer) throws -> [DefaultHistoryTransaction] {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.sortBy = [SortDescriptor(\DefaultHistoryTransaction.transactionIdentifier, order: .forward)]
        return try ModelContext(container).fetchHistory(descriptor)
    }

    /// The entity names the changes in `transactions` touched.
    private static func touchedEntities(_ transactions: [DefaultHistoryTransaction]) -> Set<String> {
        Set(transactions.flatMap { transaction in
            transaction.changes.map { $0.changedPersistentIdentifier.entityName }
        })
    }

    // MARK: - Tests

    /// The happy path leaves nothing behind. The sentinel exists only for the duration of a
    /// materializing read; one that outlived a SUCCESSFUL read would make the very next launch
    /// purge history and re-upload the whole store for no reason — and the launch after that,
    /// and every one after.
    @Test func aNormalFoldLeavesNoSentinelBehind() throws {
        let container = try TestStore.makeDiskContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let customer = try Self.seedCustomer(named: "Sentinel", in: context)
        let store = GLSyncLocalStore(container: container)

        let beforeAnyRead = try Self.sentinelExists(for: container)
        #expect(!beforeAnyRead, "a fresh store must not start out tripped")

        // The baseline mint is itself a sentinel-wrapped read (`establishHistoryBaseline`).
        store.establishHistoryBaseline()
        let baseline = store.persistedState()
        #expect(baseline.historyToken != nil, "the baseline must have READ its own transaction")
        let afterBaseline = try Self.sentinelExists(for: container)
        #expect(!afterBaseline, "the baseline read left its sentinel on disk")

        // A real edit after the watermark, then the fold that reads it.
        customer.firstName = "Folded"
        try context.save()
        let fold = try store.fold(since: baseline.historyToken,
                                  writtenUnder: baseline.historyFingerprint)
        #expect(fold.enqueued == 1,
                "the edit must actually have been read — otherwise a missing sentinel proves nothing")

        let afterFold = try Self.sentinelExists(for: container)
        #expect(!afterFold, "a completed fold left its sentinel on disk")
        #expect(!store.foldSentinelTripped(),
                "the store itself must not read a completed fold as a crash")
    }

    /// The breaker. A sentinel left on disk means the last run died INSIDE a history read;
    /// reading again would die on the same row, every launch, until the person deletes the
    /// app. So the cycle must re-baseline — purge FIRST, then drop the watermark and re-arm
    /// bootstrap so the whole store re-uploads — and clear the file, so the NEXT launch reads
    /// normally again instead of purging forever.
    @Test func aTrippedSentinelForcesRebaselineInsteadOfAReadAndClearsItself() throws {
        let container = try TestStore.makeDiskContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let customer = try Self.seedCustomer(named: "Tripped", in: context)
        let store = GLSyncLocalStore(container: container)

        // A store that looks fully synced: bootstrap done, cursor advanced, watermark set.
        store.markBootstrapComplete(cursor: 7)
        store.establishHistoryBaseline()
        let before = store.persistedState()
        #expect(before.historyToken != nil && before.bootstrapComplete && before.cursor == 7,
                "precondition: a synced-looking store")

        // An un-folded user edit sits in history — exactly what a crash mid-read strands.
        customer.firstName = "Stranded"
        try context.save()
        let stranded = try Self.history(of: container)
        #expect(Self.touchedEntities(stranded).contains("Customer"),
                "precondition: the edit must be in history for the purge to mean anything")

        // Plant what a crash mid-read leaves behind: the file, and nothing else.
        let sentinel = try Self.sentinelURL(of: container)
        #expect(FileManager.default.createFile(atPath: sentinel.path, contents: nil))
        #expect(store.foldSentinelTripped(),
                "the store does not look where this test planted the file — the path is wrong on one side")

        // `runCycle`'s breaker branch, in its order: re-baseline (purge first), THEN clear.
        store.rebaselineHistory()
        store.clearFoldSentinel()
        let after = store.persistedState()

        #expect(after.historyToken == nil, "the watermark must be dropped — it points into purged history")
        #expect(!after.bootstrapComplete, "bootstrap must re-run so the whole store re-uploads (lossless)")
        #expect(after.historyFingerprint == GLSyncHistory.schemaFingerprint,
                "the shape this build reads must be stamped with the reset")
        #expect(after.cursor == 7, "a history reset must not touch the server cursor")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path),
                "the sentinel must be cleared, or every launch re-purges")
        #expect(!store.foldSentinelTripped())

        // Purged, not read: the stranded transaction is gone AND nothing was folded from it.
        let remaining = try Self.history(of: container)
        #expect(!Self.touchedEntities(remaining).contains("Customer"),
                "the user's transaction survived the purge — the next read would materialize it")
        #expect(remaining.allSatisfy { $0.author == GLSyncHistory.applyAuthor },
                "only the engine's own post-purge state write may remain in history")
        #expect(GLSyncOutboxEntry.all(in: ModelContext(container)).isEmpty,
                "a tripped sentinel must never READ history into the outbox")

        // Lossless: with bootstrap re-armed, the first-run upload carries the record whose
        // edit was purged, so the edit still reaches the server.
        #expect(store.enqueueEverything(pulled: [:]) == 1)
    }

    /// Order is the whole point of `rebaselineHistory`: PURGE first, then drop the token.
    /// The other order is worse than doing nothing — a nil token means "read from the
    /// beginning", which would materialize the very rows that trap. `deleteHistory` never
    /// materializes a transaction, which is what makes the purge safe on poisoned history.
    @Test func rebaselinePurgesHistoryFirst() throws {
        let container = try TestStore.makeDiskContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try Self.seedCustomer(named: "Purge", in: context)

        let before = try Self.history(of: container)
        #expect(Self.touchedEntities(before).contains("Customer"),
                "precondition: the store must record history, or the purge below proves nothing")

        let store = GLSyncLocalStore(container: container)
        store.rebaselineHistory()

        // The purge ran before the reset's own state write: the user's transaction is gone,
        // and the only thing that may postdate it is that write (author `gl-sync`, one
        // GLSyncState row). Anything else here means something was read, or left readable.
        let after = try Self.history(of: container)
        #expect(!Self.touchedEntities(after).contains("Customer"),
                "the user's transaction survived the purge")
        #expect(Self.touchedEntities(after).isSubset(of: Set(["GLSyncState"])),
                "only the reset's own state row may postdate the purge")
        #expect(after.allSatisfy { $0.author == GLSyncHistory.applyAuthor },
                "a non-engine transaction outlived the purge")

        let state = store.persistedState()
        #expect(state.historyToken == nil)
        #expect(!state.bootstrapComplete)
        #expect(state.historyFingerprint == GLSyncHistory.schemaFingerprint)
    }
}
