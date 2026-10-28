//
//  MBLocalizationTests.swift
//  GLSmallBusinessTests
//
//  The in-app language switcher's contract: the chosen language drives both the
//  environment locale AND every mbLoc-built imperative string, while the REGION
//  (money, dates) always stays the device's. A regression here ships a half-
//  switched app — Text keys in one language, alerts in another.
//

import Testing
import Foundation
import Observation
import GoldLifeID
@testable import GLSmallBusiness

/// Stands in for `GoldLifeID.shared.identity` in the follow tests: the package's
/// Language and Appearance rows change exactly these values, and calling the real
/// engine here would write the account on the server.
@MainActor
@Observable
final class StubGoldLifeIDAccount {
    var language: String?
    var appearance: String?
    init(language: String? = nil, appearance: String? = nil) {
        self.language = language
        self.appearance = appearance
    }
}

/// Waits (bounded, about one second) for a follow to land: the follower applies a change on
/// the next main-actor turn, because Observation reports a change before the new value is stored.
@MainActor
func waitForFollow(_ done: @MainActor () -> Bool) async {
    for _ in 0..<200 where !done() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite(.serialized)
@MainActor
struct MBLocalizationTests {

    /// The injected locale overrides ONLY the language; region (and therefore
    /// currency/date conventions) stays the device's.
    @Test func localeOverridesLanguageAndPreservesRegion() {
        let es = MBLocalization.locale(for: .es)
        #expect(es.language.languageCode?.identifier == "es")
        #expect(es.region == Locale.autoupdatingCurrent.region)

        let en = MBLocalization.locale(for: .en)
        #expect(en.language.languageCode?.identifier == "en")

        // .system passes the device locale through untouched.
        #expect(MBLocalization.locale(for: .system).identifier == Locale.autoupdatingCurrent.identifier)
    }

    /// mbLoc resolves against the CHOSEN language, live — the exact behavior the
    /// sweep of 218 String(localized:) sites exists to guarantee.
    @Test func mbLocFollowsTheChosenLanguage() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        MBLocalization.shared.language = .es
        #expect(mbLoc("Customers") == "Clientes",
                "mbLoc should resolve Spanish when the app language is Español")

        MBLocalization.shared.language = .en
        #expect(mbLoc("Customers") == "Customers")
    }

    /// The nonisolated static path answers the same as the observed instance path —
    /// they must never disagree (documents vs UI would drift).
    @Test func staticAndInstancePathsAgree() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        MBLocalization.shared.language = .es
        #expect(MBLocalization.string("Customers") == MBLocalization.shared.string("Customers"))
        #expect(MBLocalization.currentLocale.language.languageCode?.identifier == "es")
    }

    /// The choice persists: setting the language writes the raw value to
    /// UserDefaults under the app's own key (never shared across apps).
    @Test func choicePersistsUnderTheAppKey() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        MBLocalization.shared.language = .es
        #expect(UserDefaults.standard.string(forKey: "mb.language") == "es")
    }

    /// English-pinned surfaces (customer text/email templates, accountant CSVs)
    /// must stay English whatever the UI language — a half-translated sentence is
    /// wrong in every configuration.
    @Test func englishLabelsIgnoreTheChosenLanguage() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        MBLocalization.shared.language = .es
        #expect(PaymentMethod.check.englishLabel == "Check")
        #expect(PaymentMethod.check.label == "Cheque",
                "the UI label should still follow the chosen language")
        #expect(PayType.hourly.englishLabel == "Hourly")
        #expect(W9TINType.ssn.englishLabel == "SSN")
    }

    /// The embed address carries the app's language and never traps (anti-crash): a base that
    /// already has a query gets `&`, and a base that isn't an address at all comes back nil, so
    /// the sheet shows its "couldn't load" state instead of a force-unwrap crash.
    @Test func webURLTagsTheLanguageAndNeverTraps() {
        let base = "https://apps.softwarebygl.com/embed/my-business/privacy"
        #expect(MBLocalization.webURL(base, languageCode: "es")?.absoluteString == base + "?lang=es")
        #expect(MBLocalization.webURL(base + "?theme=dark", languageCode: "en")?.absoluteString
                == base + "?theme=dark&lang=en")
        #expect(MBLocalization.webURL("http://[::1", languageCode: "en") == nil)
        #expect(MBLocalization.webURL("https://a b.com", languageCode: "es") == nil)

        // The live path reads the chosen language.
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        #expect(MBLocalization.webURL(base)?.absoluteString == base + "?lang=es")
        MBLocalization.shared.language = .en
        #expect(MBLocalization.webURL(base)?.absoluteString == base + "?lang=en")
        #expect(MBLocalization.webURL("http://[::1") == nil)
    }

    /// The Hours / Paychecks range segments and the entry-mode segments on the employee and
    /// subcontractor screens drew `Text(rawValue)` — English words verbatim in Spanish (found
    /// 2026-09-29). They draw their localized `title` now; no screen draws a raw value.
    @Test func segmentLabelsFollowTheChosenLanguage() throws {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        #expect(mbLoc("All") == "Todo")
        #expect(mbLoc("This year") == "Este año")
        #expect(mbLoc("Custom") == "Personalizado")
        #expect(mbLoc("Range") == "Rango")
        #expect(mbLoc("Hours") == "Horas")
        #expect(mbLoc("Dollars") == "Dólares")

        let screens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GLSmallBusiness/Screens")
        for name in ["EmployeeDetailScreen.swift", "SubcontractorDetailScreen.swift"] {
            let source = try String(contentsOf: screens.appendingPathComponent(name), encoding: .utf8)
            #expect(!source.contains("Text($0.rawValue)"), "\(name) draws a raw value")
            #expect(source.contains("Text($0.title)"), "\(name)")
        }
    }

    /// Audit 2026-10-03 F20: picking Español on the Gold Life ID screen (the package sets
    /// `GoldLifeID.shared.identity.language`) switches an app left on Gold Life ID Setting, live.
    /// Before the fix the app followed Stytch `gl_prefs`, which nothing writes, and stayed English.
    @Test func goldLifeIDLanguagePickSwitchesTheApp() async {
        let loc = MBLocalization.shared
        let savedPref = loc.pref
        let savedCache = UserDefaults.standard.string(forKey: "mb.language.account")
        defer {
            UserDefaults.standard.set(savedCache, forKey: "mb.language.account")
            loc.setPref(savedPref)
            loc.followGoldLifeID()
        }
        let account = StubGoldLifeIDAccount(language: "en")
        loc.follow { account.language }
        loc.setPref(.goldLife)
        loc.language = .en

        account.language = "es"                       // the package's Español row
        await waitForFollow { loc.language == .es }
        #expect(loc.language == .es, "Gold Life ID Setting must follow the Gold Life ID's language")
        #expect(mbLoc("Customers") == "Clientes", "imperative strings switch with it")
        #expect(UserDefaults.standard.string(forKey: "mb.language.account") == "es",
                "the account value is cached for the next offline launch")

        account.language = "en"                       // and back, without a relaunch
        await waitForFollow { loc.language == .en }
        #expect(loc.language == .en)

        // An explicit app-level pick is a local override: the account no longer moves it.
        loc.setPref(.en)
        account.language = "es"
        await waitForFollow { UserDefaults.standard.string(forKey: "mb.language.account") == "es" }
        #expect(UserDefaults.standard.string(forKey: "mb.language.account") == "es")
        #expect(loc.language == .en)
    }

    /// Before the Gold Life ID record loads (signed out, or a new person landing) there is no
    /// account value: the cached one stands instead of flashing to System.
    @Test func noAccountValueKeepsTheCachedLanguage() async {
        let loc = MBLocalization.shared
        let savedPref = loc.pref
        let savedCache = UserDefaults.standard.string(forKey: "mb.language.account")
        defer {
            UserDefaults.standard.set(savedCache, forKey: "mb.language.account")
            loc.setPref(savedPref)
            loc.followGoldLifeID()
        }
        UserDefaults.standard.set("en", forKey: "mb.language.account")
        let account = StubGoldLifeIDAccount(language: nil)
        loc.follow { account.language }
        loc.setPref(.goldLife)
        account.language = "es"
        await waitForFollow { loc.language == .es }
        #expect(loc.language == .es)
        account.language = nil
        await waitForFollow { false }
        #expect(loc.language == .es)
        #expect(UserDefaults.standard.string(forKey: "mb.language.account") == "es")
    }

    // MARK: The real road from the Gold Life ID record (audit 2026-10-03 F20, review round 1)

    /// A loaded Gold Life ID record: the demo identity with Español and Dark saved.
    private static var loadedIdentity: GoldLifeIdentity {
        var identity = GoldLifeIdentity.demo
        identity.language = "es"
        identity.appearance = "dark"
        return identity
    }

    /// Signed out or still resolving: nothing to follow, so the cached value stands.
    @Test(arguments: [GoldLifeSessionState.signedOut, .resolving])
    func noAccountValueUnlessSignedIn(_ state: GoldLifeSessionState) {
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: state, identity: Self.loadedIdentity,
                                                field: \.language) == nil)
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: state, identity: Self.loadedIdentity,
                                                field: \.appearance) == nil)
    }

    /// Signed in but the record not loaded yet (`.empty`): no value, never a flash to System.
    @Test func noAccountValueBeforeTheRecordLoads() {
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: .empty,
                                                field: \.language) == nil)
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: .empty,
                                                field: \.appearance) == nil)
    }

    /// Signed in with the record loaded: the saved values come through, each from its own field.
    @Test func signedInLoadedRecordGivesItsValues() {
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: Self.loadedIdentity,
                                                field: \.language) == "es")
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: Self.loadedIdentity,
                                                field: \.appearance) == "dark")
    }

    /// The language store follows the record's language field, never another one.
    @Test func languageFollowsTheLanguageField() {
        #expect(MBLocalization.followedField == \GoldLifeIdentity.language)
        #expect(MBGoldLifeIDFollow.accountValue(sessionState: .signedIn, identity: Self.loadedIdentity,
                                                field: MBLocalization.followedField) == "es")
    }

    /// Launch arms the follow: a fresh store reads the Gold Life ID record from the start.
    @Test func launchArmsTheGoldLifeIDFollow() {
        #expect(MBLocalization().followsGoldLifeID, "init must call followGoldLifeID()")
    }
}
