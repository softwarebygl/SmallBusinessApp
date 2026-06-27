//
//  SubscriptionManager.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Loads the subscription products for the paywall and finishes incoming transactions.
//  Whether the user is *currently* subscribed is tracked reactively by `.subscriptionStatusTask`
//  in AppGate (the reliable, Apple-recommended way), which writes the result into the
//  `isSubscribed` / `statusKnown` flags below. AccessGate reads those app-wide to decide whether a
//  "new record" action is allowed or should open the paywall.
//

import Foundation
import StoreKit
import Observation

@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    static let monthlyID = "mybusiness.pro.monthly"
    static let annualID  = "mybusiness.pro.yearly"
    static let productIDs = [monthlyID, annualID]

    /// The App Store Connect subscription group ID — mirrored in GLSmallBusiness.storekit so
    /// status tracking behaves identically in local testing and in production.
    static let groupID = "22148954"

    enum LoadState { case loading, loaded, failed }

    private(set) var products: [Product] = []
    private(set) var loadState: LoadState = .loading

    /// Live entitlement, written by AppGate's `.subscriptionStatusTask` and read app-wide by
    /// AccessGate. `inGracePeriod` / `inBillingRetryPeriod` count as subscribed, so a card hiccup
    /// never walls a paying customer mid-renewal.
    var isSubscribed = false
    /// True once StoreKit has reported a status at least once. Until then the gate stays open so a
    /// returning subscriber is never blocked on a cold launch before the status read resolves.
    var statusKnown = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
        Task { await loadProducts() }
        Task { await refreshCachedEntitlement() }
    }

    /// Resolve entitlement from StoreKit's locally-cached `currentEntitlements`, which works OFFLINE.
    /// Without this, a cold launch while offline leaves `statusKnown` false, and AccessGate keeps the
    /// gate open — handing a capped free user unlimited creation for the session. AppGate's live
    /// `.subscriptionStatusTask` still overrides this with the authoritative result when online.
    func refreshCachedEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result,
               Self.productIDs.contains(txn.productID),
               txn.revocationDate == nil,
               (txn.expirationDate ?? .distantFuture) > .now {
                active = true
                break
            }
        }
        isSubscribed = active
        statusKnown = true
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    /// Finish transactions delivered at runtime (renewals, Ask-to-Buy approvals, etc.) so StoreKit
    /// doesn't keep redelivering them. Entitlement state is tracked by `.subscriptionStatusTask`.
    private func listenForTransactions() -> Task<Void, Never> {
        Task {
            for await update in Transaction.updates {
                if case .verified(let txn) = update { await txn.finish() }
            }
        }
    }
}
