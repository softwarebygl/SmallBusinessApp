//
//  SaveOnceLatchTests.swift
//  GLSmallBusinessTests
//
//  The duplicate-payment guard behind SaveOnceButton (SaveOnceButton.swift
//  `SaveOnceLatch`): a committing action runs exactly once, and a refusing action
//  (the read-only gate said no) re-arms the latch so the retry the alert invites
//  actually works.
//

import Testing
@testable import GLSmallBusiness

@MainActor
struct SaveOnceLatchTests {

    @Test func aCommittingActionRunsOnceAndTheSecondFireIsIgnored() {
        var latch = SaveOnceLatch()
        var runs = 0
        #expect(!latch.fired)

        #expect(latch.fire { runs += 1; return true })
        #expect(runs == 1)
        #expect(latch.fired)

        // The fast double-tap during the dismiss animation: the action must not run again.
        #expect(!latch.fire { runs += 1; return true })
        #expect(runs == 1)
        #expect(latch.fired)
    }

    @Test func aRefusingActionLeavesTheLatchArmedForTheRetry() {
        var latch = SaveOnceLatch()
        var runs = 0

        #expect(!latch.fire { runs += 1; return false })
        #expect(runs == 1)
        #expect(!latch.fired, "a refused save must not leave the button dead behind the alert")

        // The retry runs the action again, and this time it commits.
        #expect(latch.fire { runs += 1; return true })
        #expect(runs == 2)
        #expect(latch.fired)

        // …and once committed it stays committed.
        #expect(!latch.fire { runs += 1; return true })
        #expect(runs == 2)
    }

    @Test func firedReflectsEveryTransition() {
        var latch = SaveOnceLatch()
        #expect(!latch.fired)
        latch.fire { false }
        #expect(!latch.fired)
        latch.fire { true }
        #expect(latch.fired)
        latch.fire { false }   // ignored — a fired latch never calls the action, so it cannot re-arm
        #expect(latch.fired)
    }
}
