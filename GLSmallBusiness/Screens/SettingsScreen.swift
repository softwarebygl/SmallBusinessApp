//
//  SettingsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import StoreKit
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
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .system: String(localized: "Auto")
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

    @State private var managingSubscription = false
    @State private var redeemingCode = false
    @State private var restoring = false

    private let privacyURL = URL(string: "https://evolvedbygl.github.io/privacy/")!
    private let termsURL   = URL(string: "https://evolvedbygl.github.io/terms/")!

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

            Section {
                Button {
                    managingSubscription = true
                } label: {
                    Label("Manage Subscription", systemImage: "creditcard")
                }
                Button {
                    restoring = true
                    Task { try? await AppStore.sync(); restoring = false }
                } label: {
                    if restoring {
                        ProgressView()
                    } else {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    redeemingCode = true
                } label: {
                    Label("Redeem Code", systemImage: "gift")
                }
            } header: {
                Text("Subscription")
            } footer: {
                Text("Manage or restore your subscription, or redeem an App Store code.")
            }

            Section {
                Link(destination: termsURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                Text("Legal")
            }
        }
        .glFormBackground()
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .offerCodeRedemption(isPresented: $redeemingCode) { _ in }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
