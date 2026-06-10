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

/// Named unlockable capabilities. The subscription gate keys off `unlimitedLifeAccess`;
/// add more flags here as you introduce new gated features.
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
/// Access is granted by EITHER:
///   1. an active subscription (set by the StoreKit layer — wired up next), or
///   2. a redeemed access-code flag (e.g. `UnlimitedLifeAccess`).
///
/// Redeemed flags persist on-device (enter a code once per device). A paid subscription,
/// once added, already follows the user across devices via their Apple ID.
@MainActor
@Observable
final class AccessManager {
    static let shared = AccessManager()

    /// Flags currently granted via redeemed codes (expired ones are excluded).
    private(set) var enabledFlags: Set<String> = []

    /// Set by the StoreKit subscription layer. `false` until that lands.
    var subscriptionActive = false

    @ObservationIgnored private let store = FlagStore()

    private init() {
        enabledFlags = store.activeFlags()
    }

    /// The app's master gate.
    var hasFullAccess: Bool {
        subscriptionActive || enabledFlags.contains(AccessFlag.unlimitedLifeAccess)
    }

    func isEnabled(_ flag: String) -> Bool { enabledFlags.contains(flag) }

    /// Attempt to redeem a user-typed code. On success the matching flag is enabled
    /// (forever, until a date, or for N days) and saved.
    @discardableResult
    func redeem(_ rawInput: String) -> RedeemResult {
        guard let entry = AccessCodes.match(rawInput) else { return .invalid }
        let expiry: Date?
        switch entry.grant {
        case .lifetime:
            expiry = nil
        case .until(let date):
            guard date > Date() else { return .expired }
            expiry = date
        case .days(let n):
            expiry = Calendar.current.date(byAdding: .day, value: n, to: Date())
        }
        store.enable(entry.flag, until: expiry)
        enabledFlags = store.activeFlags()
        return .success(flag: entry.flag, expires: expiry)
    }
}

/// On-device persistence for redeemed flags. Each flag stores an optional expiry
/// (`.distantFuture` == lifetime). Backed by `UserDefaults`.
struct FlagStore {
    private let key = "redeemedFlags.v1"

    private func raw() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return dict
    }

    private func write(_ dict: [String: Date]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func enable(_ flag: String, until: Date?) {
        var dict = raw()
        dict[flag] = until ?? .distantFuture
        write(dict)
    }

    /// Flags whose expiry is still in the future.
    func activeFlags() -> Set<String> {
        let now = Date()
        return Set(raw().filter { $0.value > now }.map(\.key))
    }
}
