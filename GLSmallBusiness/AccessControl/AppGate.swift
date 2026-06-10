//
//  AppGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The root gate. Decides what the user sees based on access:
//    • has access (subscription OR redeemed code) → the app
//    • still checking the subscription at launch    → a brief splash (no onboarding flash)
//    • no access                                     → onboarding / paywall
//  Everything is reactive, so redeeming a code, subscribing, an expiry, or a revoked code
//  flips the UI automatically — the user can never get stranded in an invalid state.
//

import SwiftUI
import StoreKit

struct AppGate: View {
    @Environment(AccessManager.self) private var access
    @Environment(SubscriptionManager.self) private var subs

    @State private var manageSubs = false
    @State private var hintDismissed = false

    var body: some View {
        Group {
            if access.hasFullAccess {
                RootView()
                    .safeAreaInset(edge: .bottom) {
                        if showCancelHint { cancelHintBanner }
                    }
            } else if !subs.didLoadEntitlements {
                SplashView()
            } else {
                OnboardingView()
            }
        }
        .manageSubscriptionsSheet(isPresented: $manageSubs)
    }

    /// You're paying AND you hold a lifetime code — nudge to cancel so you're not double-charged.
    private var showCancelHint: Bool {
        subs.isSubscribed && access.isEnabled(AccessFlag.unlimitedLifeAccess) && !hintDismissed
    }

    private var cancelHintBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("You have lifetime access").font(.subheadline.weight(.semibold))
                Text("Cancel your subscription so you're not billed again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Manage") { manageSubs = true }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { hintDismissed = true } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Brief branded placeholder shown only while the subscription entitlement is being read at launch.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("My Business")
                    .font(.custom("Italianno-Regular", size: 52))
                    .foregroundStyle(Color("AccentColor"))
                ProgressView()
            }
        }
    }
}
