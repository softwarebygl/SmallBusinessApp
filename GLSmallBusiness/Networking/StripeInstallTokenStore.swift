//
//  StripeInstallTokenStore.swift
//  GLSmallBusiness
//
//  The app's credential to the Stripe backend. A high-entropy random token kept in the Keychain (like
//  the Tax ID in SecureTINStore). The backend stores only a hash of it and uses it to decide which
//  Stripe connected account a caller owns.
//
//  ONE GOLD LIFE ID, ONE TOKEN (audit 2026-10-03 F2). The token used to be one item per device (and per
//  iCloud Keychain), never cleared: a second Gold Life ID signed in on the same iPhone sent invoices
//  whose Pay links were minted on the FIRST business's Stripe account, so customers paid the wrong
//  business. Now:
//    - the item is keyed by the signed-in canonical Gold Life ID (the SecureTINStore pattern), so
//      another account on the same iPhone reads nothing;
//    - it remembers the Stripe account the backend bound it to, and a pay link is minted only when that
//      account is the one the business profile names (SendPreparer);
//    - a session that ends deletes it (MBSessionPurge), and so does deleting the Gold Life ID;
//    - the pre-3.3.0 unscoped item moves to the signed-in account only when the server proves it is
//      that account's (`migrateLegacy`). It is deleted only on proof it is not (another account's,
//      or this Gold Life ID already has its own token); an answer without proof (today's server,
//      until C2 deploys) or no answer keeps it, unused, for a later try. Until C2 is live, existing
//      Stripe users therefore send no pay links on 3.3.0 (the send says "reconnect"), and they
//      recover on their own once it deploys.
//  The item stays `kSecAttrSynchronizable`, so the owner's other devices on the same Apple ID share it
//  (and a sign-out on one of them removes it for all of them; once C2 is live, "Reconnect this device"
//  resumes the same account). With iCloud Keychain off, a new device resumes through the synced account id and claim.
//

import Foundation
import Security

// Keychain/Security only — no main-actor state — so the (nonisolated) backend client can read off-actor.
nonisolated enum StripeInstallTokenStore {
    static let service = "GLStripeInstallToken"
    /// The pre-3.3.0 account name: ONE item per device, not tied to any Gold Life ID. Read only by the
    /// upgrade path below; never used to call the backend directly again.
    static let legacyAccount = "com.evolvedbygl.GLSmallBusiness.stripe.installtoken"

    /// The token's Keychain account for one Gold Life ID (canonical id, path-safe like the store folder).
    static func account(for canonicalID: String) -> String {
        "\(legacyAccount).\(UserScopedStore.sanitized(canonicalID))"
    }

    /// One account's token and the Stripe account the backend bound it to ("" = not known yet).
    struct Entry: Equatable, Sendable {
        var token: String
        var boundAccountId: String
    }

    /// The signed-in canonical Gold Life ID: the same scope every per-account Keychain item uses. Set
    /// when the person's store mounts, dropped by the sign-out wipe (SecureTINStore.accountScope).
    static var signedInScope: String? { SecureTINStore.accountScope }

    private static func keychainAccount(_ scope: String?) -> String? {
        let trimmed = scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : account(for: trimmed)
    }

    // MARK: - One account's token

    /// The token `scope` holds, or nil (signed out, or never linked). Reads synced and local items.
    static func load(for scope: String?, service: String = StripeInstallTokenStore.service) -> Entry? {
        guard let account = keychainAccount(scope) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        let bound = (attributes[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Entry(token: token, boundAccountId: bound)
    }

    /// Stores `entry` for `scope`, replacing any existing copy. Signed out, nothing is written.
    @discardableResult
    static func save(_ entry: Entry, for scope: String?, service: String = StripeInstallTokenStore.service) -> Bool {
        guard let account = keychainAccount(scope), !entry.token.isEmpty,
              let data = entry.token.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let bound = Data(entry.boundAccountId.utf8)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrGeneric as String] = bound
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrSynchronizable as String] = true
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var query = base
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrGeneric as String: bound] as CFDictionary)
        }
        return status == errSecSuccess
    }

    /// Records the Stripe account the backend just bound `scope`'s token to (the onboard answer).
    @discardableResult
    static func recordBoundAccount(_ accountId: String, for scope: String?,
                                   service: String = StripeInstallTokenStore.service) -> Bool {
        guard var entry = load(for: scope, service: service) else { return false }
        entry.boundAccountId = accountId
        return save(entry, for: scope, service: service)
    }

    /// Deletes `scope`'s token (synced and local copies). Signed out there is nothing to delete.
    @discardableResult
    static func delete(for scope: String?, service: String = StripeInstallTokenStore.service) -> Bool {
        guard let account = keychainAccount(scope) else { return true }
        return deleteItem(account: account, service: service)
    }

    /// A session ended for `scope` (sign-out, Stytch ended it, or the Gold Life ID was deleted): its
    /// token goes, and so does any pre-3.3.0 token still waiting on this device, so the next person to
    /// sign in finds neither. With no known account (a launch with nobody signed in) nothing is touched:
    /// those items may belong to someone signed in on another of the owner's devices.
    static func purgeSession(of scope: String?, service: String = StripeInstallTokenStore.service) {
        guard keychainAccount(scope) != nil else { return }
        delete(for: scope, service: service)
        deleteLegacy(service: service)
    }

    private static func deleteItem(account: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - The signed-in account (what the backend client and the screens use)

    /// Whether the signed-in account holds a token on this device (never mints). With the synced
    /// `stripeConnectedAccountId` present, `false` means THIS device has never linked to the backend
    /// for this account — the second-device / iCloud-Keychain-off state that needs the onboarding
    /// "resume" path before pay links can be minted here. Only onboarding may mint a token (see
    /// StripeBackendClient.onboard).
    static var exists: Bool { load(for: signedInScope) != nil }

    /// The signed-in account's token, or "" if none.
    static func read() -> String { load(for: signedInScope)?.token ?? "" }

    /// The signed-in account's token, generating and storing one on first use. "" when nobody is signed
    /// in or the Keychain refused the write: an unsaved token must never be bound on the server, or the
    /// binding would be lost with it.
    static func ensure() -> String {
        guard let scope = signedInScope else { return "" }
        if let existing = load(for: scope) { return existing.token }
        let token = generate()
        return save(Entry(token: token, boundAccountId: ""), for: scope) ? token : ""
    }

    /// Replaces the signed-in account's token (a new token is bound to nothing yet). "" deletes it.
    @discardableResult
    static func write(_ value: String) -> Bool {
        guard !value.isEmpty else { return delete(for: signedInScope) }
        return save(Entry(token: value, boundAccountId: ""), for: signedInScope)
    }

    // MARK: - The pre-3.3.0 token (upgrade path)

    static func readLegacy(service: String = StripeInstallTokenStore.service) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    /// Writes the unscoped item the way builds before 3.3.0 did. Only the tests seed it.
    @discardableResult
    static func writeLegacy(_ value: String, service: String = StripeInstallTokenStore.service) -> Bool {
        deleteLegacy(service: service)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return false }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteLegacy(service: String = StripeInstallTokenStore.service) -> Bool {
        deleteItem(account: legacyAccount, service: service)
    }

    static var hasLegacyToken: Bool { !readLegacy().isEmpty }

    /// What the server said about the pre-3.3.0 token, asked with the signed-in person's Gold Life
    /// token and the account their profile names.
    enum LegacyCheck: Equatable, Sendable {
        /// The server verified the Gold Life token AND that the token's account is the expected one.
        case matches
        /// The token belongs to another account or another Gold Life ID, or is bound to nothing.
        case mismatch
        /// The server answered without proof (a server that predates the Gold Life token). Proves
        /// nothing either way, so the token is kept for a server that can.
        case unverifiable
        /// No answer (offline, server busy): decide on a later try.
        case transient
    }

    enum LegacyMigration: Equatable, Sendable {
        case nothingToDo, moved, discarded, deferred
    }

    private static let migrationLock = NSLock()
    nonisolated(unsafe) private static var migrating = false

    /// The upgrade rule (audit 2026-10-03 C16): the unscoped token moves to `scope` only when the
    /// server proves it belongs to the account `profileAccountId` names. A proven mismatch, an
    /// account that already has its own token, or an empty profile account (callers pass one only
    /// for a profile that loaded and names none) delete it. No answer, or an answer without proof,
    /// keeps it for a later try; nobody can use it meanwhile (the client never mints or reads with
    /// it, only sends it to this proof call, and a session end purges it).
    static func migrateLegacy(scope: String?, profileAccountId: String,
                              service: String = StripeInstallTokenStore.service,
                              isCurrent: @Sendable (String) -> Bool = { $0 == StripeInstallTokenStore.signedInScope },
                              verify: @Sendable (_ legacyToken: String, _ expectedAccountId: String) async -> LegacyCheck)
        async -> LegacyMigration {
        guard let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty else { return .nothingToDo }
        let legacy = readLegacy(service: service)
        guard !legacy.isEmpty else { return .nothingToDo }
        guard load(for: scope, service: service) == nil else {
            deleteLegacy(service: service)
            return .discarded
        }
        let expected = profileAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else {
            deleteLegacy(service: service)
            return .discarded
        }
        guard beginMigration() else { return .deferred }
        defer { endMigration() }

        switch await verify(legacy, expected) {
        case .matches:
            // The person may have signed out (or switched) while the server answered.
            guard isCurrent(scope), readLegacy(service: service) == legacy else { return .deferred }
            if load(for: scope, service: service) != nil {
                deleteLegacy(service: service)
                return .discarded
            }
            guard save(Entry(token: legacy, boundAccountId: expected), for: scope, service: service) else {
                return .deferred
            }
            deleteLegacy(service: service)
            return .moved
        case .mismatch:
            deleteLegacy(service: service)
            return .discarded
        case .unverifiable, .transient:
            return .deferred
        }
    }

    private static func beginMigration() -> Bool {
        migrationLock.lock(); defer { migrationLock.unlock() }
        guard !migrating else { return false }
        migrating = true
        return true
    }

    private static func endMigration() {
        migrationLock.lock(); defer { migrationLock.unlock() }
        migrating = false
    }

    // MARK: - Minting

    /// 32 cryptographically-random bytes, hex-encoded → a 64-char opaque bearer token.
    /// Internal, not private, so a test can call it twice and assert the two differ.
    /// Asserting the SHAPE of a minted token (64 lowercase hex characters) does not
    /// catch a generator that returns a constant - a mutation replacing this body with
    /// 64 zeros passed the whole suite, which would mean every install shared one
    /// predictable payments token.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Fallback to the system RNG — still cryptographically secure on Apple platforms.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
