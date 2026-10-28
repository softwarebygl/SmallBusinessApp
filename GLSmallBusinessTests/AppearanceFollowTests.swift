//
//  AppearanceFollowTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F20, appearance half: an app left on Gold Life ID Setting follows the
//  appearance saved to the Gold Life ID (`GoldLifeID.shared.identity.appearance`, written by
//  the package's Appearance rows), live. Before the fix it followed Stytch `gl_prefs`, which
//  nothing writes, and stayed on the device setting.
//

import Testing
import SwiftUI
import GoldLifeID
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct AppearanceFollowTests {

    @Test func goldLifeIDAppearancePickSwitchesTheApp() async {
        let store = AppearanceStore.shared
        let savedPref = store.pref
        let savedCache = UserDefaults.standard.string(forKey: "mb.appearance.account")
        defer {
            UserDefaults.standard.set(savedCache, forKey: "mb.appearance.account")
            store.set(savedPref)
            store.followGoldLifeID()
        }
        let account = StubGoldLifeIDAccount(appearance: "light")
        store.follow { account.appearance }
        store.set(.goldLife)

        account.appearance = "dark"                   // the package's Dark row
        await waitForFollow { store.colorScheme == .dark }
        #expect(store.colorScheme == .dark, "Gold Life ID Setting must follow the Gold Life ID's appearance")
        #expect(UserDefaults.standard.string(forKey: "mb.appearance.account") == "dark")

        account.appearance = "system"
        await waitForFollow { store.colorScheme == nil }
        #expect(store.colorScheme == nil)

        // An explicit app-level pick stands.
        store.set(.light)
        account.appearance = "dark"
        await waitForFollow { UserDefaults.standard.string(forKey: "mb.appearance.account") == "dark" }
        #expect(store.colorScheme == .light)
    }

    /// The appearance store follows the record's appearance field, never another one.
    @Test func appearanceFollowsTheAppearanceField() {
        var identity = GoldLifeIdentity.demo
        identity.language = "es"
        identity.appearance = "dark"
        #expect(AppearanceStore.followedField == \GoldLifeIdentity.appearance)
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: identity,
                                                field: AppearanceStore.followedField) == "dark")
    }

    /// Launch arms the follow: a fresh store reads the Gold Life ID record from the start.
    @Test func launchArmsTheGoldLifeIDFollow() {
        #expect(AppearanceStore().followsGoldLifeID, "init must call followGoldLifeID()")
    }
}
