//
//  SubscriptionManager.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  StoreKit 2 wrapper: loads products, tracks whether the user owns an active subscription,
//  and pushes that into the central AccessManager gate. Verification is cryptographic
//  (StoreKit's signed `VerificationResult`), so entitlements can't be forged on a normal device.
//

import Foundation
import StoreKit
import Observation

enum PurchaseOutcome { case success, pending, cancelled, failed }

@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    // Product IDs — must match the App Store Connect products (and the local .storekit file).
    static let monthlyID = "com.evolvedbygl.GLSmallBusiness.pro.monthly"
    static let annualID  = "com.evolvedbygl.GLSmallBusiness.pro.annual"
    static let productIDs = [monthlyID, annualID]

    enum LoadState { case loading, loaded, failed }

    private(set) var products: [Product] = []
    private(set) var loadState: LoadState = .loading
    private(set) var isSubscribed = false
    /// True once the first entitlement check finishes — lets the gate avoid an onboarding flash.
    private(set) var didLoadEntitlements = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    /// Recomputes whether the user currently owns an active auto-renewable subscription and pushes
    /// the result into the central gate. `currentEntitlements` already excludes expired/revoked.
    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result else { continue }
            if txn.productType == .autoRenewable && txn.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
        didLoadEntitlements = true
        AccessManager.shared.subscriptionActive = active
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let txn) = verification else { return .failed }
                await txn.finish()
                await refreshEntitlements()
                return .success
            case .pending:    return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .failed
            }
        } catch {
            return .failed
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Live updates: renewals, Ask-to-Buy approvals, refunds, purchases made elsewhere.
    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let txn) = update else { continue }
                await txn.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}
