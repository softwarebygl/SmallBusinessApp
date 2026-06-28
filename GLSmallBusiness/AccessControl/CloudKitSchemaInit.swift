//
//  CloudKitSchemaInit.swift
//  GLSmallBusiness
//
//  DEBUG-only developer helper that keeps the CloudKit **Development** schema complete and in sync with
//  the @Model, so a Production "Deploy Schema Changes" never misses a field. This supports the app's
//  normal single-Apple-ID `.automatic` CloudKit sync (the sync that ships) — it has nothing to do with
//  multi-user sharing. Compiled out of Release builds.
//

import Foundation
import SwiftData
import CoreData

nonisolated enum CloudKitSchemaInit {
    static let containerIdentifier = "iCloud.com.evolvedbygl.GLSmallBusiness"

    #if DEBUG
    /// Keeps the CloudKit **Development** schema complete and in sync with the model — automatically.
    ///
    /// Why this exists: SwiftData's `.automatic` mirroring only creates CloudKit schema lazily, as records
    /// actually sync. Never-exercised models (`Paycheck`, `Project`, `SubPayment`), to-one links
    /// (`ScheduledJob.customer/invoice/project`, `Invoice.job`, `Receipt.job`) and optional photo/file/text
    /// fields therefore never reach CloudKit — and in Production (locked schema) those saves silently fail.
    /// `initializeCloudKitSchema` introspects the model and creates the *complete* schema regardless of
    /// data, closing that gap.
    ///
    /// Runs on DEBUG launches and is a NO-OP unless the model's shape changed since the last successful
    /// run (tracked by a fingerprint in `UserDefaults`), so it only does work right after you edit an
    /// `@Model`. Force a re-run by launching with `-initializeCloudKitSchema YES`.
    ///
    /// ⚠️ This can ONLY update the **Development** environment — after it runs you must still open CloudKit
    /// Dashboard → **Deploy Schema Changes…** (Development → Production) once.
    static func runIfNeeded() {
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

        // NOTE: do NOT delete tempURL here — initializeCloudKitSchema leaves mirroring tasks briefly using
        // the store; it lives in the OS temp directory (reclaimed automatically), so leaving it is harmless.
    }

    /// A stable fingerprint of the model's shape (entity names + their property names). Changes whenever an
    /// `@Model` or a stored property is added/removed — exactly when the CloudKit schema needs regenerating.
    private static func schemaFingerprint(_ model: NSManagedObjectModel) -> String {
        model.entities
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
            .map { entity in
                let props = entity.propertiesByName.keys.sorted().joined(separator: ",")
                return "\(entity.name ?? "?"){\(props)}"
            }
            .joined(separator: "|")
    }
    #endif
}
