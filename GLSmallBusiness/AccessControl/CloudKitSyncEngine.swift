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

#if DEBUG
extension CloudKitSyncEngine {
    /// Keeps the CloudKit **Development** schema complete and in sync with the model — automatically.
    ///
    /// Why this exists: SwiftData's `.automatic` mirroring only creates CloudKit schema lazily, as
    /// records actually sync. Never-exercised models (`Paycheck`, `Project`, `SubPayment`), to-one
    /// links (`ScheduledJob.customer/invoice/project`, `Invoice.job`, `Receipt.job`) and optional
    /// photo/file/text fields therefore never reach CloudKit — and in Production (locked schema) those
    /// saves silently fail. `initializeCloudKitSchema` introspects the model and creates the *complete*
    /// schema regardless of data, closing that gap.
    ///
    /// Runs on DEBUG launches and is a NO-OP unless the model's shape changed since the last successful
    /// run (tracked by a fingerprint in `UserDefaults`), so it stays out of the way day to day and only
    /// does work right after you edit an `@Model`. Force a re-run by launching with
    /// `-initializeCloudKitSchema YES`.
    ///
    /// ⚠️ This can ONLY update the **Development** environment. Apple does not allow code to change the
    /// **Production** schema — after this runs you must still open CloudKit Dashboard →
    /// **Deploy Schema Changes…** (Development → Production) once. That manual deploy is unavoidable by
    /// design (the production schema is permanent and additive-only). Compiled out of Release builds.
    ///
    /// Requires a DEBUG build on a device/simulator signed into the container's iCloud account. Uses a
    /// throwaway temp store so the live `default.store` is never touched — the schema lives in the
    /// CloudKit container (keyed by `containerIdentifier`), not the local store file.
    static func initializeCloudKitSchemaIfNeeded() {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: GLSchemaV1.models) else {
            print("❌ [schema-init] Could not build the managed object model from GLSchemaV1.")
            return
        }

        let fingerprintKey = "cloudKitSchemaFingerprint"
        let fingerprint = schemaFingerprint(model)
        let forced = UserDefaults.standard.bool(forKey: "initializeCloudKitSchema")
        guard forced || UserDefaults.standard.string(forKey: fingerprintKey) != fingerprint else {
            return   // model shape unchanged since the last successful init — nothing to do
        }

        let container = NSPersistentCloudKitContainer(name: "GLSmallBusiness", managedObjectModel: model)
        // Throwaway local store: initializeCloudKitSchema writes & deletes sample records of every type;
        // keep that churn off the real store. Only the CloudKit Development schema gets populated.
        let tempURL = URL.temporaryDirectory.appending(path: "schema-init-\(UUID().uuidString).store")
        let desc = NSPersistentStoreDescription(url: tempURL)
        desc.cloudKitContainerOptions =
            NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            print("❌ [schema-init] Temp store load failed: \(loadError)")
            return
        }

        do {
            print("⏳ [schema-init] Model changed — creating the FULL CloudKit schema in DEVELOPMENT… (can take a minute)")
            try container.initializeCloudKitSchema(options: [])
            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)   // remember only on success
            print("✅ [schema-init] DEVELOPMENT schema is now complete. "
                + "Deploy it: CloudKit Dashboard → ‘Deploy Schema Changes…’ (Development → Production).")
        } catch {
            print("❌ [schema-init] initializeCloudKitSchema failed (schema NOT updated, retries next launch): \(error)")
        }

        // NOTE: do NOT delete tempURL here. initializeCloudKitSchema leaves CloudKit mirroring tasks
        // briefly using the store; removing the file out from under them throws SQLite "vnode unlinked
        // while in use" noise in the console. It lives in the OS temp directory (reclaimed automatically),
        // so leaving it is harmless — and this whole path is DEBUG-only.
    }

    /// A stable fingerprint of the model's shape (entity names + their property names). Changes whenever
    /// an `@Model` or a stored property is added/removed — exactly when the CloudKit schema needs
    /// regenerating. Stored as a plain string, not `hashValue` (which isn't stable across launches).
    private static func schemaFingerprint(_ model: NSManagedObjectModel) -> String {
        model.entities
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
            .map { entity in
                let props = entity.propertiesByName.keys.sorted().joined(separator: ",")
                return "\(entity.name ?? "?"){\(props)}"
            }
            .joined(separator: "|")
    }
}
#endif
