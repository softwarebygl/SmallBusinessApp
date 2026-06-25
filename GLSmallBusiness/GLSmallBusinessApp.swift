//
//  GLSmallBusinessApp.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData
import CoreText
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
/// DEBUG-only: removes a SwiftData store and its `-wal` / `-shm` sidecars so a fresh one can be created
/// after a pre-launch schema change. Never compiled into release builds, so App Store data is untouched.
fileprivate func wipeSwiftDataStore(at url: URL) {
    let fileManager = FileManager.default
    for path in [url.path, url.path + "-wal", url.path + "-shm"] {
        try? fileManager.removeItem(atPath: path)
    }
}
#endif

@main
struct GLSmallBusinessApp: App {
    /// Device-local appearance preference (Light / Dark / Auto), set in Settings.
    @AppStorage(AppColorScheme.storageKey) private var appColorSchemeRaw = AppColorScheme.system.rawValue
    private var appColorScheme: AppColorScheme { AppColorScheme(rawValue: appColorSchemeRaw) ?? .system }

    /// Private-CloudKit-backed store. With `.automatic`, CloudKit sync turns on once the
    /// iCloud capability is enabled; until then (or with no iCloud account) it stays local.
    let sharedModelContainer: ModelContainer = {
        // Versioned schema + migration plan so future model changes upgrade existing
        // customers' data safely. See GLSchema.swift for the rules before changing any @Model.
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        #if DEBUG
        // In-progress CloudKit SHARING engine (NSPersistentCloudKitContainer). Off unless explicitly
        // enabled for testing; on failure it falls through to the proven `.automatic` path below.
        if CloudKitSyncEngine.isEnabled {
            if let shared = try? CloudKitSyncEngine.makeContainer(schema: schema) { return shared }
            print("⚠️ CloudKit sharing engine failed to start — using the standard .automatic store.")
        }
        #endif
        do {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: cloud)
        } catch {
            print("⚠️ CloudKit store unavailable — falling back to a local store. \(error)")
            let local = ModelConfiguration(schema: schema)
            do {
                return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: local)
            } catch {
                #if DEBUG
                // DEV ONLY: pre–App-Store the schema still changes often and we stay on V1, so an old
                // on-disk store from a previous build can't always migrate in place. Rather than force a
                // manual delete-and-reinstall on every schema change, wipe the local dev store and retry
                // once. This is compiled out of release builds, so App Store users' iCloud data is never
                // touched. (At App Store launch: freeze the shipped shape as GLSchemaV1 and use
                // GLSchemaV2 + a lightweight migration stage for every later change — see GLSchema.swift.)
                print("⚠️ Local store couldn’t load (\(error)). DEBUG: wiping the dev store and retrying.")
                wipeSwiftDataStore(at: local.url)
                if let recovered = try? ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self,
                                                       configurations: local) {
                    return recovered
                }
                #endif
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        registerBundledFonts()
        configureNavigationBarAppearance()
        #if DEBUG
        if DemoMode.isActive {
            DemoSeed.populate(sharedModelContainer.mainContext)
        } else {
            JobMigration.runIfNeeded(sharedModelContainer.mainContext)
        }
        #else
        JobMigration.runIfNeeded(sharedModelContainer.mainContext)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppGate()   // gates RootView behind an active subscription; RootView is the app
                .tint(Color("AccentColor"))   // GL gold accent app-wide (tabs, selections, buttons)
                .preferredColorScheme(appColorScheme.colorScheme)
                .environment(SubscriptionManager.shared)
        }
        .modelContainer(sharedModelContainer)
    }

    private func registerBundledFonts() {
        let filenames = [
            "Italianno-Regular",
            "Inter-VariableFont_opsz,wght",
            "Inter-Italic-VariableFont_opsz,wght",
        ]
        for name in filenames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("[Font] Not in bundle: \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let err = error?.takeRetainedValue()
                print("[Font] Failed to register \(name):", err as Any)
            }
        }
    }

    private func configureNavigationBarAppearance() {
        #if canImport(UIKit)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let largeFont = UIFont(name: "Italianno-Regular", size: 48) {
            appearance.largeTitleTextAttributes[.font] = largeFont
        }
        if let inlineFont = UIFont(name: "Italianno-Regular", size: 28) {
            appearance.titleTextAttributes[.font] = inlineFont
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        #endif
    }
}
