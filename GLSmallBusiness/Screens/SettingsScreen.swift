//
//  SettingsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import GoldLifeUI
import GoldLifeAI
import GoldLifeCloud
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// The appearance preference is AppearanceStore (Services/AppearanceStore.swift)
// — the law-29 Gold Life Setting pattern, account-synced. The old 3-option
// AppColorScheme enum retired with it; its stored value migrates on first run.

/// Whether the uploaded company logo personalizes the app's chrome — the Menu button and the
/// faint screen-background watermark. Device-local `@AppStorage`; defaults to `true` to match the
/// app's original behavior (the Menu button has always shown the uploaded logo when one is set).
/// When `false`, that chrome falls back to the built-in GL monogram. Does NOT affect the logo on
/// estimate/invoice PDFs or emails — those always carry the company logo.
enum AppBranding {
    static let useCompanyLogoKey = "mb.useCompanyLogo"
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
    @State private var appearanceStore = AppearanceStore.shared
    /// Whether the assistant may share records right now — read on appear, so the row appears the
    /// moment someone allows sharing and disappears the moment they stop.
    @State private var assistantSharingOn = false
    @State private var stoppingAssistantSharing = false
    @AppStorage(AppBranding.useCompanyLogoKey) private var useCompanyLogo = true
    @AppStorage(SchedulingPrefs.oneJobAtATimeKey) private var oneJobAtATime = true
    @AppStorage(AppLockPrefs.key) private var requireLock = false
    /// The app-switcher cover. Default ON (privacy-first); independent of the
    /// Face ID lock, so turning the lock off still leaves the cover in place.
    @AppStorage("mb.hideWhenBackgrounded") private var hideWhenBackgrounded = true

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query private var userProfiles: [UserProfile]

    /// "Extra line in emails" — the String twin of `profileBinding`: same read-only guard in the
    /// setter, same fetch-or-create (in the service). Each keystroke is written (as typed) but not
    /// saved; `saveEmailSignatureText` saves once when the field loses focus or the screen goes.
    private var emailSignatureTextBinding: Binding<String> {
        Binding(
            get: { profiles.first?.emailSignatureText ?? "" },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                perform {
                    try BusinessProfileService.setEmailSignatureText(newValue, saveNow: false, in: modelContext)
                }
            }
        )
    }

    /// The one save for the typed "Extra line in emails" (a no-op when nothing is pending).
    private func saveEmailSignatureText() {
        modelContext.saveChanges()
    }

    /// Runs a service write after this screen's gate; an unpredicted refusal is shown, not dropped.
    private func perform(_ write: () throws -> Void) {
        do { try write() } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// The UserProfile twin of `profileBinding` — the one per-person Setting on
    /// this screen (whose name signs outgoing emails). Same read-only guard, and the
    /// same fetch-or-create: a new account has no UserProfile row until something
    /// writes one (a duplicate from the sync bootstrap is merged by ProfileDedup).
    private var emailNameBinding: Binding<Bool> {
        Binding(
            get: { userProfiles.first?.useMyNameInEmails ?? false },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                UserProfile.setUseMyNameInEmails(newValue, in: modelContext)
            }
        )
    }

    /// A switch on the single business profile (synced), defaulting to on (the original document
    /// behavior). BusinessProfileService finds or creates the profile.
    private func profileBinding(_ setting: BusinessDisplaySetting) -> Binding<Bool> {
        Binding(
            get: { profiles.first?[keyPath: setting.keyPath] ?? true },
            set: { newValue in
                // A toggle bound straight to the model has nowhere else to refuse, so the guard
                // lives in the setter and the alert is bound to the screen.
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                perform { try BusinessProfileService.setDisplay(setting, newValue, in: modelContext) }
            }
        )
    }

    @State private var localization = MBLocalization.shared
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal BusinessProfileService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @FocusState private var signatureFieldFocused: Bool

    var body: some View {
        Form {
            // FIRST, and only when it applies: the backup has stopped and needs a decision.
            // Everything below it is a preference; this is the one thing that is waiting.
            GLSyncPausedSection()
            // The server's refusals are shown here once each, beside the row that counts them
            // (QA 2026-10-03 F87).
            Section { GLSyncBackupRow() }
                .modifier(GLSyncMessageAlert())

            // Pure device/app preferences. Gold Life ID, Subscription, Legal, and
            // About all moved up to the Menu in the fleet parity pass
            // (2026-08-22) — the Menu's gold pill, Subscription row, and About row
            // are their homes now.
            Section {
                NavigationLink {
                    AppearanceScreen()
                } label: {
                    HStack {
                        Text("Appearance")
                        Spacer()
                        Text(appearanceStore.pref.label)
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                }
            } header: {
                InfoLabel("Appearance", info: "System, Light, or Dark, for My Business on this device. Your Gold Life ID holds the setting every Gold Life app follows.", topic: "Appearance")
            }

            Section {
                NavigationLink {
                    LanguageScreen()
                } label: {
                    HStack {
                        Text("Language")
                        Spacer()
                        Text(localization.pref.pickerLabel)
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                }
            } header: {
                InfoLabel("Language", info: "English or Español, for My Business on this device. Your Gold Life ID holds the setting every Gold Life app follows.", topic: "Language")
            }

            // Law 84: which Maps, Messages and Email apps a tapped address, phone or email opens.
            GLContactAppsSettingsSection()

            // ONE section for everything a CUSTOMER sees on paperwork. It used to be
            // four sibling sections — "Email", "Logo", "Business address on documents",
            // "Documents" — all of which mean the same thing to a contractor, so which
            // switch controlled which channel was guesswork. (The owner hit exactly this:
            // he turned on "Show logo on documents" expecting his logo on an emailed
            // estimate, and the email logo is gated by the signature toggle instead.)
            // The rows are now named by CHANNEL, so no heading can lie.
            Section {
                // Straight to the asset. The Logo section used to hold two switches about
                // a logo with no logo in sight and no way to reach one.
                if let profile = profiles.first {
                    NavigationLink {
                        MyCompanyFormScreen(profile: profile)
                    } label: {
                        HStack(spacing: 12) {
                            MenuButtonLabel()
                                .frame(width: 34, height: 34)
                            Text("Your logo")
                            Spacer()
                        }
                    }
                }
                // Each switch names every place it controls in its own ⓘ (found 2026-09-29: the
                // owner looked for the contractor-package EMAIL logo under the documents switch;
                // the email logo is the signature's). PDF behavior is unchanged.
                Toggle(isOn: profileBinding(.logoOnDocuments)) {
                    InfoLabel("Logo on documents and texts",
                              info: "Puts your logo on estimates, invoices, change orders, payment receipts and completion packages, and on the logo picture sent with a text message. Your logo in emails is the next switch.",
                              topic: "Logo on documents and texts")
                }
                Toggle(isOn: profileBinding(.emailSignature)) {
                    InfoLabel("Logo and signature in emails",
                              info: "Adds your logo, business name and contact details at the bottom of every email you send — estimates, invoices, change orders, receipts and contractor packages. Turn it off and emails go out with no logo.",
                              topic: "Logo and signature in emails")
                }
                if profiles.first?.emailSignatureEnabled ?? true {
                    TextField("Extra line in emails (optional)", text: emailSignatureTextBinding, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($signatureFieldFocused)
                        .onChange(of: signatureFieldFocused) { _, focused in
                            if !focused { saveEmailSignatureText() }
                        }
                    // Per-PERSON, not per-business: each Gold Life ID on the
                    // account picks whose name signs the emails THEY send.
                    // Owner is the default (the original behavior); "My name"
                    // falls back to the owner's when this person's own name is
                    // blank, so the signature never loses its name line.
                    Picker("Name in emails", selection: emailNameBinding) {
                        Text("Owner’s name").tag(false)
                        Text("My name").tag(true)
                    }
                }
                Toggle("Show address on documents", isOn: profileBinding(.addressOnDocuments))
                NavigationLink {
                    DocumentSettingsScreen()
                } label: {
                    Label("Document Messages", systemImage: "text.bubble")
                }
            } header: {
                InfoLabel("What customers see", info: "Everything that shows up on the estimates, invoices, receipts and emails you send. Your logo in emails uses the light version — email backgrounds are white.", topic: "What customers see")
            }

            // Kept separate on purpose: this one is about THIS iPhone, not about
            // anything a customer receives. It used to sit beside "Logo on documents"
            // under one "Logo" heading, mixing a local preference with a synced one.
            Section {
                Toggle("Use logo in the app", isOn: Binding(get: { useCompanyLogo },
                                                            set: { AppSettingsService.setUseCompanyLogo($0) }))
            } header: {
                InfoLabel("In the app", info: "Personalizes the Menu button and the faint background watermark. This device only — it changes nothing your customers see.", topic: "In the app")
            }

            Section {
                Toggle("Book one job at a time", isOn: Binding(get: { oneJobAtATime },
                                                               set: { AppSettingsService.setOneJobAtATime($0) }))
            } header: {
                InfoLabel("Scheduling", info: "Warns you before you double-book a day.", topic: "Scheduling")
            }

            Section {
                NavigationLink {
                    WorkScheduleScreen()
                } label: {
                    Label("Work schedule", systemImage: "calendar.badge.clock")
                }
            } header: {
                InfoLabel("Workdays", info: "Set your workdays and hours, the holidays you take off, and any time off — these drive your next available date and the gaps between jobs.", topic: "Workdays")
            }

            // The assistant's data sharing, and the one way to take it back (contract §4: the
            // consent sheet promises this row is here). Shown only once sharing is on — there is
            // nothing to stop before that.
            // Nothing of the assistant is reachable while its compile-time switch is off (D1); the
            // stored consent stays, and sign-out still clears it.
            if MBFeatureFlags.assistantEnabled && assistantSharingOn {
                Section {
                    Button(role: .destructive) { stoppingAssistantSharing = true } label: {
                        Label("Stop sharing with Sentinel", systemImage: "sparkles")
                    }
                } header: {
                    InfoLabel("Sentinel", info: "Sentinel sends what you type and the records needed to answer when using a connected cloud AI. Turn this off and Sentinel will ask again before sending.", topic: "Sentinel")
                }
            }

            Section {
                Toggle("Require Face ID to open", isOn: $requireLock)
                Toggle("Hide when switching apps", isOn: $hideWhenBackgrounded)
            } header: {
                // The last sentence used to end at "on this iPhone", which read as "this
                // iPhone is the only copy" — true under CloudKit-off, false the moment the
                // Gold Life backup exists (GLSYNC-SPEC.md §4). It now says where the other
                // copy is and what stands in front of it, so this lock isn't mistaken for
                // the only one.
                InfoLabel("Security", info: "Require Face ID (or your device passcode) to open My Business, and again if you have been away for a minute. Hiding when switching apps covers your records in the app switcher, where your device stores the picture it takes — turn it off if you want to see this app beside another one. Your records are encrypted on this device either way, and your Gold Life backup can only be reached by signing in.", topic: "Security")
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .alert("Stop sharing with Sentinel?", isPresented: $stoppingAssistantSharing) {
            Button("Stop Sharing", role: .destructive) {
                MBAssistantSession.shared.consent.reset()
                assistantSharingOn = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Sentinel will ask before sending to connected cloud AIs again.")
        }
        .onAppear { assistantSharingOn = MBAssistantSession.shared.consent.isGranted }
        .onDisappear { saveEmailSignatureText() }
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Settings"))), for: .scrollContent)   // breathing room below the large title's descenders
        .navigationTitle(GLScript.padded(mbLoc("Settings")))
        .toolbarTitleDisplayMode(.large)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
