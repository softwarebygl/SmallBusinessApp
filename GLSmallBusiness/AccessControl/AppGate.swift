//
//  AppGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The app root. Everyone gets the full app for free up to the FreeTier caps, so this no longer
//  gates entry — it just keeps the shared subscription entitlement (`SubscriptionManager`) live via
//  Apple's `.subscriptionStatusTask`. The per-record AccessGate reads that entitlement to decide
//  when a "new record" action should open the paywall instead. Subscribing, restoring, renewing,
//  redeeming an offer code, or expiring all flip `isSubscribed` automatically.
//

import SwiftUI
import StoreKit

struct AppGate: View {
    @Environment(SubscriptionManager.self) private var subscription

    var body: some View {
        RootView()
            .subscriptionStatusTask(for: SubscriptionManager.groupID) { taskState in
                switch taskState {
                case .loading:
                    break
                case .failure:
                    // A StoreKit failure is transient (verification/network), NOT an authoritative
                    // "not subscribed". Do NOT flip isSubscribed false or mark the status known here —
                    // that would wall a real subscriber who is over a free cap. Leave the entitlement
                    // as-is (gate stays open while still unknown) and let the next .success resolve it.
                    break
                case .success(let statuses):
                    subscription.isSubscribed = statuses.contains {
                        [.subscribed, .inGracePeriod, .inBillingRetryPeriod].contains($0.state)
                    }
                    subscription.statusKnown = true
                @unknown default:
                    subscription.statusKnown = true
                }
            }
    }
}
