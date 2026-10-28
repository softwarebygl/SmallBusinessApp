//
//  RelockPolicyTests.swift
//  GLSmallBusinessTests
//
//  The warm-relock decision (GatePhase.swift `GLRelockPolicy.shouldRelock`): re-lock
//  only when the lock is on AND the app sat in the background for at least the grace
//  window. Pinned so the sixty-second ruling (2026-08-31) cannot drift by a boundary.
//

import Testing
import Foundation
import GoldLifeUI
@testable import GLSmallBusiness

struct RelockPolicyTests {

    /// Whole-second reference dates so the interval math is exact, not float-fuzzy.
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let grace: TimeInterval = 60

    @Test func neverBackgroundedNeverRelocks() {
        #expect(!GLRelockPolicy.shouldRelock(backgroundedAt: nil, now: now, grace: grace, requireLock: true))
    }

    @Test func justUnderTheGraceWindowStaysUnlocked() {
        let since = now.addingTimeInterval(-59.999)
        #expect(!GLRelockPolicy.shouldRelock(backgroundedAt: since, now: now, grace: grace, requireLock: true))
    }

    @Test func exactlyTheGraceWindowRelocks() {
        let since = now.addingTimeInterval(-60)
        #expect(GLRelockPolicy.shouldRelock(backgroundedAt: since, now: now, grace: grace, requireLock: true))
    }

    @Test func lockOffNeverRelocksHoweverLongItWasAway() {
        let since = now.addingTimeInterval(-3600)
        #expect(!GLRelockPolicy.shouldRelock(backgroundedAt: since, now: now, grace: grace, requireLock: false))
    }

    /// The DEBUG `-mb.relockGrace` override path: the policy honours whatever grace it is handed.
    @Test func aOneSecondGraceRelocksAfterOneSecond() {
        let since = now.addingTimeInterval(-1)
        #expect(GLRelockPolicy.shouldRelock(backgroundedAt: since, now: now, grace: 1, requireLock: true))
        #expect(!GLRelockPolicy.shouldRelock(backgroundedAt: now.addingTimeInterval(-0.5), now: now,
                                           grace: 1, requireLock: true))
    }
}

/// iPad with two My Business windows (QA 2026-10-03, F25): the relock covered ONE window and
/// left the other one usable, and unlocking that one window left the other's relock latched off.
/// The lock is now one app-wide state with one cover per window; these pin the bookkeeping that
/// GLLockWindow applies to real scenes (ids stand in for scene-session ids).
struct MultiWindowLockTests {

    @Test func twoWindowsGetTwoCovers() {
        var ledger = GLLockCoverLedger()
        let added = ledger.lock(foreground: ["A", "B"])
        #expect(added == ["A", "B"])
        #expect(ledger.covered == ["A", "B"])
        #expect(ledger.isLocked)
    }

    @Test func unlockClearsBothCovers() {
        var ledger = GLLockCoverLedger()
        _ = ledger.lock(foreground: ["A", "B"])
        let cleared = ledger.unlock()
        #expect(cleared == ["A", "B"])
        #expect(ledger.covered.isEmpty)
        #expect(!ledger.isLocked)
    }

    /// The second window came back after the first one locked: it is covered as it comes forward.
    @Test func aWindowThatComesForwardWhileLockedIsCovered() {
        var ledger = GLLockCoverLedger()
        _ = ledger.lock(foreground: ["A"])
        let first = ledger.sceneCameForward("B")
        let again = ledger.sceneCameForward("B")
        #expect(first)
        #expect(!again, "one cover per window, never two")
        #expect(ledger.covered == ["A", "B"])
    }

    @Test func aWindowComingForwardWhileUnlockedIsLeftAlone() {
        var ledger = GLLockCoverLedger()
        let beforeAnyLock = ledger.sceneCameForward("A")
        #expect(!beforeAnyLock)
        _ = ledger.lock(foreground: ["A"])
        _ = ledger.unlock()
        let afterUnlock = ledger.sceneCameForward("A")
        #expect(!afterUnlock)
        #expect(ledger.covered.isEmpty)
    }

    /// A second window's lock call is no longer dropped: it adds only the window not yet covered.
    @Test func aSecondLockCallCoversOnlyTheNewWindow() {
        var ledger = GLLockCoverLedger()
        _ = ledger.lock(foreground: ["A"])
        let added = ledger.lock(foreground: ["A", "B"])
        #expect(added == ["B"])
    }

    @Test func aClosedWindowIsForgotten() {
        var ledger = GLLockCoverLedger()
        _ = ledger.lock(foreground: ["A", "B"])
        ledger.sceneClosed("B")
        let cleared = ledger.unlock()
        #expect(cleared == ["A"])
    }

    /// One lock for the whole app: every window reads the same state, a second relock from
    /// another window raises nothing new, and one unlock clears it for every window.
    @Test func everyWindowSharesOneLock() {
        var shown: [Bool] = []
        let lock = GLWarmLock { isShown, _ in shown.append(isShown) }
        lock.lock()
        lock.lock()   // the other window's return past the grace window
        #expect(lock.isLocked)
        #expect(shown == [true])
        lock.unlock()
        #expect(!lock.isLocked)
        #expect(shown == [true, false])
        lock.unlock()
        #expect(shown == [true, false])
    }

    /// The covers' Unlock is wired to the shared lock, so unlocking any window clears it.
    @Test func theCoversUnlockClearsTheSharedLock() {
        var unlockFromCover: (() -> Void)?
        let lock = GLWarmLock { isShown, onUnlock in if isShown { unlockFromCover = onUnlock } }
        lock.lock()
        unlockFromCover?()
        #expect(!lock.isLocked)
    }
}
