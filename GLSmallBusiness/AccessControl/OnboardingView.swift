//
//  OnboardingView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The first screen for anyone without an active subscription. Uses Apple's `SubscriptionStoreView`
//  (a compliant paywall that shows title / length / price and links to the Terms of Use and Privacy
//  Policy) when products are available, with a friendly retry state if they can't load. Comp or
//  discounted access is handled by Apple offer codes via the built-in Redeem Code button — never a
//  custom code mechanism.
//

import SwiftUI
import StoreKit

struct OnboardingView: View {
    @Environment(SubscriptionManager.self) private var subs
    @State private var retrying = false
    @State private var restoring = false
    @State private var redeeming = false
    @State private var actionMessage: String?

    private let privacyURL = URL(string: "https://evolvedbygl.github.io/privacy/")!
    private let termsURL   = URL(string: "https://evolvedbygl.github.io/terms/")!

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if !subs.products.isEmpty {
            paywall
        } else if subs.loadState == .loading {
            loadingState
        } else {
            unavailableState
        }
    }

    // MARK: - States

    private var paywall: some View {
        SubscriptionStoreView(productIDs: SubscriptionManager.productIDs) {
            marketingHeader
        }
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .redeemCode)   // Apple offer-code redemption (compliant)
        .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
    }

    private var loadingState: some View {
        VStack(spacing: 28) {
            marketingHeader
            ProgressView("Loading plans…")
            Spacer()
            legalFooter
        }
        .padding()
    }

    private var unavailableState: some View {
        VStack(spacing: 22) {
            marketingHeader
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("Couldn’t load plans right now").font(.headline)
                Text("Check your connection and tap Retry — or restore a previous purchase or redeem an offer code below.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                retrying = true
                Task { await subs.loadProducts(); retrying = false }
            } label: {
                if retrying {
                    ProgressView()
                } else {
                    Text("Retry").fontWeight(.semibold).frame(maxWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)

            // Escape hatches that need NO product data, so an existing subscriber is never trapped on
            // this error screen (required for Restore by guideline 3.1.2; redemption stays Apple-native).
            VStack(spacing: 12) {
                Button {
                    Task {
                        restoring = true
                        do { try await AppStore.sync() }
                        catch { actionMessage = SubscriptionActions.restoreFailureMessage(for: error) }
                        restoring = false
                    }
                } label: {
                    if restoring { ProgressView() } else { Text("Restore Purchases") }
                }
                .disabled(restoring)

                Button("Redeem Code") { redeeming = true }
            }
            .font(.callout)

            Spacer()
            legalFooter
        }
        .padding()
        .offerCodeRedemption(isPresented: $redeeming) { result in
            if case .failure(let error) = result {
                actionMessage = SubscriptionActions.redeemFailureMessage(for: error)
            }
        }
        .alert("Subscription", isPresented: Binding(get: { actionMessage != nil },
                                                    set: { if !$0 { actionMessage = nil } })) {
            Button("OK", role: .cancel) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    // MARK: - Shared pieces

    /// Always-visible Terms of Use + Privacy Policy links. Required for subscription apps, and kept
    /// here so the links are present even when the paywall itself can't load.
    private var legalFooter: some View {
        HStack(spacing: 14) {
            Link("Terms of Use", destination: termsURL)
            Text("·").foregroundStyle(.secondary)
            Link("Privacy Policy", destination: privacyURL)
        }
        .font(.footnote)
        .padding(.bottom, 4)
    }

    private var marketingHeader: some View {
        VStack(spacing: 12) {
            Text("My Business")
                .font(.custom("Italianno-Regular", size: 56))
                .foregroundStyle(Color("AccentColor"))
            Text("Run your trade from your phone.")
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                feature("doc.text.fill", "Professional estimates & invoices")
                feature("camera.fill", "Scan & track receipts")
                feature("icloud.fill", "Private sync through your own iCloud")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color("AccentColor"))
                .frame(width: 26)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
