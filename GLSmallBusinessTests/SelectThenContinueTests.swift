//
//  SelectThenContinueTests.swift
//  GLSmallBusinessTests
//
//  The pure rules behind law 63 in My Business (audit 2026-10-03 F135); the taps themselves are
//  pinned by GLSmallBusinessUITests/SelectThenContinueUITests.
//    - New estimate / New invoice: Continue opens the form for the SELECTED customer, and only
//      while that customer is still in the list (else it stays disabled).
//    - Add to Project: Done applies the selected project; an unchanged choice applies nothing.
//

import Testing
import SwiftUI
import SwiftData
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct SelectThenContinueTests {

    private typealias Picker = PickCustomerThenScreen<Text>

    // MARK: - Customer picker: Continue

    @Test func continueWaitsForAChoice() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let reed = TS.customer(in: ctx)
        try ctx.save()
        #expect(Picker.continueTarget(selectedID: nil, in: [reed]) == nil, "Nothing chosen: Continue is disabled.")
    }

    @Test func continueOpensTheSelectedCustomer() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let reed = TS.customer(in: ctx)
        let carter = TS.customer(first: "Danielle", last: "Carter", in: ctx)
        try ctx.save()
        let target = Picker.continueTarget(selectedID: carter.persistentModelID, in: [reed, carter])
        #expect(target?.persistentModelID == carter.persistentModelID)
    }

    @Test func continueIsDisabledWhenTheChosenCustomerIsGone() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let reed = TS.customer(in: ctx)
        let carter = TS.customer(first: "Danielle", last: "Carter", in: ctx)
        try ctx.save()
        // Carter was chosen, then deleted elsewhere: the list no longer has him.
        #expect(Picker.continueTarget(selectedID: carter.persistentModelID, in: [reed]) == nil)
    }

    // MARK: - Add to Project: Done

    @Test func doneAppliesANewlySelectedProject() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let kitchen = Project(name: "Kitchen")
        let bath = Project(name: "Bath")
        ctx.insert(kitchen); ctx.insert(bath)
        try ctx.save()
        let applied = AddToProjectSheet.projectToApply(selectedID: bath.persistentModelID,
                                                       currentID: kitchen.persistentModelID,
                                                       in: [kitchen, bath])
        #expect(applied?.persistentModelID == bath.persistentModelID)
        let fromNone = AddToProjectSheet.projectToApply(selectedID: kitchen.persistentModelID,
                                                        currentID: nil, in: [kitchen, bath])
        #expect(fromNone?.persistentModelID == kitchen.persistentModelID)
    }

    @Test func doneWithTheSameProjectAppliesNothing() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let kitchen = Project(name: "Kitchen")
        ctx.insert(kitchen)
        try ctx.save()
        #expect(AddToProjectSheet.projectToApply(selectedID: kitchen.persistentModelID,
                                                 currentID: kitchen.persistentModelID,
                                                 in: [kitchen]) == nil)
        #expect(AddToProjectSheet.projectToApply(selectedID: nil, currentID: nil, in: [kitchen]) == nil)
    }

    @Test func doneNeverAppliesAProjectThatIsGone() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let kitchen = Project(name: "Kitchen")
        let bath = Project(name: "Bath")
        ctx.insert(kitchen); ctx.insert(bath)
        try ctx.save()
        #expect(AddToProjectSheet.projectToApply(selectedID: bath.persistentModelID,
                                                 currentID: nil, in: [kitchen]) == nil)
    }
}
