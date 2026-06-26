//
//  AccessGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The single rule guarding every "new record" entry point: a user may create another record of a
//  given type if they're subscribed, or if they're still under that type's free cap (see FreeTier).
//
//  The same rule quietly handles a lapsed subscriber: someone who built 50 customers while paying,
//  then stopped, simply has count >= cap and isSubscribed == false, so they can't add a 51st — yet
//  every existing record stays fully viewable and editable. No separate read-only mode required.
//
//  We deliberately allow creation while the subscription status is still unknown (statusKnown ==
//  false), so a returning subscriber is never briefly walled on a cold launch before StoreKit
//  answers. Status normally resolves in well under a second.
//

import SwiftData

@MainActor
enum AccessGate {
    /// Whether the user may create another `T`. Pass the live `SubscriptionManager` and the cap for
    /// this type from `FreeTier`. The count is global (every record of that type, across all
    /// customers), matching how the free tier is metered.
    static func canCreate<T: PersistentModel>(_ type: T.Type, cap: Int,
                                              in context: ModelContext,
                                              subscription: SubscriptionManager) -> Bool {
        #if DEBUG
        if DemoMode.isActive { return true }   // screenshot / demo runs are never capped
        #endif
        if subscription.isSubscribed || !subscription.statusKnown { return true }
        let count = (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        return count < cap
    }
}
