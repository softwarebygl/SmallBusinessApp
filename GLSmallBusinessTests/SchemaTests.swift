//
//  SchemaTests.swift
//  GLSmallBusinessTests
//
//  Guards that the full app schema is internally valid — it builds a ModelContainer over GLCurrentSchema
//  in memory (no persistent store, no CloudKit), so a failure here means the @Model definitions
//  themselves are wrong (vs. a stale on-disk store on a device).
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct SchemaTests {
    @Test func fullSchemaBuildsInMemory() throws {
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        _ = try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: config)
    }
}
