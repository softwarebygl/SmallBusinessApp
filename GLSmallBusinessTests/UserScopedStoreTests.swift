//
//  UserScopedStoreTests.swift
//  GLSmallBusinessTests
//
//  The per-person store: that its folder name can never escape the Stores directory, where
//  it lives on disk, that mounting the same person twice is one container, and that account
//  deletion marks the default store for a wipe at the next launch (it cannot be wiped while
//  the launch container holds it open — CRUD audit 2026-09-02). And that a missing Application
//  Support folder is answered, never trapped: the session runs in memory and the wipe has
//  nothing on disk to remove (the old `.first!` in both paths).
//
//  `UserScopedStore.shared` is process-global and the host app owns it, so every test that
//  mounts a store tears its own mount down again through `wipeOnAccountDeletion()` — the
//  app's own removal path — and puts back the one UserDefaults key that call sets. Left
//  `true`, that key would make the host app's NEXT launch wipe its default store.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct UserScopedStoreTests {

    // MARK: - Fixtures

    /// Containers `UserScopedStore` builds are kept for the life of the process
    /// (project_swiftdata_test_process_trap) — the store drops its own reference on wipe.
    private static var retained: [ModelContainer] = []

    private static let wipeKey = UserScopedStore.pendingDefaultStoreWipeKey

    /// `Application Support/Stores` — the folder every per-person store lives under.
    private static var storesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stores")
    }

    /// An id that is already filename-safe, so the folder name IS the id and the
    /// path assertion below has one fewer moving part.
    private static func freshID() -> String { "test-" + UUID().uuidString }

    /// Snapshot the pending-wipe flag so a test can put it back exactly as it found it.
    private static func pinWipeFlag() -> Any? {
        UserDefaults.standard.object(forKey: wipeKey)
    }

    private static func restoreWipeFlag(_ saved: Any?) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: wipeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: wipeKey)
        }
    }

    /// Unmount and delete the test's store the way the app does, then put the flag back.
    private static func tearDown(restoring saved: Any?) {
        UserScopedStore.shared.wipeOnAccountDeletion()
        restoreWipeFlag(saved)
    }

    private static func mount(_ id: String) -> ModelContainer {
        let container = UserScopedStore.shared.container(for: id)
        retained.append(container)
        container.mainContext.autosaveEnabled = false
        return container
    }

    // MARK: - Tests

    /// The canonical id arrives from the server and lands in a FILENAME. Anything that could
    /// mean something to a path becomes `_`, the length is capped, and a real id — a UUID —
    /// passes through untouched.
    @Test func sanitizedStripsPathMeaningCapsLengthAndPassesUUIDsThrough() {
        #expect(UserScopedStore.sanitized("../../etc/passwd") == "______etc_passwd")

        let eighty = String(repeating: "a", count: 80)
        #expect(UserScopedStore.sanitized(eighty).count == 64)
        #expect(UserScopedStore.sanitized(eighty) == String(repeating: "a", count: 64),
                "the cap must keep the leading characters, not scramble them")

        let uuid = UUID().uuidString
        #expect(UserScopedStore.sanitized(uuid) == uuid, "real ids are UUIDs and must pass through untouched")
    }

    /// Mounting the signed-in person is idempotent — the same live container, not a second
    /// one over the same file — and the store sits where the app will look for it next launch:
    /// `Application Support/Stores/<id>/GLSmallBusiness.store`.
    @Test func mountingTheSameIdTwiceIsOneContainerUnderTheStoresFolder() throws {
        let saved = Self.pinWipeFlag()
        defer { Self.tearDown(restoring: saved) }
        let id = Self.freshID()

        let first = Self.mount(id)
        let second = UserScopedStore.shared.container(for: id)
        #expect(first === second, "re-mounting the signed-in person must reuse the live container")
        #expect(UserScopedStore.shared.activeMainContext === first.mainContext,
                "the mounted person's main context must be the one composers read")

        let storeDir = Self.storesRoot.appendingPathComponent(id)
        let storeURL = storeDir.appendingPathComponent("GLSmallBusiness.store")
        #expect(first.configurations.first?.url.standardizedFileURL.path == storeURL.standardizedFileURL.path,
                "the store is not under Application Support/Stores/<id>/")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: storeDir.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
                "the person's store folder was not created")
        #expect(FileManager.default.fileExists(atPath: storeURL.path),
                "the store file was not created where the app will reopen it")
    }

    /// Account deletion is the one exit that wipes. The person's own store folder goes now;
    /// the default store — held open by the launch container — is MARKED instead, and the
    /// next launch wipes it before that container exists. The live references are dropped.
    @Test func wipeOnAccountDeletionRemovesTheStoreAndMarksTheDefaultStoreForNextLaunch() throws {
        let saved = Self.pinWipeFlag()
        defer { Self.restoreWipeFlag(saved) }
        // Pin: start unmarked, so a `true` below can only be this call's doing.
        UserDefaults.standard.removeObject(forKey: Self.wipeKey)

        let id = Self.freshID()
        _ = Self.mount(id)
        let storeDir = Self.storesRoot.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: storeDir.path),
                "precondition: the person's store folder must exist before the wipe")

        UserScopedStore.shared.wipeOnAccountDeletion()

        #expect(UserDefaults.standard.bool(forKey: Self.wipeKey),
                "the default store must be marked for the next launch's wipe")
        #expect(!FileManager.default.fileExists(atPath: storeDir.path),
                "the deleted account's store folder must be gone now")
        #expect(UserScopedStore.shared.activeMainContext == nil, "the live container must be dropped")
        #expect(UserScopedStore.shared.activeEngine == nil, "the live engine must be dropped")
    }

    /// The folder is injectable, and mounting and the wipe name the same one
    /// (`storeDirectory`): `<folder>/Stores/<id>/GLSmallBusiness.store`, created on mount and
    /// removed by the wipe.
    @Test func mountAndWipeUseTheSameInjectedFolder() throws {
        let saved = Self.pinWipeFlag()
        defer { Self.restoreWipeFlag(saved) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = Self.freshID()

        let container = UserScopedStore.shared.container(for: id, appSupport: root)
        Self.retained.append(container)
        container.mainContext.autosaveEnabled = false
        let storeDir = UserScopedStore.storeDirectory(for: id, in: root)
        #expect(storeDir.standardizedFileURL.path
                == root.appendingPathComponent("Stores").appendingPathComponent(id).standardizedFileURL.path)
        #expect(container.configurations.first?.url.standardizedFileURL.path
                == storeDir.appendingPathComponent("GLSmallBusiness.store").standardizedFileURL.path,
                "the store must live in the injected folder")
        #expect(FileManager.default.fileExists(atPath: storeDir.path), "the person's store folder was not created")

        UserScopedStore.shared.wipeOnAccountDeletion(appSupport: root)
        #expect(!FileManager.default.fileExists(atPath: storeDir.path), "the wipe must remove the same folder")
        #expect(UserScopedStore.shared.activeMainContext == nil)
    }

    /// No Application Support folder (the system lookup came back empty — it used to be
    /// force-unwrapped). Signing in never traps and never falls back to the shared default
    /// store: the session runs in memory and the root alert is told nothing will be kept. The
    /// account-deletion wipe finds nothing on disk, logs it, and still drops the live
    /// references and marks the default store for the next launch.
    @Test func noApplicationSupportFolderRunsInMemoryAndTheWipeStillCompletes() throws {
        let saved = Self.pinWipeFlag()
        defer { Self.restoreWipeFlag(saved) }
        UserDefaults.standard.removeObject(forKey: Self.wipeKey)
        StoreRecoveryTests.disarmRootAlert()

        let container = UserScopedStore.shared.container(for: Self.freshID(), appSupport: nil)
        Self.retained.append(container)
        container.mainContext.autosaveEnabled = false
        #expect(container.configurations.first?.isStoredInMemoryOnly == true,
                "with no folder the person's store must run in memory, not in the shared default store")
        #expect(StoreRecovery.consumeNotice() == .memoryOnly, "the person must be told changes won't be kept")
        #expect(UserScopedStore.shared.activeMainContext === container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Customer>()) == 0, "the in-memory store works")

        UserScopedStore.shared.wipeOnAccountDeletion(appSupport: nil)
        #expect(UserScopedStore.shared.activeMainContext == nil, "the live container must be dropped")
        #expect(UserScopedStore.shared.activeEngine == nil, "the live engine must be dropped")
        #expect(UserDefaults.standard.bool(forKey: Self.wipeKey),
                "the default store must still be marked for the next launch's wipe")
    }

    /// QA 2026-10-03 F63 at sign-in: the person's store that this build can't open is moved to
    /// `Stores/<id>/Recovered/<date>/` (never deleted), rebuilt, and its unsent changes land in
    /// the mounted store — where the sign-out warning counts them. The session wipe (law 13)
    /// then takes every Recovered copy with it, the launch store's too: a moved-aside copy is
    /// still the person's data and never outlives their session.
    @Test func anIncompatibleStoreAtSignInIsRescuedAndTheWipeTakesTheRecoveredCopies() throws {
        let saved = Self.pinWipeFlag()
        defer { Self.restoreWipeFlag(saved) }
        StoreRecoveryTests.disarmRootAlert()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = Self.freshID()
        let storeDir = UserScopedStore.storeDirectory(for: id, in: root)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try StoreRecoveryTests.writeStore(schema: StoreRecoveryTests.incompatibleSchema,
                                          to: storeDir.appendingPathComponent("GLSmallBusiness.store")) { context in
            context.insert(IncompatibleShape.Customer())
            StoreRecoveryTests.insertOutboxRows(into: context)
        }

        let container = UserScopedStore.shared.container(for: id, appSupport: root)
        Self.retained.append(container)
        container.mainContext.autosaveEnabled = false
        _ = StoreRecovery.consumeNotice()

        #expect(!StoreRecoveryTests.recoveredCopies(of: "GLSmallBusiness.store", in: storeDir).isEmpty,
                "the person's unreadable store must be moved under their own folder, never deleted")
        #expect(MBSessionPurge.unsyncedChanges(in: UserScopedStore.shared.activeMainContext).total == 2,
                "the rescued changes must be in the mounted store, where the sign-out warning counts them")

        // The launch store's Recovered copy sits at the top of Application Support.
        let launchCopy = root.appendingPathComponent("Recovered/2026-10-04T00-00-00Z/default.store")
        try FileManager.default.createDirectory(at: launchCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: launchCopy)

        UserScopedStore.shared.wipeLocalCopy(appSupport: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Stores").path),
                "the session wipe must remove every per-person store, Recovered copies included")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovered").path),
                "the launch store's Recovered copy must not outlive the session (law 13)")
    }
}
