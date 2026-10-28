//
//  GLSyncStatusTests.swift
//  GLSmallBusinessTests
//
//  What the Settings Backup row says, and the one-time queue of the server's refusals
//  (QA 2026-10-03 F87, F88).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct GLSyncStatusTests {

    private func english<T>(_ body: () throws -> T) rethrows -> T {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .en
        return try body()
    }

    /// F88. An unsent edit outranks the last backup time: a time would say it is backed up.
    @Test func theBackupRowNamesWhatIsStillOnThisDevice() {
        english {
            let earlier = Date().addingTimeInterval(-60)
            typealias Changes = MBSessionPurge.UnsyncedChanges
            #expect(GLSyncBackupRow.detail(lastSyncAt: earlier, changes: Changes(waiting: 1))
                    == "1 change waiting")
            #expect(GLSyncBackupRow.detail(lastSyncAt: nil, changes: Changes(waiting: 3))
                    == "3 changes waiting")
            #expect(GLSyncBackupRow.detail(lastSyncAt: earlier, changes: Changes(waiting: 2, parked: 1))
                    == "1 change not backed up")
            #expect(GLSyncBackupRow.detail(lastSyncAt: earlier, changes: Changes(parked: 4))
                    == "4 changes not backed up")
            #expect(GLSyncBackupRow.detail(lastSyncAt: nil, changes: Changes()) == "Not yet backed up")
            let time = GLSyncBackupRow.detail(lastSyncAt: earlier, changes: Changes())
            #expect(!time.isEmpty && !time.contains("change"), "a drained outbox shows the time, got \(time)")
        }
    }

    /// The checkmark is a claim too: only a drained outbox with a real backup time earns it.
    @Test func theCheckmarkOnlyShowsForARealBackup() {
        typealias Changes = MBSessionPurge.UnsyncedChanges
        let earlier = Date().addingTimeInterval(-60)
        #expect(GLSyncBackupRow.symbol(lastSyncAt: earlier, changes: Changes()) == "checkmark.icloud")
        #expect(GLSyncBackupRow.symbol(lastSyncAt: earlier, changes: Changes(waiting: 1)) == "icloud")
        #expect(GLSyncBackupRow.symbol(lastSyncAt: nil, changes: Changes()) == "icloud")
        #expect(GLSyncBackupRow.symbol(lastSyncAt: earlier, changes: Changes(parked: 1)) == "exclamationmark.icloud")
    }

    @Test func theSpanishRowIsTranslated() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        #expect(GLSyncBackupRow.detail(lastSyncAt: nil, changes: .init(waiting: 1)) == "1 cambio pendiente")
        #expect(GLSyncBackupRow.detail(lastSyncAt: nil, changes: .init(parked: 2)) == "2 cambios sin respaldar")
    }

    /// F87. Each sentence once: repeats collapse, and taking one removes it.
    @Test func eachRefusalSentenceIsShownOnce() {
        let status = GLSyncStatus.shared
        status.clearMessages()
        defer { status.clearMessages() }

        status.post(["Refused A", "Refused A", "Refused B"])
        status.post(["Refused A"])
        #expect(status.pendingMessages == ["Refused A", "Refused B"])

        #expect(status.takeMessage() == "Refused A")
        #expect(status.takeMessage() == "Refused B")
        #expect(status.takeMessage() == nil)
    }

    @Test func signingOutForgetsThePreviousPersonsRefusals() {
        let status = GLSyncStatus.shared
        status.post(["Someone else's refusal"])
        status.clearMessages()
        #expect(status.pendingMessages.isEmpty)
    }
}
