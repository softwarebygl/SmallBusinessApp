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

/// Opaque branded cover shown over the whole app whenever it isn't active, so sensitive on-screen
/// data (SSN/TIN, a customer's financials, a 1099/W-9 preview) never lands in the app-switcher
/// snapshot. Contains no user data of its own.
private struct PrivacyScreen: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Text("My Business")
                .font(.custom("Italianno-Regular", size: 52))
                .foregroundStyle(Color("AccentColor"))
        }
    }
}

@main
struct GLSmallBusinessApp: App {
    /// Device-local appearance preference (Light / Dark / Auto), set in Settings.
    @AppStorage(AppColorScheme.storageKey) private var appColorSchemeRaw = AppColorScheme.system.rawValue
    private var appColorScheme: AppColorScheme { AppColorScheme(rawValue: appColorSchemeRaw) ?? .system }
    @Environment(\.scenePhase) private var scenePhase

    /// Private-CloudKit-backed store. With `.automatic`, CloudKit sync turns on once the
    /// iCloud capability is enabled; until then (or with no iCloud account) it stays local.
    let sharedModelContainer: ModelContainer = {
        // Versioned schema + migration plan so future model changes upgrade existing
        // customers' data safely. See GLSchema.swift for the rules before changing any @Model.
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        #if DEBUG
        // UI tests that need a deterministic, pristine dataset launch with -uiTestChangeOrder → use a
        // throwaway in-memory store so the demo seed runs fresh every launch (the persistent demo store is
        // idempotent and wouldn't pick up test-only fixtures), and the real store is never touched.
        if ProcessInfo.processInfo.arguments.contains("-uiTestChangeOrder"),
           let memory = try? ModelContainer(
               for: schema,
               configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)) {
            return memory
        }
        // Auto-maintain the CloudKit DEVELOPMENT schema: if the data model changed since the last run,
        // force-create every record type/field so nothing is missing before you Deploy to Production.
        // No-op when the model is unchanged. Runs synchronously to completion before the live store
        // loads. (Production still requires a manual ‘Deploy Schema Changes’ in CloudKit Dashboard.)
        CloudKitSchemaInit.runIfNeeded()
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
            ProfileDedup.run(sharedModelContainer.mainContext)
        }
        #else
        JobMigration.runIfNeeded(sharedModelContainer.mainContext)
        ProfileDedup.run(sharedModelContainer.mainContext)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppGate()   // shows the app to everyone (free up to the FreeTier caps) and keeps the
                        // subscription entitlement live; the paywall appears only at a cap
                .tint(Color("AccentColor"))   // GL gold accent app-wide (tabs, selections, buttons)
                .preferredColorScheme(appColorScheme.colorScheme)
                .environment(SubscriptionManager.shared)
                // Cover the UI whenever the app isn't active so the iOS app-switcher snapshot can't
                // capture an on-screen SSN/TIN or a customer's financials. (No app data is in
                // PrivacyScreen.)
                .overlay {
                    if scenePhase != .active { PrivacyScreen() }
                }
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
        // Scale the script titles with Dynamic Type (capped so they enlarge for low-vision users
        // without overrunning the nav bar).
        if let largeFont = UIFont(name: "Italianno-Regular", size: 48) {
            appearance.largeTitleTextAttributes[.font] =
                UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: largeFont, maximumPointSize: 64)
        }
        if let inlineFont = UIFont(name: "Italianno-Regular", size: 28) {
            appearance.titleTextAttributes[.font] =
                UIFontMetrics(forTextStyle: .headline).scaledFont(for: inlineFont, maximumPointSize: 40)
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        #endif
    }
}
