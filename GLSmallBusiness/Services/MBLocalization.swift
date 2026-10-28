//
//  MBLocalization.swift
//  GLSmallBusiness
//
//  In-app language choice (Adrian, 2026-08-21):
//  no AppleLanguages, no bundle swizzle, no restart.
//  The choice is a raw string in UserDefaults ("mb.language" — per the
//  separation-over-consolidation rule, never shared across apps),
//  owned by an @Observable singleton. MBLocalizedRoot at the app root reads the
//  observable and injects `.environment(\.locale, …)`, so every `Text` re-localizes
//  live the instant the picker changes. The injected locale is DEVICE REGION + chosen
//  language — money and dates keep the user's region; only the words change.
//
//  Imperative strings (alerts, labels built in code) must go through `mbLoc(...)` /
//  `MBLocalization.string(...)`: plain `String(localized:)` reads the DEVICE language
//  and would stay English after an in-app switch (found on device —
//  Text keys flipped instantly while code-built strings waited for a relaunch).
//

import SwiftUI
import Observation
import GoldLifeID

/// The language PICKER's options — the Gold Life Setting pattern (law 29):
/// Gold Life Setting → System → explicit values, Gold Life Setting the default.
/// Distinct from `MBAppLanguage` (the RESOLVED value the whole localization
/// engine runs on): the pref is what the person chose in the picker, the
/// resolved value is what that choice means on this device right now.
nonisolated enum MBLanguagePref: String, CaseIterable, Identifiable {
    case goldLife, system, en, es

    /// What the PICKER offers (owner ruling 2026-08-30, the three-tier
    /// hierarchy): Gold Life ID Setting (default) → System → explicit. The
    /// ACCOUNT's own value is edited on the Gold Life ID screen; an app-level
    /// pick here is a LOCAL override and never writes the account.
    static var pickerCases: [MBLanguagePref] { [.goldLife, .system, .en, .es] }

    var id: String { rawValue }

    /// Endonyms never translate; the two "follow something" rows do.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .goldLife: return "Gold Life ID Setting"
        case .system: return "System"
        case .en: return "English"
        case .es: return "Español"
        }
    }

}

/// The languages the app offers. English + Spanish only (owner decision 2026-08-21).
nonisolated enum MBAppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case es

    var id: String { rawValue }

    /// The BCP-47 language code to force, or nil to follow the device.
    var languageCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .es: return "es"
        }
    }

    /// The row label, shown in each language's OWN name so it's recognisable
    /// whatever language the app is currently in (Apple Settings does the same).
    /// `system` should read in the CURRENT language, so it stays a localizable key;
    /// the named languages are endonyms and never translate.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .es: return "Español"
        }
    }
}

@Observable
final class MBLocalization {
    static let shared = MBLocalization()

    // nonisolated: an immutable constant read by the nonisolated statics below.
    private nonisolated static let storageKey = "mb.language"
    private nonisolated static let prefKey = "mb.language.pref"
    private nonisolated static let accountCacheKey = "mb.language.account"
    /// Every key this store writes on the device: a sample session puts them back on Exit
    /// (law 42, `AppSettingsService.beginSampleSession`).
    nonisolated static let deviceKeys = [storageKey, prefKey, accountCacheKey]

    /// The RESOLVED language every localization path runs on. Persisted so the
    /// nonisolated statics below (which read the key directly) always agree with
    /// the observed instance. Internal setter ONLY so the unit target can pin the
    /// language around tests that assert English output (MM's twin rule — see
    /// MMLocalization.storageKey); app code goes through `setPref`.
    var language: MBAppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey) }
    }

    /// The person's picker choice (law 29 three-tier, 2026-08-30): Gold Life
    /// ID Setting follows the account, System follows the device, en/es are
    /// explicit LOCAL overrides — a pick here never writes the account.
    private(set) var pref: MBLanguagePref

    /// Internal (not private) only so the unit target can check that a fresh store arms the
    /// Gold Life ID follow at launch; app code always uses `shared`.
    init() {
        #if DEBUG
        // Screenshot determinism: -demoMode pins the appearance, so it pins the
        // language too - a leftover in-app choice on a screenshot simulator would
        // silently produce Spanish marketing shots. `-demoES` opts into Spanish
        // captures deliberately.
        if DemoMode.isActive {
            let demoPref: MBLanguagePref = ProcessInfo.processInfo.arguments.contains("-demoES") ? .es : .en
            pref = demoPref
            language = demoPref == .es ? .es : .en
            return
        }
        #endif
        let defaults = UserDefaults.standard
        // (The pre-law-29 legacy migration that lived here was dead on arrival:
        // the tier3 block below overwrote its result on the same first launch.
        // Removed 2026-08-30 audit.)
        // 2026-08-30 owner ruling (the three-tier hierarchy): the app-level
        // default is Gold Life ID Setting. One-shot migration back from the
        // short-lived explicit-only era.
        if defaults.string(forKey: "mb.language.tier3") == nil {
            defaults.set("done", forKey: "mb.language.tier3")
            defaults.set(MBLanguagePref.goldLife.rawValue, forKey: Self.prefKey)
        }
        let storedPref = MBLanguagePref(rawValue: defaults.string(forKey: Self.prefKey) ?? "") ?? .goldLife
        pref = storedPref
        language = Self.resolve(storedPref)
        followGoldLifeID()
    }

    /// What a pref means on this device right now. Gold Life ID Setting reads
    /// the cached ACCOUNT value ("system" / "en" / "es", kept current by
    /// `followGoldLifeID`); an account set to System follows the device,
    /// exactly like a local System pick.
    private nonisolated static func resolve(_ pref: MBLanguagePref) -> MBAppLanguage {
        switch pref {
        case .system: return .system
        case .en: return .en
        case .es: return .es
        case .goldLife:
            switch UserDefaults.standard.string(forKey: accountCacheKey) {
            case "en": return .en
            case "es": return .es
            default: return .system
            }
        }
    }

    /// The picker's entry point (three-tier, 2026-08-30): every choice here is
    /// a LOCAL override — the ACCOUNT value is edited only on the Gold Life ID
    /// screen. Applies immediately (live switch).
    func setPref(_ new: MBLanguagePref) {
        pref = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.prefKey)
        language = Self.resolve(new)
    }

    /// Re-reads the saved choice after a sample session put the owner's values back (law 42),
    /// so the app speaks the owner's language again the moment the sample ends.
    func reloadFromDefaults() {
        let storedPref = MBLanguagePref(rawValue: UserDefaults.standard.string(forKey: Self.prefKey) ?? "") ?? .goldLife
        pref = storedPref
        language = Self.resolve(storedPref)
    }

    /// Follows the language saved to the Gold Life ID (law 48: `me/language`, which the
    /// GoldLifeID package loads into `GoldLifeID.shared.identity` and its Language rows
    /// write). Audit 2026-10-03 F20: this app used to follow Stytch `gl_prefs`, which
    /// nothing writes any more, so a pick on the Gold Life ID screen never reached it.
    func followGoldLifeID() {
        follow { MBGoldLifeIDFollow.accountValue(Self.followedField) }
        followsGoldLifeID = true
    }

    /// The Gold Life ID field this store follows (a test pins it, so a swapped field fails).
    static let followedField: KeyPath<GoldLifeIdentity, String> = \.language

    /// True while the live follow reads the Gold Life ID record (set by `followGoldLifeID`,
    /// which `init` calls); a test stub passed to `follow` turns it off.
    @ObservationIgnored private(set) var followsGoldLifeID = false

    /// Which `follow` call is the live one; an older watch stops at its next change.
    @ObservationIgnored private var followGeneration = 0

    /// Follows `read` from now on: its current value is applied at once, and every change
    /// after that, live. A new call replaces the one before. Internal so the tests can follow
    /// a stub account.
    func follow(_ read: @escaping @MainActor @Sendable () -> String?) {
        followsGoldLifeID = false
        followGeneration += 1
        let generation = followGeneration
        if let value = read() { applyAccountLanguage(value) }
        MBGoldLifeIDFollow.watch(read,
                                 while: { [weak self] in self?.followGeneration == generation },
                                 apply: { [weak self] in self?.applyAccountLanguage($0) })
    }

    /// Caches the account's value ("system" / "en" / "es") for offline launches and
    /// re-renders every follower. An explicit app-level pick stands (law 29 three-tier).
    private func applyAccountLanguage(_ raw: String) {
        let value = ["en", "es"].contains(raw) ? raw : "system"
        UserDefaults.standard.set(value, forKey: Self.accountCacheKey)
        if pref == .goldLife { language = Self.resolve(.goldLife) }
    }

    /// Session hygiene (2026-08-30 audit): the account cache belongs to the person who
    /// owned the session. Called when the signed-in account CHANGES — the arriving
    /// person must not inherit the departed one's language.
    func clearAccountPrefState() {
        UserDefaults.standard.removeObject(forKey: Self.accountCacheKey)
        if pref == .goldLife { language = Self.resolve(.goldLife) }
    }

    /// Called on sign-in / session restore (after `clearAccountPrefState` on an account
    /// switch): applies the Gold Life ID's language now if its record is already loaded;
    /// later changes arrive through `followGoldLifeID`.
    func syncFromAccount() async {
        if let value = MBGoldLifeIDFollow.accountValue(Self.followedField) { applyAccountLanguage(value) }
    }

    /// The Locale to inject at the root: the device's region (currency, number,
    /// and date formatting) with the chosen language layered on top. `system`
    /// hands back the plain auto-updating device locale untouched.
    ///
    /// Reads `language` — the OBSERVED stored property — on purpose: that read is
    /// what registers Observation from any view body that calls `mbLoc` (via
    /// `string(_:)` → `locale`), so changing the language re-renders those views
    /// in place. Routing through the static (which reads UserDefaults directly)
    /// breaks live switching for imperative strings.
    var locale: Locale { Self.locale(for: language) }

    /// The chosen locale, readable from ANY isolation — reads UserDefaults and
    /// `Locale` directly, no actor-isolated state. NOT observation-tracked — only
    /// use it where the caller's re-render is already driven by something else.
    nonisolated static var currentLocale: Locale {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return locale(for: MBAppLanguage(rawValue: raw) ?? .system)
    }

    /// Device region + the given language. One place, so the observed instance
    /// path and the nonisolated static path can never disagree.
    nonisolated static func locale(for language: MBAppLanguage) -> Locale {
        guard let code = language.languageCode else { return .autoupdatingCurrent }
        // Start from the device locale so region/script/calendar are preserved,
        // then override ONLY the language code.
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents.languageCode = Locale.LanguageCode(code)
        return Locale(components: components)
    }

    /// The concrete language code the app is showing right now — the chosen one,
    /// or the device's mapped to what the app actually ships (en/es) for `system`.
    /// Handed to the web views so the embedded pages match the app's language.
    nonisolated static var resolvedLanguageCode: String {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        if let code = MBAppLanguage(rawValue: raw)?.languageCode { return code }
        let device = Locale.preferredLanguages.first ?? "en"
        return device.hasPrefix("es") ? "es" : "en"
    }

    /// Tag an in-app web-view URL with the app's current language, so the embedded
    /// page (privacy, terms, how-to) renders in the same language as the app. Adds
    /// `lang=<code>`; read it fresh at load time (compute the URL, don't cache it).
    /// My Business embeds follow prefers-color-scheme.
    ///
    /// Never traps: if the tagged address can't be formed, the page loads untagged (in its
    /// default language); if `base` isn't an address at all, nil — the caller shows its
    /// "couldn't load" state instead of crashing.
    nonisolated static func webURL(_ base: String) -> URL? {
        webURL(base, languageCode: resolvedLanguageCode)
    }

    /// Hosts whose `/embed/` pages stay inside the in-app web view.
    nonisolated static let embedHosts = ["apps.softwarebygl.com", "softwarebygl.com"]

    /// `webURL(_:)` for a given language code — the pure part, pinned by tests.
    nonisolated static func webURL(_ base: String, languageCode: String) -> URL? {
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: "\(base)\(separator)lang=\(languageCode)") ?? URL(string: base)
    }

    /// Localize a string from a `nonisolated` context (pure formatting helpers).
    /// Same chosen language as `string(_:)`, no actor hop.
    nonisolated static func string(_ keyAndValue: String.LocalizationValue) -> String {
        var resource = LocalizedStringResource(keyAndValue)
        resource.locale = currentLocale
        return String(localized: resource)
    }

    /// Localize an imperative string (one built in code, not handed to a SwiftUI
    /// `Text`) to the CURRENTLY chosen language. Reads `locale` on every call, so
    /// it tracks the live choice the same way the environment-driven `Text`s do.
    func string(_ keyAndValue: String.LocalizationValue) -> String {
        var resource = LocalizedStringResource(keyAndValue)
        resource.locale = locale
        return String(localized: resource)
    }

    /// Localize a DYNAMIC key — one whose text is only known at runtime and is
    /// used verbatim as its OWN catalog key (the carousel taglines, which arrive
    /// as data from the GoldLifeApps catalog). Falls back to the key itself when
    /// no translation exists, so an untranslated (new/remote) tagline still reads
    /// correctly rather than blank.
    func dynamic(_ key: String) -> String {
        var resource = LocalizedStringResource(stringLiteral: key)
        resource.locale = locale
        return String(localized: resource)
    }
}

/// Localize an imperative string to the app's CURRENT language — the terse call.
/// Supports interpolation — `mbLoc("Delete (\(count))")` builds the format key
/// and fills it in the chosen language.
func mbLoc(_ keyAndValue: String.LocalizationValue) -> String {
    MBLocalization.shared.string(keyAndValue)
}

/// Wraps the whole app and injects the chosen language as the environment locale.
///
/// Its own View (rather than an `.environment` on the App's Scene) so that reading
/// `loc.locale` here registers Observation on the language: the moment the picker
/// changes `language`, this view re-renders with the new locale, and every `Text`
/// beneath it re-localizes in place — no relaunch.
struct MBLocalizedRoot<Content: View>: View {
    @State private var loc = MBLocalization.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.environment(\.locale, loc.locale)
    }
}

/// Follows one value of the shared Gold Life ID record (law 48), for My Business's language
/// and appearance alike (audit 2026-10-03 F20). Observation reports a change before the new
/// value is stored, so each change is applied on the next main-actor turn, where the watch
/// also registers again; that read sees every change made since the report. A watch whose
/// `isCurrent` turns false stops.
@MainActor
enum MBGoldLifeIDFollow {
    /// The signed-in person's saved value, or nil while there is none to follow: signed
    /// out, or the record not loaded yet (a new person landing reads `.empty`), when the
    /// cached value must stand instead of flashing to System.
    static func accountValue(_ field: KeyPath<GoldLifeIdentity, String>) -> String? {
        let engine = GoldLifeID.shared
        return accountValue(sessionState: engine.sessionState, identity: engine.identity, field: field)
    }

    /// The rule behind `accountValue(_:)`, pure so the tests can pin it: a value only while
    /// signed in with the record loaded.
    static func accountValue(sessionState: GoldLifeSessionState,
                             identity: GoldLifeIdentity,
                             field: KeyPath<GoldLifeIdentity, String>) -> String? {
        guard sessionState == .signedIn, identity != .empty else { return nil }
        return identity[keyPath: field]
    }

    static func watch(_ read: @escaping @MainActor @Sendable () -> String?,
                      while isCurrent: @escaping @MainActor @Sendable () -> Bool,
                      apply: @escaping @MainActor @Sendable (String) -> Void) {
        guard isCurrent() else { return }
        withObservationTracking {
            _ = read()
        } onChange: {
            Task { @MainActor in
                guard isCurrent() else { return }
                if let value = read() { apply(value) }
                watch(read, while: isCurrent, apply: apply)
            }
        }
    }
}
