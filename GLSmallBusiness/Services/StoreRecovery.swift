//
//  StoreRecovery.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Opens a SwiftData container WITHOUT a crash path. Both stores (the launch
//  container and the per-user UserScopedStore) go through the one function here,
//  so the recovery behavior can never drift between them.
//
//  Why crashing was wrong: a store that fails to open used to hit `fatalError`,
//  which is exactly the Aug 22 crash (GLSmallBusinessApp.swift:115 in 3.0.0 (40)
//  — assertionFailure in the sharedModelContainer closure, app dead before the
//  first frame). REQUIREMENTS law 14: a store that will not open is rebuilt from
//  the backend (alert + log), never fatalError.
//
//  Why wiping was wrong too (QA 2026-10-03 F63): the store is a cache of the
//  backend EXCEPT for its sync outbox — the changes this device hasn't uploaded
//  yet. Deleting the file on any open error lost those, and a full disk or a
//  locked device is not a broken store at all. So the error is classified first:
//    - storage can't be used right now (full, no permission, I/O): retry once,
//      then run this session in memory with an honest alert. The file is kept,
//      untouched, for the next launch.
//    - the file can't be read by this build (a failed migration, a store a newer
//      build wrote, a corrupt file): the files MOVE to a dated `Recovered` folder
//      next to the store (never deleted), a fresh store is built, its outbox rows
//      are copied over from the moved copy, and sync re-downloads the rest. The
//      alert promises the re-download only when nothing unsent was left behind.
//  The Recovered copies are the person's data, so the session wipe removes them
//  with everything else (law 13; `UserScopedStore.wipeLocalCopy`).
//

import Foundation
import OSLog
import SQLite3
import SwiftData

/// Removes a SwiftData store and its `-wal` / `-shm` sidecars. Only for a store that
/// MUST go — the account-deletion mark, wiped at the next launch before the container
/// opens. Never a recovery step: an unreadable store is moved aside instead (F63).
nonisolated func wipeSwiftDataStore(at url: URL) {
    let fileManager = FileManager.default
    for path in [url.path, url.path + "-wal", url.path + "-shm"] {
        try? fileManager.removeItem(atPath: path)
    }
}

@MainActor
enum StoreRecovery {

    private static let log = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness",
                                    category: "StoreRecovery")

    /// What happened while opening a store, when it wasn't a clean open. Read by
    /// the root alert exactly once (`consumeNotice`).
    enum Notice: Equatable {
        /// The on-disk copy couldn't be read, was moved aside, and a fresh store
        /// opened. Nothing in it was waiting to upload, so everything re-downloads.
        case rebuilt
        /// As `rebuilt`, and this many changes that weren't uploaded yet were copied
        /// into the fresh store (parked ones stay parked, as they were).
        case rebuiltKeepingChanges(Int)
        /// As `rebuilt`, but the old copy's list of unsent changes couldn't be read.
        /// The old files are kept; changes not backed up yet may be missing.
        case rebuiltChangesMayBeMissing
        /// The device is out of space. Nothing was deleted; the session runs in memory.
        case storageFull
        /// The device's storage couldn't be used (or even a fresh on-disk store
        /// wouldn't open); running on an in-memory store so the app still works,
        /// but nothing survives closing it.
        case memoryOnly
        /// A previous run crashed while reading the sync journal (the fold
        /// sentinel tripped); the journal was purged and the store re-uploads.
        /// No user data is lost — the journal only tracks WHAT changed.
        case syncRepaired
        /// A save threw — the screen may look saved while the change is not on
        /// disk. Rare (disk full, validation); the person must know to retry.
        case saveFailed
    }

    private static var pendingNotice: Notice?

    /// One-shot read for the root alert, so a notice is shown exactly once.
    static func consumeNotice() -> Notice? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    /// Called by the sync engine when the crash-loop breaker fires (a previous
    /// run died inside a history read). Same alert rail as a store rebuild.
    static func noteSyncRepaired() {
        log.error("[sync] fold sentinel tripped — history purged, store re-uploading")
        pendingNotice = .syncRepaired
        announce()
    }

    /// Called by `saveChanges()` when a save throws — the log line already
    /// exists at the call site; this is the person's half.
    static func noteSaveFailed() {
        pendingNotice = .saveFailed
        announce()
    }

    /// Called by `UserScopedStore` when the person's store has no Application Support folder
    /// to live in and runs in memory — the same alert as the last-resort fallback below.
    static func noteMemoryOnly() {
        pendingNotice = .memoryOnly
        announce()
    }

    private static func note(_ notice: Notice) {
        pendingNotice = notice
        announce()
    }

    /// Wakes the root alert. `.onAppear` alone only covered the launch
    /// container: the per-user store opens at SIGN-IN, long after the root
    /// view appeared, so its recovery used to log and then die unshown.
    private static func announce() {
        NotificationCenter.default.post(name: .mbStoreRecovered, object: nil)
    }

    // MARK: - Opening

    /// Opens `configuration` without a crash path and without losing unsent changes
    /// (see the file header). Never throws.
    static func openContainer(schema: Schema,
                              migrationPlan: (any SchemaMigrationPlan.Type)?,
                              configuration: ModelConfiguration,
                              label: String) -> ModelContainer {
        openContainer(schema: schema, configuration: configuration, label: label) { config in
            try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: config)
        }
    }

    /// The same, with the open itself injectable so a test can stand in a full disk.
    static func openContainer(schema: Schema,
                              configuration: ModelConfiguration,
                              label: String,
                              open: (ModelConfiguration) throws -> ModelContainer) -> ModelContainer {
        let firstError: Error
        do {
            return try open(configuration)
        } catch {
            firstError = error
        }
        let url = configuration.url
        let failure = classify(firstError, storeURL: url)
        log.error("[\(label)] store failed to open (\(String(describing: failure), privacy: .public)): \(String(describing: firstError), privacy: .public)")

        // Storage that can't be used right now: retry once, then keep the file and run in memory.
        if failure != .unreadable {
            do {
                let container = try open(configuration)
                log.error("[\(label)] store opened on the retry")
                return container
            } catch {
                let full = failure == .storageFull || classify(error, storeURL: url) == .storageFull
                log.fault("[\(label)] retry failed: \(String(describing: error), privacy: .public) — store kept, this session runs in memory")
                note(full ? .storageFull : .memoryOnly)
                return memoryContainer(schema: schema, label: label)
            }
        }

        // This build can't read the file: move it aside, rebuild, rescue the outbox.
        let moved = moveAside(url)
        var rebuilt: ModelContainer?
        switch moved {
        case .moved, .nothingToMove:
            do {
                rebuilt = try open(configuration)
            } catch {
                log.fault("[\(label)] fresh store also failed to open: \(String(describing: error), privacy: .public)")
            }
        case .failed:
            log.fault("[\(label)] couldn't move the unreadable store aside; it stays in place, untouched")
        }
        let container = rebuilt ?? memoryContainer(schema: schema, label: label)
        let source: URL? = switch moved {
        case .moved(let copy): copy
        case .failed: url
        case .nothingToMove: nil
        }
        let rescue = source.map { rescueOutbox(from: $0, into: container) } ?? .copied(0)
        if case .moved(let copy) = moved {
            log.error("[\(label)] unreadable store moved to \(copy.deletingLastPathComponent().lastPathComponent, privacy: .public); outbox rescue: \(String(describing: rescue), privacy: .public)")
        }

        guard rebuilt != nil else {
            note(.memoryOnly)
            return container
        }
        switch (moved, rescue) {
        case (.nothingToMove, _):
            break   // nothing was there to reset: a first open that failed once, now fine
        case (_, .copied(0)):
            note(.rebuilt)
        case (_, .copied(let count)):
            note(.rebuiltKeepingChanges(count))
        case (_, .unreadable):
            note(.rebuiltChangesMayBeMissing)
        }
        return container
    }

    /// Last resort: an in-memory store so the app still works this session.
    private static func memoryContainer(schema: Schema, label: String) -> ModelContainer {
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: memory)
        } catch {
            log.fault("[\(label)] in-memory container failed: \(error)")
            if let fallback = try? ModelContainer(for: Schema([]), configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
                return fallback
            }
            if let disk = try? ModelContainer(for: schema) {
                return disk
            }
            if let emptyDisk = try? ModelContainer(for: Schema([])) {
                return emptyDisk
            }
            // unreachable: empty in-memory SwiftData container allocation only fails on process memory exhaustion
            fatalError("[\(label)] unrecoverable ModelContainer allocation failure: \(error)")
        }
    }

    // MARK: - Classifying the error

    /// Why a store didn't open, as far as recovery cares.
    nonisolated enum Failure: Equatable {
        /// The device is out of space.
        case storageFull
        /// The storage can't be used right now: no permission, a locked device, an I/O error.
        case storageUnavailable
        /// The file itself can't be read by this build: a failed migration, a newer
        /// build's store, a corrupt file, or anything unrecognized.
        case unreadable
    }

    /// Reads every error in the chain — SwiftData's wrapper hides Core Data's error in a
    /// private field, so it is reached by reflection, then `NSUnderlyingErrorKey` — and
    /// sorts it. A file that exists but can't be read by this process is storage too.
    nonisolated static func classify(_ error: Error, storeURL: URL) -> Failure {
        var codes: [(domain: String, code: Int)] = []
        for nsError in errorChain(error) {
            codes.append((nsError.domain, nsError.code))
            if let sqlite = nsError.userInfo["NSSQLiteErrorDomain"] as? Int {
                codes.append(("NSSQLiteErrorDomain", sqlite))
            }
        }
        if codes.contains(where: isStorageFull) { return .storageFull }
        if codes.contains(where: isStorageUnavailable) { return .storageUnavailable }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storeURL.path), !fileManager.isReadableFile(atPath: storeURL.path) {
            return .storageUnavailable
        }
        return .unreadable
    }

    nonisolated private static func isStorageFull(_ code: (domain: String, code: Int)) -> Bool {
        switch code.domain {
        case NSPOSIXErrorDomain: [Int(ENOSPC), Int(EDQUOT)].contains(code.code)
        case NSCocoaErrorDomain: code.code == NSFileWriteOutOfSpaceError
        case "NSSQLiteErrorDomain": code.code & 0xFF == Int(SQLITE_FULL)
        default: false
        }
    }

    nonisolated private static func isStorageUnavailable(_ code: (domain: String, code: Int)) -> Bool {
        switch code.domain {
        case NSPOSIXErrorDomain:
            [Int(EIO), Int(EACCES), Int(EPERM), Int(EROFS), Int(EBUSY)].contains(code.code)
        case NSCocoaErrorDomain:
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError,
             NSFileWriteVolumeReadOnlyError].contains(code.code)
        case "NSSQLiteErrorDomain":
            [SQLITE_IOERR, SQLITE_CANTOPEN, SQLITE_READONLY, SQLITE_PERM, SQLITE_BUSY,
             SQLITE_LOCKED, SQLITE_AUTH].map(Int.init).contains(code.code & 0xFF)
        default: false
        }
    }

    /// The error and everything it wraps, breadth-first, at most 16 deep.
    nonisolated static func errorChain(_ error: Error) -> [NSError] {
        var found: [NSError] = []
        var queue: [Any] = [error]
        while !queue.isEmpty, found.count < 16 {
            let next = queue.removeFirst()
            if let wrapped = next as? Error {
                let nsError = wrapped as NSError
                found.append(nsError)
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] { queue.append(underlying) }
                // Core Data's NSDetailedErrorsKey, and Foundation's list of underlying errors.
                if let detailed = nsError.userInfo["NSDetailedErrors"] as? [Any] { queue += detailed }
                if let multiple = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Any] { queue += multiple }
            }
            // Stored properties that hold errors (SwiftDataError's `_underlyingCocoaError`,
            // CocoaError's `_nsError`), optionals unwrapped.
            for child in Mirror(reflecting: next).children {
                let value = child.value
                let mirror = Mirror(reflecting: value)
                if mirror.displayStyle == .optional {
                    if let some = mirror.children.first?.value, some is Error { queue.append(some) }
                } else if value is Error {
                    queue.append(value)
                }
            }
        }
        return found
    }

    // MARK: - Moving aside

    nonisolated enum MoveOutcome: Equatable {
        /// Moved; the store file's new path.
        case moved(URL)
        /// No store file or sidecar existed.
        case nothingToMove
        /// A move failed; whatever moved was put back, and nothing at the path changed.
        case failed
    }

    /// Moves the store and its `-wal` / `-shm` to `<folder>/Recovered/<UTC date>/`, never
    /// deleting anything. Sidecars go FIRST and the store file last, so a store rebuilt at
    /// the path can never meet the old store's write-ahead log.
    nonisolated static func moveAside(_ url: URL, now: Date = Date()) -> MoveOutcome {
        let fileManager = FileManager.default
        let present = ["-wal", "-shm", ""].filter { fileManager.fileExists(atPath: url.path + $0) }
        guard !present.isEmpty else { return .nothingToMove }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        let recovered = url.deletingLastPathComponent().appendingPathComponent("Recovered", isDirectory: true)
        var folder = recovered.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            folder = recovered.appendingPathComponent(
                formatter.string(from: now) + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        }
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        var done: [String] = []
        for suffix in present {
            do {
                try fileManager.moveItem(atPath: url.path + suffix, toPath: destination.path + suffix)
                done.append(suffix)
            } catch {
                for back in done { try? fileManager.moveItem(atPath: destination.path + back, toPath: url.path + back) }
                return .failed
            }
        }
        return .moved(destination)
    }

    // MARK: - Rescuing the outbox

    enum RescueOutcome: Equatable {
        /// The old outbox was read and this many rows were copied (0: it was empty).
        case copied(Int)
        /// The old outbox couldn't be read or the copy couldn't be saved.
        case unreadable
    }

    /// Copies the outbox rows of the store at `source` into `container`, every field kept
    /// (the `opID` too, so a push the server already took replays as cached, not twice).
    /// Parked rows come over parked: they still hold the person's value for a side-by-side
    /// pick, and a parked row never blocks its record's download (`pendingRecordIDs`).
    /// The source is read straight from SQLite, read-only: the reason it is being rescued
    /// is that this build's model can't open it, and SwiftData can't open it read-only
    /// either (Core Data still wants to migrate it: 134110). The outbox table's columns
    /// are this app's own `GLSyncOutboxEntry` fields, named the way Core Data names them.
    static func rescueOutbox(from source: URL, into container: ModelContainer) -> RescueOutcome {
        // The last-resort empty-schema container has no outbox to write into (an insert
        // there would trap); the rows stay safe in the source file.
        guard container.schema.entities.contains(where: { $0.name == "GLSyncOutboxEntry" }) else {
            return .unreadable
        }
        guard let rows = readOutboxRows(at: source) else { return .unreadable }
        let context = ModelContext(container)
        var copied = 0
        for row in rows {
            guard let recordID = row.recordID,
                  GLSyncOutboxEntry.entry(for: recordID, in: context) == nil else { continue }
            let entry = GLSyncOutboxEntry(recordID: recordID, recordType: row.recordType,
                                          parentID: row.parentID, baseVersion: row.baseVersion,
                                          fieldsJSON: row.fieldsJSON, isDelete: row.isDelete,
                                          cascadeJSON: row.cascadeJSON, firstDirtiedAt: row.firstDirtiedAt)
            entry.lastDirtiedAt = row.lastDirtiedAt
            if let opID = row.opID { entry.opID = opID }
            entry.attempts = row.attempts
            entry.lastError = row.lastError
            context.insert(entry)
            copied += 1
        }
        guard copied > 0 else { return .copied(0) }
        do {
            try context.save()
            return .copied(copied)
        } catch {
            log.error("outbox rescue couldn't save: \(String(describing: error), privacy: .public)")
            context.rollback()
            return .unreadable
        }
    }

    /// One outbox row as read from the old file.
    nonisolated struct OutboxRow: Equatable {
        var recordID: UUID?
        var recordType = ""
        var parentID: UUID?
        var baseVersion = 0
        var fieldsJSON = ""
        var isDelete = false
        var cascadeJSON = "[]"
        var firstDirtiedAt = Date.distantPast
        var lastDirtiedAt = Date.distantPast
        var opID: UUID?
        var attempts = 0
        var lastError = ""
    }

    /// The outbox rows in a store file, or nil when the file can't be read as a database.
    /// A database without an outbox table (a store from before GLSync) has none: `[]`.
    nonisolated static func readOutboxRows(at url: URL) -> [OutboxRow]? {
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }

        func query(_ sql: String, _ each: (OpaquePointer) -> Void) -> Bool {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return false }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: each(statement)
                case SQLITE_DONE: return true
                default: return false
                }
            }
        }

        let table = "ZGLSYNCOUTBOXENTRY"
        var columns: [String] = []
        guard query("PRAGMA table_info(\(table))", { statement in
            if let name = sqlite3_column_text(statement, 1) { columns.append(String(cString: name)) }
        }) else { return nil }
        if columns.isEmpty {
            // No outbox table — but only a real database says so; garbage fails here.
            return query("SELECT count(*) FROM sqlite_master", { _ in }) ? [] : nil
        }
        let wanted = ["ZRECORDID", "ZRECORDTYPE", "ZPARENTID", "ZBASEVERSION", "ZFIELDSJSON",
                      "ZISDELETE", "ZCASCADEJSON", "ZFIRSTDIRTIEDAT", "ZLASTDIRTIEDAT", "ZOPID",
                      "ZATTEMPTS", "ZLASTERROR"].filter(columns.contains)
        guard wanted.contains("ZRECORDID"), wanted.contains("ZRECORDTYPE"), wanted.contains("ZFIELDSJSON") else {
            return nil
        }

        var rows: [OutboxRow] = []
        let read = query("SELECT \(wanted.joined(separator: ", ")) FROM \(table)") { statement in
            var row = OutboxRow()
            for (index, column) in wanted.enumerated() {
                let i = Int32(index)
                switch column {
                case "ZRECORDID": row.recordID = uuid(statement, i)
                case "ZRECORDTYPE": row.recordType = text(statement, i) ?? ""
                case "ZPARENTID": row.parentID = uuid(statement, i)
                case "ZBASEVERSION": row.baseVersion = Int(sqlite3_column_int64(statement, i))
                case "ZFIELDSJSON": row.fieldsJSON = text(statement, i) ?? ""
                case "ZISDELETE": row.isDelete = sqlite3_column_int64(statement, i) != 0
                case "ZCASCADEJSON": row.cascadeJSON = text(statement, i) ?? "[]"
                case "ZFIRSTDIRTIEDAT": row.firstDirtiedAt = date(statement, i) ?? .distantPast
                case "ZLASTDIRTIEDAT": row.lastDirtiedAt = date(statement, i) ?? .distantPast
                case "ZOPID": row.opID = uuid(statement, i)
                case "ZATTEMPTS": row.attempts = Int(sqlite3_column_int64(statement, i))
                case "ZLASTERROR": row.lastError = text(statement, i) ?? ""
                default: break
                }
            }
            rows.append(row)
        }
        return read ? rows : nil
    }

    nonisolated private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    /// Core Data keeps a UUID as a 16-byte blob; a text form is accepted too.
    nonisolated private static func uuid(_ statement: OpaquePointer, _ index: Int32) -> UUID? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_BLOB:
            guard sqlite3_column_bytes(statement, index) == 16,
                  let bytes = sqlite3_column_blob(statement, index) else { return nil }
            return NSUUID(uuidBytes: bytes.assumingMemoryBound(to: UInt8.self)) as UUID
        case SQLITE_TEXT:
            return text(statement, index).flatMap(UUID.init(uuidString:))
        default:
            return nil
        }
    }

    /// Core Data keeps a Date as seconds since 2001-01-01.
    nonisolated private static func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }
}

import SwiftUI
import Combine

extension Notification.Name {
    /// A store recovery happened — posted by `StoreRecovery.openContainer` so
    /// the root alert reacts whenever it happens, not just at launch.
    static let mbStoreRecovered = Notification.Name("mb.storeRecovered")
}

/// Root-level alert for a store recovery, per the "every edge case: alert AND
/// log" rule — the log lines above are the developer half, this is the person's.
/// Listens as well as looks: the launch container recovers BEFORE this mounts
/// (`.onAppear` catches it), the per-user store recovers at sign-in, long after
/// (`.onReceive` catches that one).
struct StoreRecoveryAlert: ViewModifier {
    @State private var notice: StoreRecovery.Notice?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: presentIfPending)
            .onReceive(NotificationCenter.default.publisher(for: .mbStoreRecovered)) { _ in
                presentIfPending()
            }
            .alert(title, isPresented: $isPresented) {
                Button(mbLoc("OK"), role: .cancel) {}
            } message: {
                Text(message)
            }
    }

    private func presentIfPending() {
        guard !isPresented, let pending = StoreRecovery.consumeNotice() else { return }
        notice = pending
        isPresented = true
    }

    private var title: String { Self.title(for: notice ?? .rebuilt) }
    private var message: String { Self.message(for: notice ?? .rebuilt) }

    static func title(for notice: StoreRecovery.Notice) -> String {
        switch notice {
        case .memoryOnly: mbLoc("This device can’t save right now")
        case .storageFull: mbLoc("Storage is full")
        case .syncRepaired: mbLoc("Sync was repaired")
        case .saveFailed: mbLoc("That change didn’t save")
        case .rebuilt, .rebuiltKeepingChanges, .rebuiltChangesMayBeMissing: mbLoc("Your local copy was rebuilt")
        }
    }

    /// Promises a re-download only for what the server has: unsent changes are named apart.
    static func message(for notice: StoreRecovery.Notice) -> String {
        switch notice {
        case .memoryOnly:
            mbLoc("The app couldn’t use this device’s storage, so changes won’t be kept after you close it. Restarting the device usually fixes this.")
        case .storageFull:
            mbLoc("This device is out of space, so My Business couldn’t open its saved data. Nothing was deleted. Free up space, then close and reopen the app. Until then, changes won’t be kept after you close it.")
        case .syncRepaired:
            mbLoc("Saving hit a snag last time, so sync restarted itself. Everything saves and re-uploads automatically — nothing for you to do.")
        case .saveFailed:
            mbLoc("Your device couldn’t write the change. Free up storage if it’s low, then open the record and try again.")
        case .rebuilt:
            mbLoc("The saved copy on this device couldn’t be read, so it was reset. Your business data re-downloads from your Gold Life account when you sign in.")
        case .rebuiltKeepingChanges(let count):
            count == 1
                ? mbLoc("The saved copy on this device couldn’t be read, so it was reset. Your business data re-downloads from your Gold Life account. The 1 change that wasn’t backed up yet was kept on this device.")
                : mbLoc("The saved copy on this device couldn’t be read, so it was reset. Your business data re-downloads from your Gold Life account. The \(count) changes that weren’t backed up yet were kept on this device.")
        case .rebuiltChangesMayBeMissing:
            mbLoc("The saved copy on this device couldn’t be read, so it was reset. Your backed-up business data re-downloads from your Gold Life account, but changes this device hadn’t backed up yet may be missing.")
        }
    }
}
