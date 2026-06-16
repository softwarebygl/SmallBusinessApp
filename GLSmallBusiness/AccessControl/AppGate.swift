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
    @State private var statusKnown = false

    var body: some View {
        Group {
            if subscribed || DemoMode.isActive {
                RootView()
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
