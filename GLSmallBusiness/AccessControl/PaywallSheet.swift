//
//  PaywallSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The upgrade paywall, shown as a sheet the moment a free user reaches a FreeTier cap, and from
//  Settings → Upgrade. Uses Apple's compliant `SubscriptionStoreView` (title / length / price plus
//  Terms-of-Use and Privacy-Policy links), with Restore Purchases and Apple offer-code redemption.
//  When the App Store can't be reached, a branded retry state replaces the store so the user isn't
//  left staring at an empty sheet. A gold grabber tops the sheet per the app's drag-indicator
//  convention. Everything the user already created stays usable behind this sheet — subscribing only
//  unlocks creating more.
//

import SwiftUI
import StoreKit

struct PaywallSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subs

    @State private var retrying = false
    @State private var restoring = false

    private let privacyURL = URL(string: "https://softwarebygl.com/my-business/privacy")!
    private let termsURL   = URL(string: "https://softwarebygl.com/my-business/terms")!

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(GLColor.gold.render(in: colorScheme).opacity(0.6))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if subs.loadState == .failed && subs.products.isEmpty {
                unavailableState
            } else {
                SubscriptionStoreView(productIDs: SubscriptionManager.productIDs) {
                    header
                }
                .storeButton(.visible, for: .restorePurchases)
                .storeButton(.visible, for: .redeemCode)   // Apple offer-code redemption (compliant)
                .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
                .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .accessibilityLabel("Close")
        }
        .glAppearance(colorScheme)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("My Business")
                .font(.custom("Italianno-Regular", size: 56, relativeTo: .largeTitle))
                .foregroundStyle(GLColor.gold.render(in: colorScheme))
            Text("You’ve reached the free limit")
                .font(.headline)
            Text("Subscribe to add unlimited customers, estimates, invoices, jobs, and receipts. Everything you’ve already created stays yours either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    /// Shown when the subscription products can't be loaded (e.g. offline). Keeps the user oriented and
    /// offers a Retry + Restore instead of an empty store.
    private var unavailableState: some View {
        VStack(spacing: 20) {
            header
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Couldn’t reach the App Store")
                .font(.headline)
            Text("Check your connection and try again.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                retrying = true
                Task { await subs.loadProducts(); retrying = false }
            } label: {
                if retrying { ProgressView() } else { Text("Retry").fontWeight(.semibold).frame(maxWidth: 200) }
            }
            .buttonStyle(.borderedProminent)
            .tint(GLColor.gold.render(in: colorScheme))

            Button {
                restoring = true
                Task { try? await AppStore.sync(); restoring = false }
            } label: {
                if restoring { ProgressView() } else { Text("Restore Purchases") }
            }
            .font(.callout)
            .disabled(restoring)
            Spacer()
        }
        .padding()
    }
}

extension View {
    /// Presents the upgrade paywall as a sheet when `isPresented` becomes true.
    func paywallSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { PaywallSheet() }
    }
}
