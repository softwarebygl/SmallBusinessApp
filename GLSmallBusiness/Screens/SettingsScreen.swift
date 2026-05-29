//
//  SettingsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

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

struct SettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
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
        .scrollContentBackground(.hidden)
        .background {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
