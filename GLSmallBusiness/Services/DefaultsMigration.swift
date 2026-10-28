//
//  DefaultsMigration.swift — one-shot rename of legacy UserDefaults keys into
//  the mb.* namespace (law 26). Runs from App.init before anything reads them;
//  each value is copied under its new name and the old key removed, so an
//  updating device keeps every preference and never re-runs a backfill.
//
//  Keys with their own owners migrate elsewhere: `appColorScheme`
//  (AppearanceStore), `mm.demoMode` (UserDemoMode), `mb.language.pref`'s
//  bootstrap (MBLocalization).
//

import Foundation

/// The Face-ID app-lock preference. (Its old home, the dead second lock screen
/// AppLockGate, is deleted — GatePhase.LockScreen is the live lock.)
enum AppLockPrefs {
    static let key = "mb.requireBiometricUnlock"
    /// Marks that the default below has been applied once, so a person who
    /// deliberately turns the lock OFF is never re-opted-in on a later launch.
    private static let seededKey = "mb.requireBiometricUnlock.seeded"

    /// The launch lock is ON by default (owner ruling 2026-08-31).
    ///
    /// It is now the app's ONE authentication — every in-session prompt was
    /// removed on the strength of it — so it cannot be the off-by-default
    /// toggle it used to be, or the app would ship with no gate at all.
    ///
    /// Seeded, not forced: existing installs that already carry an explicit
    /// choice keep it, and anyone may still turn it off (a device with no
    /// enrolled biometrics must not be walled out of its own records —
    /// `BiometricGate` allows access when the device can't evaluate a policy,
    /// and the in-session gates re-arm themselves when the lock is off).
    static func seedDefaultIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
    }
}

enum DefaultsMigration {
    /// old key → new key. Empty new key = delete-only (dead feature residue).
    private static let renames: [(old: String, new: String)] = [
        ("useCompanyLogo", "mb.useCompanyLogo"),
        ("scheduleWorkdaysMask", "mb.scheduleWorkdaysMask"),
        ("scheduleOneJobAtATime", "mb.scheduleOneJobAtATime"),
        ("requireBiometricUnlock", AppLockPrefs.key),
        ("didGrandfatherReceiptReviewLink_v1", "mb.didGrandfatherReceiptReviewLink_v1"),
        ("didBackfillJobsFirstClass_v1", "mb.didBackfillJobsFirstClass_v1"),
        ("goldLifeIDPromptShown", ""),   // the soft-gate nudge is gone
        // The retired per-app profile cache (name, phone, home address, photo). Gold Life ID
        // owns that record (law 48), so this copy goes on the first launch of 3.3.0, signed
        // in or not (audit 2026-10-03 F38).
        ("gl_profile_cache", ""),
    ]

    static func runIfNeeded(_ defaults: UserDefaults = .standard) {
        for rename in renames {
            guard let value = defaults.object(forKey: rename.old) else { continue }
            if !rename.new.isEmpty, defaults.object(forKey: rename.new) == nil {
                defaults.set(value, forKey: rename.new)
            }
            defaults.removeObject(forKey: rename.old)
        }
    }
}
