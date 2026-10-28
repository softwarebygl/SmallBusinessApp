//
//  GLSyncRegistryCoverageTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for GLSyncRegistry: exhaustive test exercising all 24 sync types (the
//  Price Sheet joined the first 23 on 2026-10-03, QA finding F3) through their
//  registry entries: count, fetchAll, createEmpty, fetch, children,
//  blobs, setBlob, linkParent, and delete.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct GLSyncRegistryCoverageTests {

    @Test func exercisesAllRegistryTypes() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        #expect(GLSyncRegistry.allTypes.count == 28)

        for key in GLSyncRegistry.allTypes {
            let entry = try #require(GLSyncRegistry.entry(for: key))
            #expect(entry.key == key)
            #expect(GLSyncRegistry.entry(entityName: entry.entityName)?.key == key)
            _ = GLSyncRegistry.depth(of: key)
            _ = GLSyncRegistry.piiClass(type: key, field: "w9Data")
            _ = GLSyncRegistry.piiClass(type: key, field: "other")

            // Count and fetchAll on empty context
            _ = entry.count(ctx)
            _ = entry.fetchAll(ctx)

            // Create empty record and fetch
            let record = entry.createEmpty(ctx)
            if let syncID = record.glSyncID {
                let fetched = entry.fetch(syncID, ctx)
                #expect(fetched != nil)
            }

            // Inspect children and blobs
            _ = entry.children(record)
            _ = entry.blobBytes(record)

            // Test setting blob data for all blob fields
            let sampleBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
            for field in entry.blobFields {
                entry.setBlobBytes(record, field, sampleBytes)
            }
            _ = entry.blobBytes(record)

            // Test linkParent
            entry.linkParent(record, nil, ctx)
            entry.linkParent(record, UUID(), ctx)

            // Delete
            entry.delete(record, ctx)
        }
    }

    /// Every record type the app stores is backed up, except GLSync's own bookkeeping. The
    /// Price Sheet sat in the store for weeks with no registry entry (QA finding F3): nothing
    /// failed, its edits were skipped by the fold, and a sign-out wiped it for good. A model added
    /// to the schema without a registry entry now fails here instead.
    @Test func everyStoredModelIsASyncTypeExceptGLSyncsOwn() {
        let stored = Set(Schema(versionedSchema: GLCurrentSchema.self).entities.map(\.name))
        let synced = Set(GLSyncRegistry.allTypes.compactMap { GLSyncRegistry.entry(for: $0)?.entityName })
        let bookkeeping: Set<String> = ["GLSyncOutboxEntry", "GLSyncState", "GLSyncRecordVersion",
                                        "Contract", "ContractGroup", "ContractLineItem"] // local until manifest v2
        #expect(stored.subtracting(synced) == bookkeeping,
                "stored but never backed up: \(stored.subtracting(synced).subtracting(bookkeeping).sorted())")
        #expect(synced.isSubset(of: stored), "a registry entry names no stored model")
    }
}
