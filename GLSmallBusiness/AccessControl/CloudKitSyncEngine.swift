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
import CloudKit

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

    /// The accepted-shares store (CloudKit `.shared` scope). Data shared TO this device by another Apple
    /// ID lands here — a SEPARATE file from `default.store` (the owner's own private data), because
    /// CloudKit keeps the private and shared databases apart. Held so the accept-invitation call can
    /// target it.
    nonisolated(unsafe) private static var sharedStore: NSPersistentStore?

    static var sharedStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "shared.store")
    }

    /// The one store the SwiftData UI reads. The owner reads their own data (`default.store`); a device
    /// that has ACCEPTED a share is a pure participant (no private data of its own), so its UI reads the
    /// shared store instead. This participant-side rendering is the seam to confirm in on-device testing.
    static var uiStoreURL: URL {
        SharingState.isParticipant ? sharedStoreURL : defaultStoreURL
    }

    /// The top-level @Model entity names. Every other record (line items, payments, groups, attachments,
    /// time entries, …) is reachable from one of these through a relationship, so a CKShare covering
    /// these covers the whole business. Keep in sync with GLSchemaV1's top-level types.
    static let topLevelEntityNames = [
        "Customer", "Invoice", "Estimate", "Receipt", "Employee",
        "Subcontractor", "ScheduledJob", "Project", "BusinessProfile", "UserProfile",
    ]

    /// Builds a SwiftData `ModelContainer` whose underlying store is driven by an
    /// `NSPersistentCloudKitContainer` (so CKShare can be added later). Throws if the Core Data stack
    /// can't open the store, letting the caller fall back to the proven `.automatic` path.
    static func makeContainer(schema: Schema) throws -> ModelContainer {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: GLSchemaV1.models) else {
            throw CocoaError(.persistentStoreOpen)
        }

        let cloud = NSPersistentCloudKitContainer(name: "GLSmallBusiness", managedObjectModel: model)

        // Two stores: the owner's own data (`.private`) and any data shared TO this device by another
        // Apple ID (`.shared`). CloudKit keeps the private and shared databases apart, so they're
        // separate files. The shared store is what makes accepting an invite possible.
        let privateStore = makeStoreDescription(url: defaultStoreURL, scope: .private)
        let sharedStoreDescription = makeStoreDescription(url: sharedStoreURL, scope: .shared)
        cloud.persistentStoreDescriptions = [privateStore, sharedStoreDescription]

        // Stores load synchronously (shouldAddStoreAsynchronously = false), so the handler fires once per
        // store before `loadPersistentStores` returns — capture the first error across both.
        var loadError: Error?
        cloud.loadPersistentStores { _, error in
            if let error { loadError = loadError ?? error }
        }
        if let loadError { throw loadError }
        mirror = cloud   // keep the mirror alive for the app's lifetime
        sharedStore = cloud.persistentStoreCoordinator.persistentStores.first { $0.url == sharedStoreURL }

        // SwiftData opens ONE store for the UI (owner → private, participant → shared). It must NOT drive
        // CloudKit (`.none`) — NSPCKC does.
        let config = ModelConfiguration(schema: schema, url: uiStoreURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: config)
    }

    /// A CloudKit-mirrored store description for one database scope. History tracking + remote-change
    /// notifications are required for both SwiftData coexistence and CloudKit sharing.
    private static func makeStoreDescription(url: URL,
                                             scope: CKDatabase.Scope) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        options.databaseScope = scope
        description.cloudKitContainerOptions = options
        return description
    }
}

// MARK: - Sharing (CKShare, root-free)
//
// Whole-business sharing WITHOUT a synthetic root object: CloudKit's `share([objects], to:)` accepts a
// list of records and shares each one PLUS everything reachable from it through relationships. Passing
// every top-level record (its children come along automatically) covers the whole business in one
// CKShare — and needs zero data-model change, so the app's schema stays exactly as it ships today.

nonisolated enum CloudKitShareError: Error { case engineOff, nothingToShare, shareFailed }

extension CloudKitSyncEngine {
    /// The CKContainer backing the share — handed to `UICloudSharingController`.
    static var ckContainer: CKContainer { CKContainer(identifier: containerIdentifier) }

    /// Every top-level managed object in the owner's store (NSPCKC's sharing API works on managed
    /// objects, not SwiftData models).
    @MainActor
    private static func allTopLevelObjects() -> [NSManagedObject] {
        guard let mirror else { return [] }
        let context = mirror.viewContext
        return topLevelEntityNames.flatMap { name -> [NSManagedObject] in
            (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))) ?? []
        }
    }

    /// The existing business-wide share, if one has been minted (drives the owner UI's "Manage invite").
    @MainActor
    static func currentShare() -> CKShare? {
        guard let mirror else { return nil }
        let ids = allTopLevelObjects().map(\.objectID)
        guard !ids.isEmpty, let shares = try? mirror.fetchShares(matching: ids) else { return nil }
        return shares.values.first
    }

    /// Mints (or returns the already-minted) CKShare covering the whole business, then makes sure every
    /// current record is in it. The caller hands the result to `UICloudSharingController`.
    @MainActor
    static func shareEverything() async throws -> CKShare {
        guard let mirror else { throw CloudKitShareError.engineOff }
        if let existing = currentShare() {
            await addUnsharedRecords(to: existing)
            return existing
        }
        let objects = allTopLevelObjects()
        guard !objects.isEmpty else { throw CloudKitShareError.nothingToShare }
        return try await withCheckedThrowingContinuation { continuation in
            mirror.share(objects, to: nil) { _, share, _, error in
                if let share {
                    continuation.resume(returning: share)
                } else {
                    continuation.resume(throwing: error ?? CloudKitShareError.shareFailed)
                }
            }
        }
    }

    /// Adds records created AFTER the invite was sent into the existing share, so the second device keeps
    /// seeing everything. Idempotent: already-shared records are skipped. Owner-only (a participant
    /// doesn't own the share). Best-effort — runs on launch / when the Collaborate screen opens.
    @MainActor
    static func addUnsharedRecords(to share: CKShare) async {
        guard let mirror, !SharingState.isParticipant else { return }
        let objects = allTopLevelObjects()
        guard !objects.isEmpty,
              let existing = try? mirror.fetchShares(matching: objects.map(\.objectID)) else { return }
        let unshared = objects.filter { existing[$0.objectID] == nil }
        guard !unshared.isEmpty else { return }
        await withCheckedContinuation { continuation in
            mirror.share(unshared, to: share) { _, _, _, _ in continuation.resume() }
        }
    }

    /// Owner-side launch hook: if the business is already shared, fold in any newly-created records.
    @MainActor
    static func syncSharedRecordsIfNeeded() async {
        guard isEnabled, !SharingState.isParticipant, let share = currentShare() else { return }
        await addUnsharedRecords(to: share)
    }

    /// Accepts an invite on the participant device, importing the shared business into the shared store.
    static func acceptShare(_ metadata: CKShare.Metadata) {
        guard let mirror, let sharedStore else { return }
        mirror.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                print("⚠️ [sharing] accept failed: \(error)")
            } else {
                SharingState.markParticipant()   // next launch, the UI reads the shared store
            }
        }
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
