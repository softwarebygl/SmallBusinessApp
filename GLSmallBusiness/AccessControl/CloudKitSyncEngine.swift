//
//  CloudKitSyncEngine.swift
//  GLSmallBusiness
//
//  The sync engine for the (in-progress) CloudKit SHARING feature. SwiftData's `cloudKitDatabase:.automatic`
//  has NO CKShare support, so sharing requires an `NSPersistentCloudKitContainer` (Core Data) to drive
//  CloudKit while SwiftData keeps serving the UI on the SAME on-disk store — "route R1", proven viable by
//  `CloudKitEngineSpikeTests` (bridge model covers every entity; Core Data adopts SwiftData's store; both
//  engines coexist concurrently).
//
//  Behind a DEBUG flag, default OFF. The proven `.automatic` path stays the live engine until this is
//  validated end-to-end against real CloudKit on a throwaway Apple ID. Never on in Release builds.
//

import Foundation
import SwiftData
import CoreData

/// Pure infrastructure — `nonisolated` so it can build containers from the App's bootstrap without
/// pinning to the main actor (the target defaults to MainActor isolation).
nonisolated enum CloudKitSyncEngine {
    static let containerIdentifier = "iCloud.com.evolvedbygl.GLSmallBusiness"

    /// Opt-in for testing: launch with `-useCloudKitSharingEngine YES` (sets the matching UserDefaults
    /// key) to drive sync via NSPersistentCloudKitContainer instead of SwiftData's `.automatic`.
    static var isEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "useCloudKitSharingEngine")
        #else
        return false
        #endif
    }

    /// Retained for the app's lifetime so CloudKit mirroring keeps running; the UI uses the SwiftData
    /// container returned by `makeContainer`. Set once at startup.
    nonisolated(unsafe) private static var mirror: NSPersistentCloudKitContainer?

    /// SwiftData's default on-disk store. Both engines target this file so existing data is ADOPTED,
    /// not re-created. (SwiftData names its default store `default.store` in Application Support.)
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Builds a SwiftData `ModelContainer` whose underlying store is driven by an
    /// `NSPersistentCloudKitContainer` (so CKShare can be added later). Throws if the Core Data stack
    /// can't open the store, letting the caller fall back to the proven `.automatic` path.
    static func makeContainer(schema: Schema) throws -> ModelContainer {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: GLSchemaV1.models) else {
            throw CocoaError(.persistentStoreOpen)
        }

        let cloud = NSPersistentCloudKitContainer(name: "GLSmallBusiness", managedObjectModel: model)
        let privateStore = NSPersistentStoreDescription(url: defaultStoreURL)
        privateStore.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateStore.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        privateStore.cloudKitContainerOptions =
            NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        // databaseScope defaults to `.private`; the `.shared` scope is added in the sharing phase.
        cloud.persistentStoreDescriptions = [privateStore]

        var loadError: Error?
        cloud.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        mirror = cloud   // keep the mirror alive for the app's lifetime

        // SwiftData opens the SAME store for the UI. It must NOT drive CloudKit (`.none`) — NSPCKC does.
        let config = ModelConfiguration(schema: schema, url: defaultStoreURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: config)
    }
}
