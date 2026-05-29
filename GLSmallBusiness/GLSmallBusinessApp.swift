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
        do {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: cloud)
        } catch {
            print("⚠️ CloudKit store unavailable — falling back to a local store. \(error)")
            let local = ModelConfiguration(schema: schema)
            do {
                return try ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, configurations: local)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        registerBundledFonts()
        configureNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            CustomersScreen()
                .preferredColorScheme(appColorScheme.colorScheme)
                .onChange(of: appColorSchemeRaw, initial: true) { _, _ in
                    applyAppearanceOverride()
                }
        }
        .modelContainer(sharedModelContainer)
    }

    /// `.preferredColorScheme` only affects the presentation it's attached to — sheets (the Menu,
    /// the forms, etc.) don't inherit it, so toggling appearance wouldn't update an open sheet.
    /// Setting the window's `overrideUserInterfaceStyle` changes the trait for the whole window,
    /// which cascades to every presented sheet too.
    private func applyAppearanceOverride() {
        #if canImport(UIKit)
        let style: UIUserInterfaceStyle
        switch appColorScheme {
        case .light: style = .light
        case .dark: style = .dark
        case .system: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
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
