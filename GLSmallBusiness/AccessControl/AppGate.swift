//
//  AppGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The root gate. Decides what the user sees based on access:
//    • has access (active subscription OR redeemed code) → the app
//    • subscription status still loading at launch         → a brief splash (no onboarding flash)
//    • no access                                           → onboarding / paywall
//  Subscription status is tracked reactively with `.subscriptionStatusTask`, so subscribing,
//  restoring, renewing, or expiring all flip the UI automatically — no one gets stranded.
//

import SwiftUI
import StoreKit

struct AppGate: View {
    @Environment(AccessManager.self) private var access

    @State private var subscribed = false
    @State private var statusKnown = false
    @State private var manageSubs = false
    @State private var hintDismissed = false

    private var hasCode: Bool { access.isEnabled(AccessFlag.unlimitedLifeAccess) }

    var body: some View {
        Group {
            if hasCode || subscribed || DemoMode.isActive {
                RootView()
                    .safeAreaInset(edge: .bottom) {
                        if showCancelHint { cancelHintBanner }
                    }
            } else if !statusKnown {
                SplashView()
            } else {
                OnboardingView()
            }
        }
        .subscriptionStatusTask(for: SubscriptionManager.groupID) { taskState in
            switch taskState {
            case .loading:
                break
            case .failure:
                subscribed = false
                statusKnown = true
            case .success(let statuses):
                subscribed = statuses.contains {
                    [.subscribed, .inGracePeriod, .inBillingRetryPeriod].contains($0.state)
                }
                statusKnown = true
            @unknown default:
                statusKnown = true
            }
        }
        .task {
            // Safety net: never sit on the splash forever if status is slow or unavailable.
            try? await Task.sleep(for: .seconds(3))
            statusKnown = true
        }
        .manageSubscriptionsSheet(isPresented: $manageSubs)
    }

    /// You're paying AND you hold a lifetime code — nudge to cancel so you're not double-charged.
    private var showCancelHint: Bool { subscribed && hasCode && !hintDismissed }

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

/// Brief branded placeholder shown only while the subscription status is being read at launch.
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
