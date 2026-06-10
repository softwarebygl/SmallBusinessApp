//
//  AccessManager.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Single source of truth for whether the user has full access to the app.
//

import Foundation
import Observation

/// Named unlockable capabilities. The subscription gate keys off `unlimitedLifeAccess`.
enum AccessFlag {
    static let unlimitedLifeAccess = "UnlimitedLifeAccess"
}

/// Outcome of redeeming an access code.
enum RedeemResult: Equatable {
    case success(flag: String, expires: Date?)
    case invalid
    case expired
}

/// The one place the rest of the app asks: "does this user have full access?"
///
/// Access is granted by EITHER an active subscription (StoreKit — wired up next) OR a redeemed
/// access-code flag. Redeemed flags are re-validated against the current code registry on every
/// launch, so removing a code from `AccessCodes` and shipping an update revokes it for everyone.
@MainActor
@Observable
final class AccessManager {
    static let shared = AccessManager()

    private(set) var enabledFlags: Set<String> = []

    @ObservationIgnored private let store = FlagStore()

    private init() { revalidate() }

    func isEnabled(_ flag: String) -> Bool { enabledFlags.contains(flag) }

    /// Re-checks stored grants against the CURRENT registry. A grant survives only if it hasn't
    /// expired AND the code that unlocked it is still present in `AccessCodes.registry`.
    func revalidate() {
        enabledFlags = store.activeFlags(registry: AccessCodes.registry)
    }

    /// Attempt to redeem a full `GL-XXXX-XXXX` code.
    @discardableResult
    func redeem(_ fullCode: String) -> RedeemResult {
        guard let entry = AccessCodes.match(fullCode) else { return .invalid }
        let expiry: Date
        switch entry.grant {
        case .lifetime:
            expiry = .distantFuture
        case .until(let date):
            guard date > Date() else { return .expired }
            expiry = date
        case .days(let n):
            expiry = Calendar.current.date(byAdding: .day, value: n, to: Date()) ?? .distantFuture
        }
        store.enable(entry.flag, codeHash: entry.codeHash, until: expiry)
        revalidate()
        return .success(flag: entry.flag, expires: expiry == .distantFuture ? nil : expiry)
    }
}

/// On-device persistence for redeemed flags. Each flag remembers the granting code's hash and an
/// expiry, so grants can be re-validated against the registry. Backed by `UserDefaults`.
struct FlagStore {
    private let key = "redeemedFlags.v2"

    private struct StoredGrant: Codable {
        let codeHash: String
        let expiry: Date
    }

    private func raw() -> [String: StoredGrant] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: StoredGrant].self, from: data)
        else { return [:] }
        return dict
    }

    private func write(_ dict: [String: StoredGrant]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func enable(_ flag: String, codeHash: String, until: Date) {
        var dict = raw()
        dict[flag] = StoredGrant(codeHash: codeHash, expiry: until)
        write(dict)
    }

    /// Flags still valid: not expired AND their granting code is still in the registry.
    func activeFlags(registry: [AccessCodes.Entry]) -> Set<String> {
        let now = Date()
        return Set(raw().compactMap { flag, grant -> String? in
            guard grant.expiry > now,
                  registry.contains(where: { $0.codeHash == grant.codeHash && $0.flag == flag })
            else { return nil }
            return flag
        })
    }
}
