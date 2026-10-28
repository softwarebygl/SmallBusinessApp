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
import GoldLifeUI

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
                    let isSubscribed = statuses.contains {
                        SubscriptionManager.entitledStates.contains($0.state)
                    }
                    subscription.applyLiveStatus(isSubscribed: isSubscribed)
                @unknown default:
                    subscription.statusKnown = true
                }
            }
            // The server's comp answer is NOT asked here any more: the launch gate asks it (with
            // StoreKit) before this view ever mounts — MBLaunchEntitlement, owner ruling
            // 2026-09-25 (8) — and a read still out when the person lands finishes on its own.
    }
}
