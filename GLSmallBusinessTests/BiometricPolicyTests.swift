//
//  BiometricPolicyTests.swift — the "if we're in, we're in" ruling.
//
//  Owner ruling 2026-08-31: the ONLY Face ID prompt is the one that opens the
//  app. Every in-session gate was removed on the strength of that, so these
//  tests pin BOTH halves — the removals AND the launch lock that justifies
//  them. Losing the second silently would leave the app with no gate at all.
//
//  The source walk is the shared scanner (Harness/SourceScan.swift), whose own
//  self-tests prove it reads the whole app target.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct BiometricPolicyTests {

    /// The hard prompt survives in exactly three places: the launch lock, the
    /// all-subcontractor CSV export (every Tax ID, leaving the device), and the
    /// irreversible account delete. Anything else calling it is a regression
    /// back toward the 15-prompt app.
    ///
    /// The assistant's hand-off builder is the SAME all-subcontractor export reached by asking
    /// instead of tapping, so it carries the same hard prompt; every other tax surface it can
    /// reach (the W-9, a single 1099-NEC, the package's W-9) uses `authenticateInSession`, exactly
    /// as its screen does.
    @Test func onlySanctionedSurfacesPromptDuringASession() {
        var callers: [String] = []
        for file in GLSource.files() {
            for line in file.text.split(separator: "\n") where line.contains("BiometricGate.authenticate(") {
                callers.append((file.path as NSString).lastPathComponent)
            }
        }
        let sanctioned = Set(["GatePhase.swift", "SubcontractorsScreen.swift", "GoldLifeIDViews.swift",
                              "MBHandoffBuilder.swift",   // the same year-end export, asked for
                              "SignatureKit.swift"])   // SignatureKit declares it
        let strays = callers.filter { !sanctioned.contains($0) }.sorted()
        #expect(strays.isEmpty,
                "in-session Face ID prompts came back in: \(strays) — use authenticateInSession")
    }

    /// The launch lock is what every removal leaned on, so it must default ON.
    @Test func theLaunchLockDefaultsOn() {
        let defaults = UserDefaults(suiteName: "BiometricPolicyTests.fresh")!
        defaults.removePersistentDomain(forName: "BiometricPolicyTests.fresh")
        AppLockPrefs.seedDefaultIfNeeded(defaults)
        #expect(defaults.bool(forKey: AppLockPrefs.key),
                "a fresh install must open behind Face ID — it is the app's only gate now")
    }

    /// A deliberate OFF is never re-opted-in by a later launch.
    @Test func aDeliberateOptOutIsRespected() {
        let name = "BiometricPolicyTests.optedOut"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: AppLockPrefs.key)   // the person turned it off
        AppLockPrefs.seedDefaultIfNeeded(defaults)
        #expect(defaults.bool(forKey: AppLockPrefs.key) == false,
                "seeding must never override a choice the person already made")
        // And seeding twice is idempotent.
        AppLockPrefs.seedDefaultIfNeeded(defaults)
        #expect(defaults.bool(forKey: AppLockPrefs.key) == false)
    }
}
