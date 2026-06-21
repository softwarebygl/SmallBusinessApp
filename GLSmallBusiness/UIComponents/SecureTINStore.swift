//
//  SecureTINStore.swift
//  GLSmallBusiness
//
//  The taxpayer ID (SSN/EIN) is the most sensitive piece of data in the app, so it is NOT kept in
//  the CloudKit-backed SwiftData store. It lives in the Keychain instead — encrypted by the Secure
//  Enclave, protected by device data-protection, and (when iCloud Keychain is on) end-to-end synced
//  across the owner's devices. There is a single business profile, so one Keychain item is enough.
//

import Foundation
import Security

enum SecureTINStore {
    private static let service = "GLSecureTIN"
    /// The single business profile's TIN account. Subcontractors use per-record accounts via
    /// `subcontractorAccount(_:)`, so many TINs can coexist, each keyed by its owner's stable id.
    private static let businessAccount = "com.evolvedbygl.GLSmallBusiness.w9tin"

    /// Keychain account for a subcontractor's TIN, derived from its stable `tinKey`.
    static func subcontractorAccount(_ key: String) -> String {
        "com.evolvedbygl.GLSmallBusiness.subtin.\(key)"
    }

    /// The business profile's stored taxpayer ID (the original single-item API).
    static func read() -> String { read(account: businessAccount) }
    @discardableResult
    static func write(_ value: String) -> Bool { write(value, account: businessAccount) }

    /// The stored taxpayer ID for `account`, or "" if none. Reads both synced and local items.
    static func read(account: String) -> String {
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
    static func write(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Clear any existing copy (synced or local) first.
        var delete = base
        delete[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(delete as CFDictionary)

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrSynchronizable as String] = true
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // The delete hadn't propagated (e.g. a sync race) — update in place instead.
            var query = base
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status == errSecSuccess
    }
}
