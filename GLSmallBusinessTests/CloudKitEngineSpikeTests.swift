//
//  CloudKitEngineSpikeTests.swift
//  GLSmallBusinessTests
//
//  Spike for the CloudKit-sharing rearchitecture (route R1): sharing requires the sync engine to be an
//  NSPersistentCloudKitContainer (Core Data) rather than SwiftData's cloudKitDatabase:.automatic, which
//  has no CKShare support. The make-or-break question — answered here with NO CloudKit and NO real data —
//  is whether a Core Data stack built from the SwiftData schema can open and read the SAME on-disk store
//  SwiftData created. If yes, the two engines can coexist on one file and the migration is viable.
//

import Testing
import Foundation
import SwiftData
import CoreData
@testable import GLSmallBusiness

@MainActor
struct CloudKitEngineSpikeTests {

    /// The SwiftData→Core Data bridge produces a managed-object model covering every app model. This is
    /// the exact model an NSPersistentCloudKitContainer would be built with for sharing.
    @Test func bridgeModelCoversEveryEntity() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: GLSchemaV1.models))
        let names = Set(model.entities.compactMap(\.name))
        for expected in ["Customer", "Invoice", "Estimate", "ScheduledJob", "JobAttachment",
                         "Receipt", "Employee", "Subcontractor", "Project",
                         "BusinessProfile", "UserProfile"] {
            #expect(names.contains(expected), "bridge model is missing entity \(expected)")
        }
        #expect(model.entities.count == GLSchemaV1.models.count)
        // The Customer entity carries its stored attributes (a representative shape check).
        let customer = try #require(model.entitiesByName["Customer"])
        #expect(customer.attributesByName["firstName"] != nil)
        #expect(customer.attributesByName["lastName"] != nil)
    }

    /// The migration-critical direction: SwiftData writes a record to a store file, then a Core Data
    /// stack (the NSPCKC base) opens the SAME file and reads it back. Proves NSPCKC can ADOPT SwiftData's
    /// existing store rather than needing a fresh one.
    @Test func coreDataOpensAndReadsSwiftDataStore() throws {
        let url = URL.temporaryDirectory.appending(path: "spike-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let sdSchema = Schema(versionedSchema: GLSchemaV1.self)

        // 1. SwiftData creates the store and writes a Customer (this is how the live store exists today).
        do {
            let config = ModelConfiguration(schema: sdSchema, url: url, cloudKitDatabase: .none)
            let sd = try ModelContainer(for: sdSchema, configurations: config)
            let customer = Customer(firstName: "Spike", lastName: "Adoption")
            sd.mainContext.insert(customer)
            try sd.mainContext.save()
        }   // SwiftData container deallocates, closing the file.

        // 2. A Core Data stack built from the bridge model opens the SAME file and reads the record.
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: GLSchemaV1.models))
        let coreData = NSPersistentContainer(name: "GLSpike", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        coreData.persistentStoreDescriptions = [description]

        var loadError: Error?
        coreData.loadPersistentStores { _, error in loadError = error }
        #expect(loadError == nil, "Core Data couldn't open SwiftData's store: \(String(describing: loadError))")

        let request = NSFetchRequest<NSManagedObject>(entityName: "Customer")
        let rows = try coreData.viewContext.fetch(request)
        #expect(rows.contains { ($0.value(forKey: "firstName") as? String) == "Spike" },
                "Core Data opened the store but didn't read SwiftData's Customer")
    }
}
