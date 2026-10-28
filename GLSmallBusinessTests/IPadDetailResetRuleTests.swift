//
//  IPadDetailResetRuleTests.swift
//  GLSmallBusinessTests
//
//  F23: when a person is picked in the iPad middle column while a screen (Edit, Log Hours,
//  More Info) is pushed over the current person's detail, the split re-keys so that screen
//  closes. These pin the decision; IPadSelectionResetUITests drives the real gesture on iPad.
//

import Testing
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct IPadDetailResetRuleTests {
    private func twoPeople() throws -> (PersistentIdentifier, PersistentIdentifier) {
        let context = try TestStore.makeContainer().mainContext
        let a = TS.customer(first: "Ann", last: "A", in: context)
        let b = TS.customer(first: "Ben", last: "B", in: context)
        try context.save()
        return (a.persistentModelID, b.persistentModelID)
    }

    @Test func pickingAnotherPersonOverAPushedScreenRebuilds() throws {
        let (a, b) = try twoPeople()
        #expect(IPadRootSplitView.pickRebuildsDetail(showing: a, picked: b, visibleRoot: nil))
    }

    @Test func pickingAnotherPersonWhileTheirDetailIsUncoveredDoesNot() throws {
        let (a, b) = try twoPeople()
        #expect(!IPadRootSplitView.pickRebuildsDetail(showing: a, picked: b, visibleRoot: a))
    }

    @Test func reTappingTheSamePersonOrStartingFromNothingDoesNot() throws {
        let (a, b) = try twoPeople()
        #expect(!IPadRootSplitView.pickRebuildsDetail(showing: a, picked: a, visibleRoot: nil))
        #expect(!IPadRootSplitView.pickRebuildsDetail(showing: nil, picked: b, visibleRoot: nil))
    }

    /// The old root can report its disappearance after the new one appeared; the stale report
    /// must not read as "covered" (DetailRootIdentity clears only its own id).
    @Test func aCoveredRootIsOnlyTheShownPerson() throws {
        let (a, b) = try twoPeople()
        #expect(IPadRootSplitView.pickRebuildsDetail(showing: b, picked: a, visibleRoot: a),
                "a root that is not the shown person's means the shown one is covered")
    }
}
