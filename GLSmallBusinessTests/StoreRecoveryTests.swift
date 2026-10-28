//
//  StoreRecoveryTests.swift
//  GLSmallBusinessTests
//
//  StoreRecovery is the no-crash-path opener for BOTH stores (launch and per-user), and
//  the one rail every "alert AND log" store notice rides to the root alert. Under test
//  (QA 2026-10-03 F63): nothing is ever wiped — a corrupt or incompatible file is moved
//  to a dated Recovered folder, rebuilt, its sync outbox copied over, and announced
//  honestly; a full disk or unreadable storage is retried once, then kept and run in
//  memory. Also: each notice setter posts; a notice is read exactly once; a healthy save
//  raises nothing.
//
//  THE ROOT ALERT IS LIVE IN THIS PROCESS. Unit tests run inside the host app, whose root
//  view carries `StoreRecoveryAlert` — an `.onReceive(.mbStoreRecovered)` that CONSUMES the
//  pending notice and presents. It can do so once per process: nothing dismisses the
//  alert, and `presentIfPending` skips while one is presented. So the FIRST notice posted
//  in the process is eaten by the app, not by the test that posted it. `disarmRootAlert()`
//  spends that one consumption on a throwaway notice before any assertion, and every test
//  starts by pinning the (process-global) pending notice to nil.
//

import Testing
import Foundation
import SwiftData
import Combine
@testable import GLSmallBusiness

/// See `StoreRecoveryTests.incompatibleSchema`.
enum IncompatibleShape {
    @Model final class Customer {
        var firstName: Int = 0
        init() {}
    }
}

/// Every stored field of an outbox row, as a value, so a rescue can be compared exactly.
struct OutboxSnapshot: Equatable {
    var recordID: UUID?
    var recordType: String
    var parentID: UUID?
    var baseVersion: Int
    var fieldsJSON: String
    var isDelete: Bool
    var cascadeJSON: String
    var firstDirtiedAt: Date
    var lastDirtiedAt: Date
    var opID: UUID?
    var attempts: Int
    var lastError: String

    init(_ row: GLSyncOutboxEntry) {
        recordID = row.recordID; recordType = row.recordType; parentID = row.parentID
        baseVersion = row.baseVersion; fieldsJSON = row.fieldsJSON; isDelete = row.isDelete
        cascadeJSON = row.cascadeJSON; firstDirtiedAt = row.firstDirtiedAt
        lastDirtiedAt = row.lastDirtiedAt; opID = row.opID; attempts = row.attempts
        lastError = row.lastError
    }
}

@MainActor
@Suite(.serialized)
struct StoreRecoveryTests {

    // MARK: - Fixtures

    /// Containers built by `StoreRecovery` outlive their test on purpose
    /// (project_swiftdata_test_process_trap). `TestStore`'s retain list is private to it,
    /// so the ones this suite opens are kept here — retained and autosave-off, same rule.
    private static var retained: [ModelContainer] = []

    static func retain(_ container: ModelContainer) -> ModelContainer {
        retained.append(container)
        container.mainContext.autosaveEnabled = false
        return container
    }

    /// See the file header. Idempotent; leaves nothing pending either way. Shared with
    /// `UserScopedStoreTests`, whose no-folder path raises a notice too.
    static func disarmRootAlert() {
        _ = StoreRecovery.consumeNotice()   // pin: nothing pending from launch or a previous test
        StoreRecovery.noteSaveFailed()      // the throwaway — the root alert eats it once…
        _ = StoreRecovery.consumeNotice()   // …or this does. Pending is nil after both.
    }

    /// A fresh per-test folder in the temporary directory, like `TestStore.makeDiskContainer()`.
    static func freshDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The 16-byte magic every SQLite file starts with (minus its trailing NUL).
    private static let sqliteMagic = Data("SQLite format 3".utf8)

    /// The `Recovered/<date>/<name>` copies next to a store, if any.
    static func recoveredCopies(of name: String, in folder: URL) -> [URL] {
        let recovered = folder.appendingPathComponent("Recovered", isDirectory: true)
        let stamps = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil)) ?? []
        return stamps.map { $0.appendingPathComponent(name) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A store this build's model cannot open: `Customer.firstName` as a NUMBER is a type
    /// change no lightweight migration can make (Core Data 134140, the shape of a real
    /// failed migration). The outbox table is the real one.
    static let incompatibleSchema = Schema([IncompatibleShape.Customer.self, GLSyncOutboxEntry.self])

    /// Writes a store in a scratch folder and COPIES its files to `url`, so no live connection
    /// touches the file under test — the way a phone finds it at launch.
    static func writeStore(schema: Schema, to url: URL, _ fill: (ModelContext) -> Void) throws {
        let scratch = try freshDirectory().appendingPathComponent(url.lastPathComponent)
        let writer = retain(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: scratch)))
        let context = ModelContext(writer)
        fill(context)
        try context.save()
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: scratch.path + suffix) {
            try FileManager.default.copyItem(atPath: scratch.path + suffix, toPath: url.path + suffix)
        }
    }

    /// Outbox rows with every field set: one waiting update and one waiting delete with a
    /// cascade, plus (`parked`) one the server already turned down.
    @discardableResult
    static func insertOutboxRows(into context: ModelContext, parked includeParked: Bool = false) -> [OutboxSnapshot] {
        let waiting = GLSyncOutboxEntry(recordID: UUID(), recordType: "customer", parentID: nil,
                                        baseVersion: 3, fieldsJSON: #"{"first_name":"Rosa"}"#,
                                        firstDirtiedAt: Date(timeIntervalSince1970: 1_790_000_000))
        waiting.lastDirtiedAt = Date(timeIntervalSince1970: 1_790_000_500.25)
        waiting.attempts = 2
        waiting.lastError = "offline"
        let delete = GLSyncOutboxEntry(recordID: UUID(), recordType: "invoice", parentID: UUID(),
                                       baseVersion: 7, fieldsJSON: "{}", isDelete: true,
                                       cascadeJSON: "[\"\(UUID().uuidString)\"]",
                                       firstDirtiedAt: Date(timeIntervalSince1970: 1_790_001_000))
        context.insert(waiting)
        context.insert(delete)
        if includeParked {
            let parked = GLSyncOutboxEntry(recordID: UUID(), recordType: "estimate", parentID: nil,
                                           baseVersion: 4, fieldsJSON: #"{"title":"Patio"}"#)
            parked.park("conflict")
            context.insert(parked)
        }
        return [OutboxSnapshot(waiting), OutboxSnapshot(delete)]
    }

    // MARK: - Tests

    /// The Aug 22 launch crash, answered without losing anything (QA 2026-10-03 F63): an
    /// unreadable store file is MOVED to a dated `Recovered` folder next to it (never deleted),
    /// a fresh store is built in its place, the person is told ONCE, and the container that
    /// comes back works.
    @Test func aCorruptStoreIsMovedAsideRebuiltAndAnnounced() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Corrupt.store")
        let garbage = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        try garbage.write(to: url)

        // The publisher delivers synchronously on the posting thread, so the count is exact
        // the moment `openContainer` returns.
        var posts = 0
        let subscription = NotificationCenter.default.publisher(for: .mbStoreRecovered)
            .sink { _ in posts += 1 }
        defer { subscription.cancel() }

        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema,
            migrationPlan: GLMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: url),
            label: "test"))

        #expect(posts == 1, "the root alert must be woken exactly once for one rebuild")
        #expect(StoreRecovery.consumeNotice() == .rebuiltChangesMayBeMissing,
                "a file whose outbox can't be read must not promise that everything re-downloads")
        #expect(StoreRecovery.consumeNotice() == nil, "a notice is read exactly once")

        // The garbage was moved, byte for byte, never deleted.
        let moved = try #require(Self.recoveredCopies(of: "Corrupt.store", in: folder).first,
                                 "the unreadable file was deleted instead of moved aside")
        #expect(try Data(contentsOf: moved) == garbage, "the moved copy must be the original bytes")

        // A real SQLite store sits at the original path.
        let rebuilt = try Data(contentsOf: url)
        #expect(rebuilt.prefix(Self.sqliteMagic.count) == Self.sqliteMagic,
                "what replaced the corrupt file is not a SQLite store")
        #expect(container.configurations.first?.url == url,
                "the rebuilt container must live at the path the app will reopen")
        let customers = try ModelContext(container).fetchCount(FetchDescriptor<Customer>())
        #expect(customers == 0, "the rebuilt container must be usable, and empty")
    }

    /// QA 2026-10-03 F63, the I/O half: a store that is fine but can't be read right now (here:
    /// no permission; on a phone: a full disk, a locked device) is NEVER wiped. HEAD wiped it,
    /// outbox and all. Now: retried once, then the session runs in memory with an honest alert,
    /// and the file — with its unsent changes — is still there for the next launch.
    @Test func anUnreadableButHealthyStoreIsKeptNotWiped() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Locked.store")
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        try Self.writeStore(schema: schema, to: url) { context in
            _ = Self.insertOutboxRows(into: context)
        }
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema,
            migrationPlan: GLMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: url),
            label: "test"))

        #expect(container.configurations.first?.isStoredInMemoryOnly == true,
                "a store that can't be read right now must leave the session in memory, not rebuilt")
        #expect(StoreRecovery.consumeNotice() == .memoryOnly, "the person must be told changes won't be kept")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before, "the store file was wiped or rewritten")
        #expect(Self.recoveredCopies(of: "Locked.store", in: folder).isEmpty,
                "an I/O failure must not move the store aside")
        let reopened = Self.retain(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url)))
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<GLSyncOutboxEntry>()) == 2,
                "the unsent changes in the kept store are gone")
    }

    /// QA 2026-10-03 F63, the model half: a store this build's model can't open (an update
    /// whose migration fails, or a store a newer build wrote) is moved aside, rebuilt, and its
    /// sync outbox — the only thing on the device the server doesn't have — is copied into the
    /// new store, every field intact. The sign-out warning then counts those rows.
    @Test func anIncompatibleStoreIsMovedAsideAndItsOutboxIsRescued() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Old.store")
        var originals: [OutboxSnapshot] = []
        try Self.writeStore(schema: Self.incompatibleSchema, to: url) { context in
            context.insert(IncompatibleShape.Customer())
            originals = Self.insertOutboxRows(into: context)
        }
        let schema = Schema(versionedSchema: GLCurrentSchema.self)

        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema,
            migrationPlan: GLMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: url),
            label: "test"))

        #expect(container.configurations.first?.isStoredInMemoryOnly == false, "the store must be rebuilt on disk")
        #expect(container.configurations.first?.url == url)
        #expect(!Self.recoveredCopies(of: "Old.store", in: folder).isEmpty,
                "the incompatible store must be moved to a Recovered folder, never deleted")

        let rescued = try ModelContext(container).fetch(FetchDescriptor<GLSyncOutboxEntry>())
            .map(OutboxSnapshot.init).sorted { $0.recordType < $1.recordType }
        #expect(rescued == originals.sorted { $0.recordType < $1.recordType },
                "the outbox rows must be copied into the new store, every field intact")
        #expect(MBSessionPurge.unsyncedChanges(in: ModelContext(container))
                == MBSessionPurge.UnsyncedChanges(waiting: 2, parked: 0),
                "the sign-out warning must count the rescued rows")
        #expect(StoreRecovery.consumeNotice() == .rebuiltKeepingChanges(2),
                "the alert must say the unsent changes were kept")
    }

    /// A PARKED row (the server already turned it down) comes over still parked: it holds
    /// the person's value for a side-by-side pick, and the sign-out warning names it apart.
    @Test func aParkedRowComesOverStillParked() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Parked.store")
        try Self.writeStore(schema: Self.incompatibleSchema, to: url) { context in
            context.insert(IncompatibleShape.Customer())
            Self.insertOutboxRows(into: context, parked: true)
        }
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema, migrationPlan: GLMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: url), label: "test"))

        let parked = try ModelContext(container).fetch(FetchDescriptor<GLSyncOutboxEntry>()).filter(\.isParked)
        #expect(parked.count == 1 && parked.first?.parkReason == "conflict", "the park must survive the rescue")
        #expect(MBSessionPurge.unsyncedChanges(in: ModelContext(container))
                == MBSessionPurge.UnsyncedChanges(waiting: 2, parked: 1),
                "the sign-out warning must count the rescued rows, parked ones apart")
        #expect(StoreRecovery.consumeNotice() == .rebuiltKeepingChanges(3))
    }

    /// The alert promises a re-download of everything only when nothing unsent was left
    /// behind: an incompatible store with an EMPTY outbox is the plain `.rebuilt`.
    @Test func anIncompatibleStoreWithNothingUnsentIsAPlainRebuild() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Clean.store")
        try Self.writeStore(schema: Self.incompatibleSchema, to: url) { context in
            context.insert(IncompatibleShape.Customer())
        }
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema, migrationPlan: GLMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: url), label: "test"))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<GLSyncOutboxEntry>()) == 0)
        #expect(!Self.recoveredCopies(of: "Clean.store", in: folder).isEmpty, "moved aside, never deleted")
        #expect(StoreRecovery.consumeNotice() == .rebuilt)
    }

    /// A full disk (stood in through the open seam: a test can't fill the simulator's disk).
    /// Retried exactly once, then the session runs in memory with the "Storage is full"
    /// alert, and the store file is neither wiped nor moved.
    @Test func aFullDiskRetriesOnceThenKeepsTheStoreAndSaysStorageIsFull() throws {
        Self.disarmRootAlert()
        let folder = try Self.freshDirectory()
        let url = folder.appendingPathComponent("Full.store")
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        try Self.writeStore(schema: schema, to: url) { context in
            Self.insertOutboxRows(into: context)
        }
        let before = try Data(contentsOf: url)
        let full = NSError(domain: NSCocoaErrorDomain, code: 134_080, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])

        var calls = 0
        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema, configuration: ModelConfiguration(schema: schema, url: url), label: "test"
        ) { _ in
            calls += 1
            throw full
        })

        #expect(calls == 2, "a full disk is retried exactly once")
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
        #expect(StoreRecovery.consumeNotice() == .storageFull)
        #expect(try Data(contentsOf: url) == before, "a full disk must never wipe the store")
        #expect(Self.recoveredCopies(of: "Full.store", in: folder).isEmpty, "nor move it")
    }

    /// The retry that works is a clean open: that container, no alert.
    @Test func aStorageErrorThatClearsOnTheRetryOpensQuietly() throws {
        Self.disarmRootAlert()
        let url = try Self.freshDirectory().appendingPathComponent("Busy.store")
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url)
        var calls = 0
        let container = Self.retain(StoreRecovery.openContainer(
            schema: schema, configuration: configuration, label: "test"
        ) { config in
            calls += 1
            if calls == 1 { throw NSError(domain: "NSSQLiteErrorDomain", code: 5) }   // SQLITE_BUSY
            return try ModelContainer(for: schema, configurations: config)
        })
        #expect(calls == 2)
        #expect(container.configurations.first?.url == url)
        #expect(StoreRecovery.consumeNotice() == nil, "a retry that works says nothing")
    }

    /// The sort itself, on the shapes Core Data and SQLite actually hand back.
    @Test func errorsAreSortedIntoFullUnavailableAndUnreadable() throws {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        func kind(_ error: Error) -> StoreRecovery.Failure { StoreRecovery.classify(error, storeURL: nowhere) }

        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: ["NSSQLiteErrorDomain": 13])) == .storageFull)
        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .storageFull)
        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: 134_080, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])) == .storageFull)

        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == .storageUnavailable)
        #expect(kind(NSError(domain: "NSSQLiteErrorDomain", code: 10 | (3 << 8))) == .storageUnavailable,
                "an extended SQLITE_IOERR code is still I/O")
        #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) == .storageUnavailable)

        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: 134_140)) == .unreadable, "missing mapping model")
        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: 134_100)) == .unreadable, "incompatible version hash")
        #expect(kind(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                             userInfo: ["NSSQLiteErrorDomain": 26])) == .unreadable, "not a database")
    }

    /// The alert's words: a re-download is promised for everything only on a plain rebuild;
    /// kept changes are counted; unreadable ones are named as possibly missing.
    @Test func theRebuildAlertOnlyPromisesWhatTheServerHas() {
        let plain = StoreRecoveryAlert.message(for: .rebuilt)
        let kept = StoreRecoveryAlert.message(for: .rebuiltKeepingChanges(3))
        let lost = StoreRecoveryAlert.message(for: .rebuiltChangesMayBeMissing)
        #expect(kept.contains("3"), "the kept changes must be counted")
        #expect(Set([plain, kept, lost, StoreRecoveryAlert.message(for: .rebuiltKeepingChanges(1))]).count == 4)
        #expect(StoreRecoveryAlert.title(for: .storageFull) != StoreRecoveryAlert.title(for: .memoryOnly))
        #expect(StoreRecoveryAlert.message(for: .storageFull) != StoreRecoveryAlert.message(for: .memoryOnly))
    }

    /// The two setters other code calls — `GLSyncEngine.runCycle` after a tripped fold
    /// sentinel, `saveChanges()` after a throwing save — each set their own notice and wake
    /// the root alert. That wake is the person's half of "alert AND log": the per-user store
    /// recovers at sign-in, long after the root view's `.onAppear`, so a notice that only
    /// sat in the slot would never be shown.
    @Test func noteSyncRepairedAndNoteSaveFailedSetTheirNoticesAndPost() {
        Self.disarmRootAlert()
        var posts = 0
        let subscription = NotificationCenter.default.publisher(for: .mbStoreRecovered)
            .sink { _ in posts += 1 }
        defer { subscription.cancel() }

        StoreRecovery.noteSyncRepaired()
        #expect(posts == 1, "noteSyncRepaired must wake the root alert")
        #expect(StoreRecovery.consumeNotice() == .syncRepaired)
        #expect(StoreRecovery.consumeNotice() == nil, "a notice is read exactly once")

        StoreRecovery.noteSaveFailed()
        #expect(posts == 2, "noteSaveFailed must wake the root alert")
        #expect(StoreRecovery.consumeNotice() == .saveFailed)
        #expect(StoreRecovery.consumeNotice() == nil, "a notice is read exactly once")
    }

    /// `saveChanges()` is the app's one save helper, and its catch is what reaches
    /// `noteSaveFailed` (ModelContextSave.swift). The throw itself is NOT provoked here: a
    /// valid SwiftData store cannot be made to fail a save from a test — chmod does nothing
    /// to an already-open SQLite connection, and a second read-only `ModelContainer`
    /// (`allowsSave: false`) over a live store file is a bare container on an unverified
    /// path, in a process where one trap ends every other test. So this pins the two halves
    /// that CAN be checked: a healthy save raises no notice (the alert can never fire
    /// spuriously), and the catch branch is wired to the setter the test above proves.
    @Test func saveChangesSurfacesAFailedSave() throws {
        Self.disarmRootAlert()
        var posts = 0
        let subscription = NotificationCenter.default.publisher(for: .mbStoreRecovered)
            .sink { _ in posts += 1 }
        defer { subscription.cancel() }

        // The healthy half: a save that lands says nothing.
        let context = ModelContext(try TestStore.makeContainer())
        context.insert(Customer(firstName: "Healthy", lastName: "Save"))
        context.saveChanges()
        #expect(!context.hasChanges, "precondition: the save must actually have landed")
        #expect(posts == 0, "a successful save must not wake the root alert")
        #expect(StoreRecovery.consumeNotice() == nil, "a successful save must leave no notice")

        // The failure half, at the call site: the catch logs (developer) AND tells (person).
        let source = try #require(GLSource.file("Models/ModelContextSave.swift"))
        let body = try #require(GLSource.functionBody("saveChanges", in: source))
        let catchBranch = try #require(body.range(of: "} catch").map { body[$0.lowerBound...] },
                                       "saveChanges() no longer catches — a failed save would throw out of every form")
        #expect(catchBranch.contains("StoreRecovery.noteSaveFailed()"),
                "a failed save is logged but the person is never told (alert AND log)")
        #expect(catchBranch.contains("Logger.data.error"),
                "the developer half — the log line — is missing from the catch")
    }
}
