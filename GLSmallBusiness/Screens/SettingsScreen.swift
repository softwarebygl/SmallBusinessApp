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

/// Whether the uploaded company logo personalizes the app's chrome — the Menu button and the
/// faint screen-background watermark. Device-local `@AppStorage`; defaults to `true` to match the
/// app's original behavior (the Menu button has always shown the uploaded logo when one is set).
/// When `false`, that chrome falls back to the built-in GL monogram. Does NOT affect the logo on
/// estimate/invoice PDFs or emails — those always carry the company logo.
enum AppBranding {
    static let useCompanyLogoKey = "useCompanyLogo"
}

extension View {
    /// Forces this presentation (sheet / full-screen cover) to a color scheme. Pass the presenting
    /// screen's own `\.colorScheme` — it already reflects the app's Light/Dark/Auto setting. A sheet
    /// otherwise captures its scheme once when it appears and won't follow the app afterward, and
    /// `.preferredColorScheme(nil)` doesn't push the device's scheme onto a sheet for Auto. Driving
    /// it from the presenter's resolved scheme covers all three settings and repaints live.
    func glAppearance(_ scheme: ColorScheme) -> some View {
        preferredColorScheme(scheme)
    }
}

struct SettingsScreen: View {
    @AppStorage(AppColorScheme.storageKey) private var appColorSchemeRaw = AppColorScheme.system.rawValue
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true

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

            Section {
                Toggle("Use company logo", isOn: $useCompanyLogo)
            } header: {
                Text("Branding")
            } footer: {
                Text("Personalize the app with your uploaded company logo — it appears on the Menu button and faintly behind your screens. Turn this off to use the app’s built-in monogram instead.")
            }
        }
        .glFormBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
