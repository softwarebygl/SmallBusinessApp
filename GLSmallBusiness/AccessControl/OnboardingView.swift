//
//  OnboardingView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The first screen for anyone without access: subscribe, or enter a GL access code.
//  Uses Apple's `SubscriptionStoreView` (compliant paywall — prices, auto-renew terms, restore,
//  and the required privacy/terms links handled for us).
//

import SwiftUI
import StoreKit

struct OnboardingView: View {
    @State private var showCode = false

    private let privacyURL = URL(string: "https://evolvedbygl.github.io/privacy/")!
    private let termsURL   = URL(string: "https://evolvedbygl.github.io/terms/")!

    var body: some View {
        SubscriptionStoreView(productIDs: SubscriptionManager.productIDs) {
            marketingHeader
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
        .safeAreaInset(edge: .bottom) {
            Button {
                showCode = true
            } label: {
                Text("Have a GL access code?")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 6)
            }
            .padding(.bottom, 4)
        }
        .sheet(isPresented: $showCode) {
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

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color("AccentColor"))
                .frame(width: 26)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
