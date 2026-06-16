//
//  OnboardingView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The first screen for anyone without access: subscribe, or enter a GL access code.
//  Uses Apple's `SubscriptionStoreView` (compliant paywall) when products are available, and a
//  friendly retry state if they can't load — so the user always has a clear path, never a dead end.
//

import SwiftUI
import StoreKit

struct OnboardingView: View {
    @Environment(SubscriptionManager.self) private var subs
    @State private var showCode = false
    @State private var retrying = false

    private let privacyURL = URL(string: "https://evolvedbygl.github.io/privacy/")!
    private let termsURL   = URL(string: "https://evolvedbygl.github.io/terms/")!

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) { codeButton }
            .sheet(isPresented: $showCode) { codeSheet }
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
        .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
    }

    private var loadingState: some View {
        VStack(spacing: 28) {
            marketingHeader
            ProgressView("Loading plans…")
        }
        .padding()
    }

    private var unavailableState: some View {
        VStack(spacing: 22) {
            marketingHeader
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("Couldn't load plans right now").font(.headline)
                Text("Check your connection and tap Retry — or enter a GL code below.")
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
        }
        .padding()
    }

    // MARK: - Shared pieces

    private var codeButton: some View {
        Button { showCode = true } label: {
            Text("Have a GL access code?")
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 6)
        }
        .padding(.bottom, 4)
    }

    private var codeSheet: some View {
        NavigationStack {
            RedeemCodeView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCode = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
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
