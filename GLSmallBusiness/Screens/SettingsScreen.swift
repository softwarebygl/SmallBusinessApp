//
//  SettingsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The app's appearance preference. Stored device-locally in `@AppStorage` (not synced via
/// CloudKit) since appearance is a per-device UI choice. Applied at the app root with
/// `.preferredColorScheme`.
enum AppColorScheme: String, CaseIterable, Identifiable {
    case light, dark, system

    static let storageKey = "appColorScheme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Auto"
        }
    }

    /// The value to hand `.preferredColorScheme`. `nil` for Auto = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

extension AppColorScheme {
    /// Applies this appearance to every window via `overrideUserInterfaceStyle`, which cascades
    /// into presented sheets too (something `.preferredColorScheme` alone doesn't reach). Call
    /// this from the view that changes the preference so it takes effect immediately.
    func applyToWindows() {
        #if canImport(UIKit)
        let style: UIUserInterfaceStyle
        switch self {
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
}

struct SettingsScreen: View {
    @AppStorage(AppColorScheme.storageKey) private var appColorSchemeRaw = AppColorScheme.system.rawValue

    private var appearance: Binding<AppColorScheme> {
        Binding(
            get: { AppColorScheme(rawValue: appColorSchemeRaw) ?? .system },
            set: { appColorSchemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearance) {
                    ForEach(AppColorScheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Choose Light or Dark, or Auto to follow your device’s setting.")
            }
        }
        .glFormBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appColorSchemeRaw) { _, newValue in
            // Apply immediately from here so the open sheet repaints right away.
            (AppColorScheme(rawValue: newValue) ?? .system).applyToWindows()
        }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
