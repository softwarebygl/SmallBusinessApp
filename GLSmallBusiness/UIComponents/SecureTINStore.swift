//
//  SecureTINStore.swift
//  GLSmallBusiness
//
//  The taxpayer ID (SSN/EIN) is the most sensitive piece of data in the app, so it is NOT kept in
//  the CloudKit-backed SwiftData store. It lives in the Keychain instead — encrypted by the Secure
//  Enclave, protected by device data-protection, and (when iCloud Keychain is on) end-to-end synced
//  across the owner's devices. The business profile's item is keyed to the signed-in Gold Life ID
//  (2026-09-29): another account on the same iPhone can never read it. Deleting the Gold Life ID
//  deletes the business item and every subcontractor's (`deleteAccountItems`, law 73, audit
//  2026-10-03 F58).
//

import Foundation
import Security

// Keychain/Security only — no main-actor state — so callers (model accessors) can read/write off-actor.
nonisolated enum SecureTINStore {
    /// A var ONLY so the DEBUG test-host boot can namespace it per process: the
    /// simulator Keychain is shared mutable state across every suite otherwise
    /// (suite review 2026-09-02). Never assigned in Release code.
    nonisolated(unsafe) static var service = "GLSecureTIN"

    // MARK: - The sample session

    /// "Explore with sample data" must never reach the real Keychain, in EITHER direction.
    /// Writing would replace the owner's own SSN/EIN in place — on this device and every device on
    /// their iCloud Keychain, with no second copy to fall back to — with a fictional number.
    /// Reading through would print the owner's REAL taxpayer ID on a fictional business's W-9 and
    /// 1099. So for the life of a sample session the whole store swaps to memory, and the values
    /// die with it exactly like the sample container does.
    ///
    /// Fenced HERE and not at the call sites on purpose. There are six ways in — the seed, the
    /// business TIN form, the subcontractor TIN form, the W-9 filler, the 1099 filler, and the
    /// masked detail rows — and a single missed one is the entire hazard back. A future call site
    /// inherits the fence for free, which is the only version of this that stays fixed.
    nonisolated(unsafe) private(set) static var isSampleSession = false
    private static let sampleLock = NSLock()
    nonisolated(unsafe) private static var sampleValues: [String: String] = [:]

    /// Swaps the store to memory and discards anything a previous sample session left.
    static func beginSampleSession() {
        sampleLock.lock(); defer { sampleLock.unlock() }
        sampleValues = [:]
        isSampleSession = true
    }

    /// Returns to the real Keychain, discarding every value the sample session wrote.
    static func endSampleSession() {
        sampleLock.lock(); defer { sampleLock.unlock() }
        sampleValues = [:]
        isSampleSession = false
    }
    /// The pre-2026-09-29 business TIN account: ONE item per device, not tied to any Gold Life
    /// ID, so the next person to sign in on this iPhone could read it. Kept only as a migration
    /// source (never deleted — it may be the owner's only copy): the first signed-in read with no
    /// item of its own copies it to THAT account, once per device, and no account reads it again.
    static let legacyBusinessAccount = "com.evolvedbygl.GLSmallBusiness.w9tin"

    /// Records which account the legacy item went to, so it is copied exactly once. In the
    /// Keychain (not UserDefaults) because the sign-out wipe clears defaults and a reinstall keeps
    /// the Keychain — a defaults flag would let the next account migrate the same item again.
    static let legacyMigrationMarkerAccount = "com.evolvedbygl.GLSmallBusiness.w9tin.migratedTo"

    /// The business TIN account for one Gold Life ID (canonical id, path-safe like the store folder).
    static func businessAccount(for canonicalID: String) -> String {
        "\(legacyBusinessAccount).\(UserScopedStore.sanitized(canonicalID))"
    }

    // MARK: - Whose Tax ID (the signed-in Gold Life ID)

    private static let scopeLock = NSLock()
    nonisolated(unsafe) private static var _accountScope: String?

    /// The signed-in canonical account the business Tax ID belongs to, or nil when nobody is
    /// signed in. Set when the person's store mounts, cleared by the sign-out wipe. The Stripe
    /// install token is keyed by the same scope (StripeInstallTokenStore.signedInScope).
    static var accountScope: String? {
        scopeLock.lock(); defer { scopeLock.unlock() }
        return _accountScope
    }

    static func setAccountScope(_ canonicalID: String?) {
        scopeLock.lock(); defer { scopeLock.unlock() }
        let trimmed = canonicalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _accountScope = trimmed.isEmpty ? nil : trimmed
    }

    /// Keychain account for a subcontractor's TIN, derived from its stable `tinKey`.
    static func subcontractorAccount(_ key: String) -> String {
        "com.evolvedbygl.GLSmallBusiness.subtin.\(key)"
    }

    /// The business profile's stored taxpayer ID — the signed-in account's, never another's.
    static func read() -> String { readBusiness(scope: accountScope) }
    @discardableResult
    static func write(_ value: String) -> Bool { writeBusiness(value, scope: accountScope) }

    private static let migrationLock = NSLock()

    /// The business Tax ID for `scope`. No scope (signed out) reads nothing. `service` is
    /// injectable so a suite can use its own Keychain namespace.
    static func readBusiness(scope: String?, service: String = SecureTINStore.service) -> String {
        if isSampleSession { return read(account: legacyBusinessAccount) }
        guard let scope, !scope.isEmpty else { return "" }
        let account = businessAccount(for: scope)
        let own = read(account: account, service: service)
        guard own.isEmpty else { return own }
        // Once per device: hand the old unscoped item to the first account that reads with none
        // of its own, and record it so nobody else ever gets it. The old item is left in place.
        migrationLock.lock(); defer { migrationLock.unlock() }
        guard read(account: legacyMigrationMarkerAccount, service: service).isEmpty else { return "" }
        let legacy = read(account: legacyBusinessAccount, service: service)
        guard !legacy.isEmpty else { return "" }
        // Marker FIRST: if it can't be recorded, nothing is copied (the old item stays for a
        // later try), so a failed write can never let a second account migrate it too.
        guard write(sanitizedMarker(scope), account: legacyMigrationMarkerAccount, service: service),
              write(legacy, account: account, service: service) else { return "" }
        return legacy
    }

    /// Writes the business Tax ID for `scope`. Signed out, nothing is written (returns false).
    @discardableResult
    static func writeBusiness(_ value: String, scope: String?, service: String = SecureTINStore.service) -> Bool {
        if isSampleSession { return write(value, account: legacyBusinessAccount) }
        guard let scope, !scope.isEmpty else { return false }
        return write(value, account: businessAccount(for: scope), service: service)
    }

    // MARK: - Deleting the Gold Life ID

    /// Account DELETION (REQUIREMENTS law 73: "ALL data across ALL GL apps"; audit 2026-10-03 F58):
    /// the business Tax ID of `scope`, the old unscoped copy when it went to this account, and the
    /// Tax ID of every subcontractor in `subcontractorKeys`. Run while the store still holds those
    /// keys — once it is wiped, the items can never be found again. Another account's items are
    /// never touched (subcontractor items are found only through this account's own records).
    /// Straight to the Keychain, never the sample-session memory: deletion only happens signed in.
    @discardableResult
    static func deleteAccountItems(scope: String?, subcontractorKeys: [String],
                                   service: String = SecureTINStore.service) -> Bool {
        var deletedAll = true
        for key in Set(subcontractorKeys) where !key.isEmpty {
            deletedAll = deleteItem(account: subcontractorAccount(key), service: service) && deletedAll
        }
        guard let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty else {
            return deletedAll
        }
        deletedAll = deleteItem(account: businessAccount(for: scope), service: service) && deletedAll
        migrationLock.lock(); defer { migrationLock.unlock() }
        if readItem(account: legacyMigrationMarkerAccount, service: service) == sanitizedMarker(scope) {
            deletedAll = deleteItem(account: legacyBusinessAccount, service: service) && deletedAll
        }
        return deletedAll
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

    private static func sanitizedMarker(_ scope: String) -> String {
        let id = UserScopedStore.sanitized(scope)
        return id.isEmpty ? "migrated" : id
    }

    /// The stored taxpayer ID for `account`, or "" if none. Reads both synced and local items.
    static func read(account: String, service: String = SecureTINStore.service) -> String {
        if isSampleSession {
            sampleLock.lock(); defer { sampleLock.unlock() }
            return sampleValues[account] ?? ""
        }
        return readItem(account: account, service: service)
    }

    /// The Keychain item itself, whatever the session.
    private static func readItem(account: String, service: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    /// Replaces the stored taxpayer ID for `account`. Writing "" clears it. New items are
    /// iCloud-Keychain synchronizable and accessible only while the device is unlocked. Returns false
    /// if the write failed, so a silent loss of the most sensitive field can be noticed, not swallowed.
    @discardableResult
    static func write(_ value: String, account: String, service: String = SecureTINStore.service) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSampleSession {
            sampleLock.lock(); defer { sampleLock.unlock() }
            if trimmed.isEmpty { sampleValues.removeValue(forKey: account) } else { sampleValues[account] = trimmed }
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Clear path: writing "" deletes any existing copy (synced or local).
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            var delete = base
            delete[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let status = SecItemDelete(delete as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        // Write path: add, or update in place if one already exists. Never delete-before-add, so a
        // failed write can NEVER destroy the previously-stored value (the most sensitive field).
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrSynchronizable as String] = true
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var query = base
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status == errSecSuccess
    }
}
