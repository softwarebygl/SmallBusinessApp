//
//  AppearanceStore.swift — the Gold Life Setting pattern (law 29), appearance half.
//
//  Every per-user preference picker offers, in order: Gold Life ID Setting → System → explicit
//  values, with Gold Life ID Setting the DEFAULT. "Gold Life ID Setting" is the value saved on
//  the person's Gold Life ID, following them across apps and devices; System and the explicit
//  values are per-device choices.
//
//  Where the account value LIVES (law 48): the Gold Life ID record's `appearance`
//  (`me/appearance`), loaded by the GoldLifeID package into `GoldLifeID.shared.identity`. This
//  store follows it (`followGoldLifeID`) and caches it for offline launches. (Before audit
//  2026-10-03 F20 it followed Stytch `untrusted_metadata.gl_prefs`, which nothing writes now.)
//
//  Who WRITES the account value (law 29 three-tier, 2026-08-30): ONLY the Gold Life ID screen's
//  Appearance rows (GoldLifeID package). The app-level picker is a LOCAL override and never
//  touches the account.
//
//  The core — the four options, the saved pick, the cached account value and how they resolve
//  to a color scheme — is GoldLifeUI's GLAppearanceStore (audit 2026-10-03 F158). This store keeps what is
//  My Business's: the mb.* keys and following the Gold Life ID record.
//

import SwiftUI
import GoldLifeUI
import GoldLifeID

/// The picker's options (owner ruling 2026-08-30, the three-tier hierarchy): Gold Life ID
/// Setting (default) → System → explicit — GoldLifeUI's, under the name this app's code uses.
typealias AppearancePref = GLAppearancePref

extension GLAppearancePref {
    /// The option's name in the app's chosen language.
    var label: String {
        switch self {
        case .goldLife: mbLoc("Gold Life ID Setting")
        case .system: mbLoc("System")
        case .light: mbLoc("Light")
        case .dark: mbLoc("Dark")
        }
    }
}

@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    /// The keys this store writes on the device (`mb.appearance`, `mb.appearance.account`):
    /// a sample session puts them back on Exit (law 42, `AppSettingsService.beginSampleSession`).
    static let deviceKeys = GLAppearanceStore.deviceKeys(keyPrefix: "mb")

    /// The package store that owns the keys, the pick and how it resolves to a color scheme.
    @ObservationIgnored private let core: GLAppearanceStore

    var pref: AppearancePref { core.pref }
    var accountValue: String? { core.accountValue }

    /// Internal (not private) only so the unit target can check that a fresh store arms the
    /// Gold Life ID follow at launch; app code always uses `shared`.
    init() {
        core = GLAppearanceStore(keyPrefix: "mb", legacyKeys: ["appColorScheme"])
        followGoldLifeID()
    }

    /// What `.preferredColorScheme` gets. nil = follow the device.
    var colorScheme: ColorScheme? { core.colorScheme }

    /// An app-level pick: LOCAL override only (three-tier, 2026-08-30) — the account value is
    /// edited on the Gold Life ID screen, never here.
    func set(_ new: AppearancePref) {
        core.set(new)
    }

    /// Re-reads the saved choice after a sample session put the owner's values back (law 42),
    /// so the owner's appearance returns the moment the sample ends.
    func reloadFromDefaults() {
        core.reloadFromDefaults()
    }

    /// Follows the appearance saved to the Gold Life ID (law 48: `me/appearance`, which the
    /// GoldLifeID package loads into `GoldLifeID.shared.identity` and its Appearance rows
    /// write). Audit 2026-10-03 F20: this app used to follow Stytch `gl_prefs`, which
    /// nothing writes any more, so a pick on the Gold Life ID screen never reached it.
    func followGoldLifeID() {
        follow { MBGoldLifeIDFollow.accountValue(Self.followedField) }
        followsGoldLifeID = true
    }

    /// The Gold Life ID field this store follows (a test pins it, so a swapped field fails).
    static let followedField: KeyPath<GoldLifeIdentity, String> = \.appearance

    /// True while the live follow reads the Gold Life ID record (set by `followGoldLifeID`,
    /// which `init` calls); a test stub passed to `follow` turns it off.
    @ObservationIgnored private(set) var followsGoldLifeID = false

    /// Which `follow` call is the live one; an older watch stops at its next change.
    @ObservationIgnored private var followGeneration = 0

    /// Follows `read` from now on (`MBGoldLifeIDFollow`): its current value is applied at
    /// once, and every change after that, live. A new call replaces the one before.
    /// Internal so the tests can follow a stub account.
    func follow(_ read: @escaping @MainActor @Sendable () -> String?) {
        followsGoldLifeID = false
        followGeneration += 1
        let generation = followGeneration
        if let value = read() { core.applyAccountAppearance(value) }
        MBGoldLifeIDFollow.watch(read,
                                 while: { [weak self] in self?.followGeneration == generation },
                                 apply: { [weak self] in self?.core.applyAccountAppearance($0) })
    }

    /// Session hygiene (2026-08-30 audit): the cache belongs to the departed account;
    /// the arriving person starts from System.
    func clearAccountPrefState() {
        core.clearAccountPrefState()
    }

    /// Called on sign-in / session restore (after `clearAccountPrefState` on an account
    /// switch): applies the Gold Life ID's appearance now if its record is already loaded;
    /// later changes arrive through `followGoldLifeID`.
    func syncFromAccount() async {
        if let value = MBGoldLifeIDFollow.accountValue(Self.followedField) { core.applyAccountAppearance(value) }
    }
}
