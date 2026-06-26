//
//  AppGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The root gate. Decides what the user sees based on subscription status:
//    • active subscription → the app
//    • status still loading at launch → a brief splash (no onboarding flash)
//    • no subscription → onboarding / paywall
//  Status is tracked reactively with `.subscriptionStatusTask`, so subscribing, restoring,
//  renewing, redeeming an offer code, or expiring all flip the UI automatically.
//

import SwiftUI
import StoreKit

struct AppGate: View {
    @State private var subscribed = false
    @State private var statusResolved = false   // set ONLY when StoreKit actually reports a status
    @State private var timedOut = false          // last-resort backstop so we never trap on the splash

    var body: some View {
        Group {
            if subscribed || DemoMode.isActive {
                RootView()
            } else if statusResolved || timedOut {
                OnboardingView()
            } else {
                SplashView()
            }
        }
        .subscriptionStatusTask(for: SubscriptionManager.groupID) { taskState in
            switch taskState {
            case .loading:
                break
            case .failure:
                subscribed = false
                statusResolved = true
            case .success(let statuses):
                subscribed = statuses.contains {
                    [.subscribed, .inGracePeriod, .inBillingRetryPeriod].contains($0.state)
                }
                statusResolved = true
            @unknown default:
                statusResolved = true
            }
        }
        .task {
            // Last-resort backstop: if StoreKit never answers (e.g. no network on first launch), fall
            // through to the paywall rather than trapping the user on the splash. A subscriber is never
            // shown the paywall for good — `subscribed` flips to RootView the instant the status task
            // reports an active entitlement, even if it arrives after this fires. The window is generous
            // (8s) so the normal sub-second status read resolves first and no paywall flash occurs.
            try? await Task.sleep(for: .seconds(8))
            timedOut = true
        }
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
