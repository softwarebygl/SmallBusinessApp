//
//  AppSettingsService.swift
//  GLSmallBusiness
//
//  The app-level preferences a person (or the assistant) may change: this app's language and
//  appearance, "Book one job at a time", and "Use logo in the app". All four are device-local
//  (UserDefaults), not business records, and were never gated — so they aren't here either.
//
//  Deliberately NOT here: the Gold Life ID account's language and appearance (Stytch `gl_prefs`,
//  edited only on the Gold Life ID screen), "Name in emails" (per-person UserProfile), and the
//  security switches (Face ID lock, hide when switching apps). Those stay out of reach.
//
//  The sample-session fence (law 42) lives here too: it saves and puts back every device
//  preference a sample session can change, the security switches included.
//

import Foundation
import GoldLifeUI

@MainActor
enum AppSettingsService {

    // MARK: Language and appearance (this app only)

    /// This app's language — a local override; switches live.
    static func setLanguage(_ pref: MBLanguagePref) {
        MBLocalization.shared.setPref(pref)
    }

    static var language: MBLanguagePref { MBLocalization.shared.pref }

    /// This app's appearance — a local override; re-renders live.
    static func setAppearance(_ pref: AppearancePref) {
        AppearanceStore.shared.set(pref)
    }

    static var appearance: AppearancePref { AppearanceStore.shared.pref }

    // MARK: Switches (@AppStorage keys — the screens' toggles observe the same keys)

    /// "Book one job at a time": warn before double-booking. On unless turned off.
    static func setOneJobAtATime(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: SchedulingPrefs.oneJobAtATimeKey)
    }

    static func oneJobAtATime(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SchedulingPrefs.oneJobAtATimeKey) as? Bool ?? true
    }

    /// "Use logo in the app": the Menu button and background watermark. On unless turned off.
    static func setUseCompanyLogo(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: AppBranding.useCompanyLogoKey)
    }

    static func useCompanyLogo(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppBranding.useCompanyLogoKey) as? Bool ?? true
    }

    // MARK: Sample session (law 42: the device is left exactly as the sample found it)

    /// "Hide when switching apps" (SettingsScreen's `@AppStorage` spells the same key).
    static let hideWhenBackgroundedKey = "mb.hideWhenBackgrounded"

    /// Every device preference a sample session can change — from Settings, Language,
    /// Appearance or the assistant's tools — including the two security switches. The fence is
    /// here, at the keys, not at each screen: a new screen that writes one of them is covered
    /// for free (law 42). Audit 2026-10-03 F149.
    static var sampleSessionKeys: [String] {
        [AppBranding.useCompanyLogoKey, SchedulingPrefs.oneJobAtATimeKey,
         AppLockPrefs.key, hideWhenBackgroundedKey]
            + MBLocalization.deviceKeys + AppearanceStore.deviceKeys
    }

    /// Where the owner's values wait while the sample runs. It sits beside the sample flag and
    /// goes on Exit. Kept on disk, not in memory, so a sample session the system closed and the
    /// app re-seeded on the next launch still hands back the owner's values, never the sample's.
    static let sampleSnapshotKey = "mb.demoMode.savedSettings"

    /// Saves the owner's values as the sample session begins. `resuming` (the sample flag was
    /// already on: the app re-seeding after a relaunch) keeps the values saved the first time.
    static func beginSampleSession(resuming: Bool, defaults: UserDefaults = .standard) {
        if resuming, defaults.dictionary(forKey: sampleSnapshotKey) != nil { return }
        var snapshot: [String: Any] = [:]
        for key in sampleSessionKeys {
            if let value = defaults.object(forKey: key) { snapshot[key] = value }
        }
        defaults.set(snapshot, forKey: sampleSnapshotKey)
    }

    /// Puts every saved value back (a key the owner never set is removed again) and drops the
    /// snapshot. Returns false when no sample session was saved, changing nothing: the sign-in
    /// landing exits sample mode on every sign-in, sample or not.
    @discardableResult
    static func restoreSampleSnapshot(defaults: UserDefaults = .standard) -> Bool {
        guard let snapshot = defaults.dictionary(forKey: sampleSnapshotKey) else { return false }
        for key in sampleSessionKeys {
            if let value = snapshot[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: sampleSnapshotKey)
        return true
    }

    /// Ends the sample session: the owner's values come back, and the live language and
    /// appearance follow them at once (the switches' `@AppStorage` readers follow on their own).
    static func endSampleSession() {
        guard restoreSampleSnapshot() else { return }
        MBLocalization.shared.reloadFromDefaults()
        AppearanceStore.shared.reloadFromDefaults()
    }
}
