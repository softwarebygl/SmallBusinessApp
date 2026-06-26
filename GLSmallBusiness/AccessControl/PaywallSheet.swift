//
//  PaywallSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The upgrade paywall, shown as a sheet the moment a free user reaches a FreeTier cap, and from
//  Settings → Upgrade. Uses Apple's compliant `SubscriptionStoreView` (title / length / price plus
//  Terms-of-Use and Privacy-Policy links), with Restore Purchases and Apple offer-code redemption.
//  A gold grabber and a Close button match the app's other sheets. Everything the user already
//  created stays fully usable behind this sheet — subscribing only unlocks creating more.
//

import SwiftUI
import StoreKit

struct PaywallSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let privacyURL = URL(string: "https://evolvedbygl.github.io/privacy/")!
    private let termsURL   = URL(string: "https://evolvedbygl.github.io/terms/")!

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(GLColor.gold.render(in: colorScheme).opacity(0.6))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 2)

            SubscriptionStoreView(productIDs: SubscriptionManager.productIDs) {
                header
            }
            .storeButton(.visible, for: .restorePurchases)
            .storeButton(.visible, for: .redeemCode)   // Apple offer-code redemption (compliant)
            .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
            .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
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
                .font(.custom("Italianno-Regular", size: 56))
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
}

extension View {
    /// Presents the upgrade paywall as a sheet when `isPresented` becomes true.
    func paywallSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { PaywallSheet() }
    }
}
