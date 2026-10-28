//
//  TestStore.swift
//  GLSmallBusinessTests — Harness
//
//  THE one way a test gets a ModelContainer. Every container handed out here is
//  isolated from the host app's (CloudKit off), retained for the life of the test
//  process, and has autosave OFF. All three are load-bearing — see the notes inside
//  `retain(_:)` and project_swiftdata_test_process_trap.
//

import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
enum TestStore {
    /// See `retain(_:)` — every container handed out is kept alive deliberately.
    private static var retained: [ModelContainer] = []

    /// A throwaway in-memory store for the current schema. CloudKit is off so it doesn't collide
    /// with the host app's container that already exists in the test process.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try retain(ModelContainer(for: schema, configurations: config))
    }

    /// An on-disk store for the current schema, under a fresh per-call directory in the
    /// temporary folder (`GLTests/<UUID>/Store.store`) so no two tests ever share a file. For
    /// the tests that need real persistence — reopen-after-close, migration, persistent history.
    /// Retained and autosave-off exactly like `makeContainer()`.
    static func makeDiskContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GLTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema,
                                        url: directory.appendingPathComponent("Store.store"),
                                        cloudKitDatabase: .none)
        return try retain(ModelContainer(for: schema, configurations: config))
    }

    /// A fresh in-memory container seeded with the demo dataset, with every seeded record
    /// already fetched in a deterministic order — see `DemoWorld`.
    static func demoWorld() throws -> DemoWorld {
        try DemoWorld(seeding: makeContainer())
    }

    private static func retain(_ container: ModelContainer) -> ModelContainer {
        // Held for the life of the test process. A SwiftUI view hosted by a rendering
        // test registers SwiftData observers that are NOT reliably released when the
        // view goes away — SwiftUI decides when the graph actually dies. When a later
        // test saves, SwiftData delivers that change to the surviving observer, and if
        // the observer's own container has been deallocated it traps (SIGTRAP). Keeping
        // every container alive means an observer can always resolve its container, so
        // the trap has nothing to fire on. These are in-memory (or temp-folder) stores
        // and go away with the process. (Tearing the window down, which the host helpers
        // also do, is necessary but NOT sufficient: the release is asynchronous, so a
        // stale observer can still be alive at the moment the next test saves.)
        retained.append(container)
        // Autosave OFF. SwiftData drives autosave from a run-loop timer, and every
        // rendering test pumps the run loop — so a timer belonging to a container whose
        // test finished long ago fires mid-run, posts a change notification, and traps
        // (SIGTRAP) inside a SwiftUI SwiftData observer whose own container is already
        // gone. It only ever showed up in full-suite runs, because it needs one suite's
        // leftover timer to land while another suite's views are alive. Tests save
        // explicitly where they mean to.
        container.mainContext.autosaveEnabled = false
        return container
    }
}
