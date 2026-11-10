//
//  SubscriptionStandingTests.swift — My Business's wiring of the purchase-history read and the
//  standing send (audit 2026-10-03 F15, F96 app half).
//
//  F15 happened because one argument went missing: the 2026-09-18 move to GLSubscription dropped
//  the `Transaction.all` read, and no test noticed, so no lapsed subscriber was ever read-only
//  again. These tests fail if `SubscriptionManager.shared` stops reading the history or stops
//  sending the latest transaction, and they pin the request the send makes.
//

import Foundation
import GoldLifeCloud
import GoldLifeUI
import Testing
@testable import GLSmallBusiness

@MainActor
struct SubscriptionStandingTests {

    @Test func theSharedSubscriptionReadsTheHistoryAndSendsTheLatestTransaction() {
        #expect(SubscriptionManager.shared.readsPurchaseHistory,
                "without the history read a lapsed subscriber is never read-only (F15)")
        #expect(SubscriptionManager.shared.recordsTransactions,
                "the server records My Business standing only from what the app sends (F96)")
    }

    @Test func theSendIsAPostOfTheJWSToTheStandingRoute() throws {
        let request = try #require(SubscriptionManager.standingRequest(jws: "header.payload.sig"))
        #expect(request.path == "entitlement/my-business")
        #expect(request.method == "POST")
        #expect(request.queryItems.isEmpty)
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == ["jws": "header.payload.sig"])
        guard case .sessionJwt = request.authMode else {
            Issue.record("the send must carry the Gold Life ID session")
            return
        }
    }

    @Test func theReplysStandingIsRead() {
        let lapsed = Data(#"{"ent":"lapsed","standing":"lapsed","expires_at":0}"#.utf8)
        #expect(SubscriptionManager.standing(fromReply: lapsed) == .lapsed)
        let retry = Data(#"{"ent":"active","standing":"billing_retry","expires_at":1}"#.utf8)
        #expect(SubscriptionManager.standing(fromReply: retry) == .billingRetry)
        #expect(SubscriptionManager.standing(fromReply: Data(#"{"standing":"someday"}"#.utf8)) == nil)
        #expect(SubscriptionManager.standing(fromReply: Data("not json".utf8)) == nil)
    }

    /// The history MB's shared subscription is given only ever counts My Business products.
    @Test func onlyMyBusinessProductsCountAsHistory() {
        let ids = Set(SubscriptionManager.shared.entitlingProductIDs.keys)
        #expect(ids == Set(SubscriptionManager.productIDs))
        let other = GLPastTransaction(productID: "com.evolvedbygl.myai.single.monthly",
                                      purchaseDate: .now, expirationDate: .now, isUpgraded: false, jws: "ai")
        #expect(!GLPurchaseHistory.summarize([other], entitlingProductIDs: ids).hasEverSubscribed)
    }

    @Test func isPaidMemberReflectsSubscribedVipAndDemoStanding() {
        let sub = SubscriptionManager.shared
        let expected = sub.isSubscribed || sub.serverEntitled || sub.isVip
        #expect(sub.isPaidMember == expected)
    }

    @Test func isMoneyEntitledUnlocksOnStoreKitUpgradeEvenWhenServerMoneyEntitledIsFalse() {
        let sub = SubscriptionManager.shared
        let priorIsSubscribed = sub.isSubscribed
        let priorEntitled = sub.serverEntitled
        let priorMoneyEntitled = sub.serverMoneyEntitled
        let priorSource = sub.serverSource
        let priorDemo = UserDemoMode.shared.isDemoActive
        defer {
            UserDemoMode.shared.isDemoActive = priorDemo
            sub.isSubscribed = priorIsSubscribed
            sub.setTestEntitlement(serverSource: priorSource, serverEntitled: priorEntitled, serverMoneyEntitled: priorMoneyEntitled)
        }

        UserDemoMode.shared.isDemoActive = false

        // Unsubscribed + unentitled -> locked
        sub.isSubscribed = false
        sub.setTestEntitlement(serverSource: "none", serverEntitled: false, serverMoneyEntitled: true)
        #expect(!sub.isMoneyEntitled, "serverMoneyEntitled without serverEntitled must never unlock Money")

        // Comped family user upgrades via StoreKit -> unlocked immediately even before server money_entitled flips
        sub.setTestEntitlement(serverSource: "comp", serverEntitled: true, serverMoneyEntitled: false)
        #expect(!sub.isMoneyEntitled)
        sub.isSubscribed = true
        #expect(sub.isMoneyEntitled)

        // Sample Data mode unlocks Money exploration with zero subscription
        sub.isSubscribed = false
        UserDemoMode.shared.isDemoActive = true
        #expect(sub.isMoneyEntitled)
    }

    @Test func compedUserHasPaidAccessButLockedMoney() {
        let sub = SubscriptionManager.shared
        let priorIsSubscribed = sub.isSubscribed
        let priorEntitled = sub.serverEntitled
        let priorMoneyEntitled = sub.serverMoneyEntitled
        let priorSource = sub.serverSource
        let priorDemo = UserDemoMode.shared.isDemoActive
        defer {
            UserDemoMode.shared.isDemoActive = priorDemo
            sub.isSubscribed = priorIsSubscribed
            sub.setTestEntitlement(serverSource: priorSource, serverEntitled: priorEntitled, serverMoneyEntitled: priorMoneyEntitled)
        }

        UserDemoMode.shared.isDemoActive = false
        sub.isSubscribed = false

        // Comped family account without money entitlement: Pro features active, Money locked
        sub.setTestEntitlement(serverSource: "comp", serverEntitled: true, serverMoneyEntitled: false)
        #expect(sub.isPaidMember)
        #expect(!sub.isMoneyEntitled)

        // Comped account WITH money entitlement: Pro and Money both unlocked
        sub.setTestEntitlement(serverSource: "comp", serverEntitled: true, serverMoneyEntitled: true)
        #expect(sub.isPaidMember)
        #expect(sub.isMoneyEntitled)
    }
}

