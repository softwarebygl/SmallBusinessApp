//
//  AccessGate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The rule guarding every "new record" entry point: a user may create another record of a given
//  type if they're subscribed, or if they're still under that type's free cap (see FreeTier).
//
//  A LAPSED subscriber is NOT that person (owner ruling, 2026-08-25). The old comment here said a
//  lapsed subscriber "simply has count >= cap ... yet every existing record stays fully viewable and
//  editable. No separate read-only mode required." That is now wrong twice over: a lapsed owner with
//  three customers was UNDER the cap and could keep creating, and editing was never blocked at all.
//  Lapsed is 100% read-only and lives in `ReadOnlyGate`; this gate calls into it so creation can
//  never take a different answer from the rest of the app. Someone who NEVER subscribed is
//  untouched and keeps the caps.
//
//  We deliberately allow creation while the subscription status is still unknown (statusKnown ==
//  false), so a returning subscriber is never briefly walled on a cold launch before StoreKit
//  answers. `SubscriptionManager.isLapsed` carries the same rule for the read-only side.
//

import SwiftData
import SwiftUI
import GoldLifeUI

@MainActor
enum AccessGate {

    /// Why creation was refused — and therefore WHICH explanation the person is owed. The two are
    /// different products and must never both appear: the paywall's "you've reached the free limit"
    /// is the wrong sentence for a lapsed subscriber, and an alert about reactivating is the wrong
    /// one for a free user who has simply filled their 15 invoices.
    enum CreateDecision: Equatable {
        case allowed
        /// Never-subscribed and at the free cap → the paywall.
        case atCap
        /// Subscribed before, not now → the read-only refusal (already logged and shown).
        case readOnly
    }

    /// The whole decision, with no side effects, so it can be unit-tested directly.
    static func decide<T: PersistentModel>(_ type: T.Type, cap: Int,
                                           in context: ModelContext,
                                           subscription: SubscriptionManager) -> CreateDecision {
        // Lapsed first: a lapsed subscriber UNDER the cap must still be refused, so this can never
        // fall through to the "count < cap" branch below.
        //
        // Ahead of the demo bypass too, and for the same reason `SubscriptionManager.isLapsed`
        // checks `-forceLapsed` ahead of `DemoMode.isActive`: `-demoMode -forceLapsed` exists
        // precisely so the read-only app can be looked at and driven with a seeded dataset. With
        // the bypass first, that combination handed a lapsed run `.allowed` and the QA override
        // could not reach creation at all. A plain `-demoMode` run is untouched — nothing is
        // lapsed unless something asked for it — and `DemoMode.isActive` is hard-false outside
        // DEBUG, so no shipped build has either branch.
        if subscription.isLapsed { return .readOnly }
        #if DEBUG
        if DemoMode.isActive { return .allowed }   // screenshot / demo runs are never capped
        #endif
        // Sample mode is never capped (law 15): it runs on a throwaway
        // in-memory container whose seed already exceeds the free caps, so
        // counting it would open the PAYWALL over fictional records — a claim
        // about capacity the person's real store hasn't used at all.
        if UserDemoMode.shared.isDemoActive { return .allowed }
        if subscription.isSubscribed || !subscription.statusKnown || subscription.isVip { return .allowed }
        let count = (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        return count < cap ? .allowed : .atCap
    }

    /// The call-site helper for an actual TAP: returns true when creation may go ahead, and
    /// otherwise has already told the person why — exactly once, and with the right explanation.
    ///
    /// One call rather than the old `if canCreate { … } else { showingPaywall = true }`, because
    /// that shape now has three outcomes and two of them need different words. Written as
    /// `if … else { paywall }` it would show a lapsed subscriber the refusal alert AND the paywall
    /// stacked on top of it.
    static func attemptCreate<T: PersistentModel>(_ type: T.Type, cap: Int,
                                                  in context: ModelContext,
                                                  subscription: SubscriptionManager,
                                                  operation: MBWriteOperation,
                                                  paywall: Binding<Bool>,
                                                  refusal: Binding<MBWriteOperation?>) -> Bool {
        switch decide(type, cap: cap, in: context, subscription: subscription) {
        case .allowed:
            return true
        case .atCap:
            paywall.wrappedValue = true
            return false
        case .readOnly:
            ReadOnlyGate.refuse(operation, into: refusal)
            return false
        }
    }
}
