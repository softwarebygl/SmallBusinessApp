//
//  MBHostDataEraseTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F1: My Business's own row on the Gold Life ID deletion screen erases My
//  Business's data in place (`MBHostDataErase`, handed to the GoldLifeID package as
//  `GoldLifeIDConfig.eraseHostAppData`). These pin the order that keeps the erase from undoing
//  itself (sync stops BEFORE the backup is erased, so nothing re-uploads) and that the local copy
//  really empties without queueing a single delete for the server.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MBHostDataEraseTests {

    private struct Failed: Error {}

    /// Records each step in the order the erase runs it.
    private final class Log {
        var steps: [String] = []
    }

    private func steps(_ log: Log, backupFails: Bool = false, pauseFails: Bool = false) -> MBHostDataErase.Steps {
        MBHostDataErase.Steps(
            pauseSync: {
                log.steps.append("pauseSync")
                if pauseFails { throw MBHostDataErase.SyncStillRunning() }
            },
            deleteBackup: {
                log.steps.append("deleteBackup")
                if backupFails { throw Failed() }
            },
            resumeSync: { log.steps.append("resumeSync") },
            endSync: { log.steps.append("endSync") },
            wipeLocalCopy: { log.steps.append("wipeLocalCopy") })
    }

    @Test func syncStopsBeforeTheBackupIsErasedAndTheLocalCopyGoesLast() async throws {
        let log = Log()
        try await MBHostDataErase.erase(using: steps(log))
        #expect(log.steps == ["pauseSync", "deleteBackup", "endSync", "wipeLocalCopy"])
    }

    /// A backup erase that did not finish changes nothing on this iPhone: sync starts again, the
    /// local copy stays, and the error reaches the screen (which says the app still has the data).
    @Test func aFailedBackupEraseKeepsEverythingAndSaysSo() async {
        let log = Log()
        await #expect(throws: Failed.self) {
            try await MBHostDataErase.erase(using: steps(log, backupFails: true))
        }
        #expect(log.steps == ["pauseSync", "deleteBackup", "resumeSync"])
    }

    /// A sync cycle that would not stop in time stops the erase instead: the backup is never erased
    /// under a cycle that is still pushing (its push would land after DELETE /account and put records
    /// back on the server), and nothing on this iPhone changes.
    @Test func aSyncThatWontStopKeepsTheBackupAndTheLocalCopy() async {
        let log = Log()
        await #expect(throws: MBHostDataErase.SyncStillRunning.self) {
            try await MBHostDataErase.erase(using: steps(log, pauseFails: true))
        }
        #expect(log.steps == ["pauseSync", "resumeSync"])
    }

    /// C17 review 2026-10-04: the store emptied under the live tabs and pushed details and the app
    /// trapped. The wipe now runs only while the signed-in screens are DOWN, and they come back
    /// (remounted) once it is done, with Delete Account reopened for step two.
    @Test func theLocalWipeRunsOnlyWithTheScreensDown() async {
        let remount = MBStoreRemount.shared
        let before = remount.completedWipes
        #expect(!remount.screensDown)
        var downDuringWipe: Bool?
        await remount.wipeWithScreensDown { downDuringWipe = remount.screensDown }
        #expect(downDuringWipe == true, "the wipe ran while the signed-in screens were still up")
        #expect(!remount.screensDown, "the screens must come back after the wipe")
        #expect(remount.completedWipes == before + 1, "Delete Account is reopened once per finished wipe")
    }

    /// The local wipe leaves no record of ANY model type (sync bookkeeping included, so the next
    /// launch starts a fresh, empty sync), and queues no delete op: the server copy is already gone.
    @Test func theLocalWipeEmptiesEveryModelAndQueuesNothing() throws {
        let world = try TestStore.demoWorld()
        let context = world.context
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) > 0, "the demo world should seed customers")
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) > 0, "the demo world should seed invoices")

        MBHostDataErase.wipeEveryRecord(in: context)

        func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? context.fetchCount(FetchDescriptor<T>())) ?? -1 }
        for type in GLCurrentSchema.models {
            #expect(count(type) == 0, "\(type) still has rows after the wipe")
        }
        #expect(count(GLSyncOutboxEntry.self) == 0, "the wipe queued delete ops for a server copy that is already gone")
        #expect(!context.hasChanges, "the wipe must be saved, not left pending")
    }
}
