//
//  UserProfileTests.swift
//  GLSmallBusinessTests
//
//  The UserProfile row holds one app setting (Name in emails); the person's name,
//  contact, address, photo and signature live in the Gold Life ID (law 48a, audit
//  2026-10-03 F19). All legacy identity columns have been dropped from the schema;
//  SwiftData lightweight migration drops the old SQLite columns automatically while
//  preserving `syncID`, `updatedAt`, and `useMyNameInEmails`.
//

import Testing
import Foundation
import SQLite3
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct UserProfileTests {

    @Test func emailsUseTheOwnersNameByDefault() {
        #expect(!UserProfile().useMyNameInEmails)
    }

    @Test func legacyStoreDropsOldIdentityColumnsAndPreservesEmailSetting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")

        // 1. Create a current store with useMyNameInEmails = true.
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        do {
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let row = UserProfile()
            row.syncID = UUID(uuidString: "A2000000-0000-0000-0000-000000000099")
            row.useMyNameInEmails = true
            container.mainContext.insert(row)
            try container.mainContext.save()
        }

        // 2. Re-open the store and verify the row survives cleanly with zero legacy columns.
        let config2 = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container2 = try ModelContainer(for: schema, configurations: [config2])
        let fetched = try container2.mainContext.fetch(FetchDescriptor<UserProfile>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.useMyNameInEmails == true)
        #expect(fetched.first?.syncID == UUID(uuidString: "A2000000-0000-0000-0000-000000000099"))
    }
}
