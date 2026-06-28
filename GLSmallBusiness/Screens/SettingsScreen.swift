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
    @AppStorage(SchedulingPrefs.oneJobAtATimeKey) private var oneJobAtATime = true

    @Environment(SubscriptionManager.self) private var subscription
    @State private var managingSubscription = false
    @State private var redeemingCode = false
    @State private var restoring = false
    @State private var showingPaywall = false
    @State private var subscriptionAlert: String?   // result of a restore / redeem; nil = no alert

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
                InfoLabel("Appearance", info: "Choose Light or Dark, or Auto to follow your device’s setting.")
            }

            Section {
                Toggle("Use company logo", isOn: $useCompanyLogo)
            } header: {
                InfoLabel("Branding", info: "Personalize the app with your uploaded company logo — it appears on the Menu button and faintly behind your screens. Turn this off to use the app’s built-in monogram instead.")
            }

            Section {
                Toggle("Book one job at a time", isOn: $oneJobAtATime)
            } header: {
                InfoLabel("Scheduling", info: "Warns you before you double-book a day.")
            }

            Section {
                NavigationLink {
                    WorkScheduleScreen()
                } label: {
                    Label("Work schedule", systemImage: "calendar.badge.clock")
                }
            } header: {
                InfoLabel("Workdays", info: "Set your workdays and hours, the holidays you take off, and any time off — these drive your next available date and the gaps between jobs.")
            }

            Section {
                // Only once status is known, so a subscriber never briefly sees "Upgrade" on cold launch.
                if subscription.statusKnown && !subscription.isSubscribed {
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Upgrade to Unlimited", systemImage: "sparkles")
                    }
                }
                Button {
                    managingSubscription = true
                } label: {
                    Label("Manage Subscription", systemImage: "creditcard")
                }
                Button {
                    restoring = true
                    Task {
                        defer { restoring = false }
                        do {
                            try await AppStore.sync()
                            subscriptionAlert = "Your purchases have been restored. If you have an active subscription, it’s now active on this device."
                        } catch {
                            // nil message = the user cancelled the sign-in sheet — say nothing.
                            subscriptionAlert = SubscriptionActions.restoreFailureMessage(for: error)
                        }
                    }
                } label: {
                    if restoring {
                        ProgressView()
                    } else {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(restoring)
                Button {
                    redeemingCode = true
                } label: {
                    Label("Redeem Code", systemImage: "gift")
                }
            } header: {
                InfoLabel("Subscription", info: "Manage or restore your subscription, or redeem an App Store code.")
            }

            // CloudKit Sharing — only while the sync engine is on, so Release users never see a half-wired
            // row (CloudKitSyncEngine.isEnabled is always false in Release).
            if CloudKitSyncEngine.isEnabled {
                Section {
                    NavigationLink {
                        CollaborationScreen()
                    } label: {
                        Label("Connect a device or person", systemImage: "person.crop.circle.badge.plus")
                    }
                } header: {
                    InfoLabel("Sharing", info: "Invite a second Apple ID — your own other phone or a trusted person — to see and edit the same business data live.")
                }
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
        .contentMargins(.top, 10, for: .scrollContent)   // breathing room below the large title's descenders
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.large)
        .paywallSheet(isPresented: $showingPaywall)
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .offerCodeRedemption(isPresented: $redeemingCode) { result in
            if case .failure(let error) = result {
                subscriptionAlert = SubscriptionActions.redeemFailureMessage(for: error)
            }
        }
        .alert("Subscription", isPresented: Binding(
            get: { subscriptionAlert != nil },
            set: { if !$0 { subscriptionAlert = nil } }
        )) {
            Button("OK", role: .cancel) { subscriptionAlert = nil }
        } message: {
            Text(subscriptionAlert ?? "")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
