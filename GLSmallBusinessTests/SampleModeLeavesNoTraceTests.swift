//
//  SampleModeLeavesNoTraceTests.swift — law 42: a sample session leaves the device as it found it.
//
//  Audit 2026-10-03 F149. Inside "Explore with sample data" the Settings switches, the app's
//  Language and Appearance, and the security switches (Face ID lock, hide when switching apps)
//  wrote this iPhone's real preferences, and Exit kept them: the owner signed back in to a
//  Spanish app with the double-booking warning and the Face ID lock off. Exit now puts every
//  one of them back the way it was before the session began.
//
//  Unit tests run in the host app's process and these keys are the host's real preferences, so
//  every test records them first and puts them back at the end (never inherit process state).
//

import Foundation
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct SampleModeLeavesNoTraceTests {

    /// Every preference a sample session can change from the Menu, the Settings screen or the
    /// assistant tools. Spelled out here (not read from the app) so a key dropped from the
    /// app's fence fails this test.
    private static let keys = [
        "mb.useCompanyLogo",
        "mb.scheduleOneJobAtATime",
        "mb.language.pref",
        "mb.language",
        "mb.appearance",
        "mb.requireBiometricUnlock",
        "mb.hideWhenBackgrounded",
    ]

    private static func record(_ defaults: UserDefaults) -> [String: Any] {
        var saved: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { saved[key] = value } }
        return saved
    }

    private static func putBack(_ saved: [String: Any], language: MBLanguagePref,
                                appearance: AppearancePref, in defaults: UserDefaults) {
        AppSettingsService.setLanguage(language)
        AppSettingsService.setAppearance(appearance)
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    @Test("Settings changed while exploring sample data are put back on Exit")
    func settingsChangedInSampleModeAreRestoredOnExit() {
        let defaults = UserDefaults.standard
        let saved = Self.record(defaults)
        let savedLanguage = AppSettingsService.language
        let savedAppearance = AppSettingsService.appearance
        let demo = UserDemoMode.shared
        defer {
            if demo.isDemoActive { demo.exitDemo() }
            Self.putBack(saved, language: savedLanguage, appearance: savedAppearance, in: defaults)
        }

        // The owner's real choices before the sample session.
        AppSettingsService.setUseCompanyLogo(true)
        AppSettingsService.setOneJobAtATime(true)
        AppSettingsService.setLanguage(.en)
        AppSettingsService.setAppearance(.light)
        defaults.set(true, forKey: AppLockPrefs.key)
        defaults.set(true, forKey: "mb.hideWhenBackgrounded")
        let before = Self.record(defaults)

        demo.startDemo()
        #expect(demo.isDemoActive)

        // Everything a person (or the assistant) can flip inside the sample.
        AppSettingsService.setUseCompanyLogo(false)
        AppSettingsService.setOneJobAtATime(false)
        AppSettingsService.setLanguage(.es)
        AppSettingsService.setAppearance(.dark)
        defaults.set(false, forKey: AppLockPrefs.key)
        defaults.set(false, forKey: "mb.hideWhenBackgrounded")

        demo.exitDemo()

        let after = Self.record(defaults)
        for key in Self.keys {
            #expect(String(describing: after[key]) == String(describing: before[key]),
                    "\(key) kept the sample session's value after Exit")
        }
        // The live stores follow the restored values, not just the saved keys.
        #expect(AppSettingsService.language == .en)
        #expect(AppSettingsService.appearance == .light)
        #expect(AppSettingsService.useCompanyLogo())
        #expect(AppSettingsService.oneJobAtATime())
    }

    @Test("A preference that was never set is removed again on Exit, not left at the sample's value")
    func aPreferenceNeverSetIsRemovedOnExit() {
        let defaults = UserDefaults.standard
        let saved = Self.record(defaults)
        let savedLanguage = AppSettingsService.language
        let savedAppearance = AppSettingsService.appearance
        let demo = UserDemoMode.shared
        defer {
            if demo.isDemoActive { demo.exitDemo() }
            Self.putBack(saved, language: savedLanguage, appearance: savedAppearance, in: defaults)
        }

        defaults.removeObject(forKey: "mb.hideWhenBackgrounded")
        defaults.removeObject(forKey: SchedulingPrefs.oneJobAtATimeKey)

        demo.startDemo()
        defaults.set(false, forKey: "mb.hideWhenBackgrounded")
        AppSettingsService.setOneJobAtATime(false)
        demo.exitDemo()

        #expect(defaults.object(forKey: "mb.hideWhenBackgrounded") == nil)
        #expect(defaults.object(forKey: SchedulingPrefs.oneJobAtATimeKey) == nil)
        #expect(AppSettingsService.oneJobAtATime(), "the default (on) applies again")
    }
}

/// The fence itself, on a private defaults suite (no host state touched).
@MainActor
@Suite(.serialized)
struct SampleSettingsFenceTests {
    private static func freshDefaults() -> (UserDefaults, String) {
        let name = "SampleSettingsFenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }

    @Test("Every switch and both security switches are inside the fence")
    func theFenceCoversEveryPreferenceASampleCanChange() {
        let keys = Set(AppSettingsService.sampleSessionKeys)
        for key in ["mb.useCompanyLogo", "mb.scheduleOneJobAtATime", "mb.language.pref", "mb.language",
                    "mb.language.account", "mb.appearance", "mb.appearance.account",
                    "mb.requireBiometricUnlock", "mb.hideWhenBackgrounded"] {
            #expect(keys.contains(key), "\(key) is outside the sample fence")
        }
        #expect(!keys.contains(UserDemoMode.defaultsKey), "the sample flag itself is never restored")
    }

    @Test("A relaunch re-seeding a running sample keeps the values saved when it began")
    func resumingKeepsTheFirstSnapshot() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AppLockPrefs.key)
        AppSettingsService.beginSampleSession(resuming: false, defaults: defaults)
        defaults.set(false, forKey: AppLockPrefs.key)          // changed inside the sample
        AppSettingsService.beginSampleSession(resuming: true, defaults: defaults)   // relaunch
        #expect(AppSettingsService.restoreSampleSnapshot(defaults: defaults))
        #expect(defaults.object(forKey: AppLockPrefs.key) as? Bool == true)
        #expect(defaults.object(forKey: AppSettingsService.sampleSnapshotKey) == nil, "the snapshot goes on Exit")
    }

    @Test("A new sample session takes a fresh snapshot")
    func aNewSessionTakesAFreshSnapshot() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("es", forKey: "mb.language.pref")
        AppSettingsService.beginSampleSession(resuming: false, defaults: defaults)
        defaults.set("en", forKey: "mb.language.pref")
        AppSettingsService.beginSampleSession(resuming: false, defaults: defaults)
        #expect(AppSettingsService.restoreSampleSnapshot(defaults: defaults))
        #expect(defaults.string(forKey: "mb.language.pref") == "en")
    }

    @Test("Exit with no sample session changes nothing (every sign-in calls it)")
    func restoringWithoutASessionChangesNothing() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: SchedulingPrefs.oneJobAtATimeKey)
        #expect(!AppSettingsService.restoreSampleSnapshot(defaults: defaults))
        #expect(defaults.object(forKey: SchedulingPrefs.oneJobAtATimeKey) as? Bool == false)
    }
}

/// The Menu's last button in the sample (audit 2026-10-03 F36).
@MainActor
struct SampleMenuSessionTests {
    @Test("Signed out in the sample: Exit Sample Mode, never greyed out")
    func signedOutSampleShowsAnEnabledExit() {
        let sample = MenuScreen.isSampleSession(demoActive: true, isSignedIn: false)
        #expect(sample)
        #expect(!MenuScreen.isSignOutDisabled(isSampleSession: sample, isBusy: false, isSignedIn: false, isHarness: false))
        #expect(!MenuScreen.isSignOutDisabled(isSampleSession: sample, isBusy: true, isSignedIn: false, isHarness: false))
    }

    @Test("A real session always wins (law 43): Sign out, as before")
    func aRealSessionKeepsSignOut() {
        #expect(!MenuScreen.isSampleSession(demoActive: true, isSignedIn: true))
        #expect(!MenuScreen.isSampleSession(demoActive: false, isSignedIn: true))
        #expect(!MenuScreen.isSignOutDisabled(isSampleSession: false, isBusy: false, isSignedIn: true, isHarness: false))
        #expect(MenuScreen.isSignOutDisabled(isSampleSession: false, isBusy: true, isSignedIn: true, isHarness: false))
        #expect(MenuScreen.isSignOutDisabled(isSampleSession: false, isBusy: false, isSignedIn: false, isHarness: false))
        #expect(!MenuScreen.isSignOutDisabled(isSampleSession: false, isBusy: false, isSignedIn: false, isHarness: true))
    }
}
