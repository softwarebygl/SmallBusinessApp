//
//  ModelContextSaveTests.swift
//  GLSmallBusinessTests
//
//  The saveChanges() helper: it no-ops when there's nothing to save (the hasChanges guard) and
//  commits when there is. The catch branch only fires on a real save failure, which a valid
//  in-memory store can't be made to throw, so it stays exercised only in production.
//

import Testing
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ModelContextSaveTests {

    @Test func noOpsWhenCleanAndCommitsWhenDirty() throws {
        let context = ModelContext(try TestStore.makeContainer())

        // Nothing pending → the guard returns early without touching the store.
        context.saveChanges()

        context.insert(Customer(firstName: "Test", lastName: "Save"))
        #expect(context.hasChanges)

        context.saveChanges()
        #expect(!context.hasChanges)   // committed

        // Clean again → guard path once more, still no throw.
        context.saveChanges()
        #expect(!context.hasChanges)
    }
}
