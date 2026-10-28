//
//  MBAIEntitlementTests.swift
//  GLSmallBusinessTests
//
//  Who the assistant is open to (contract A9 / A17): a CURRENT Pro + AI period or a comped
//  account — never plain Pro, never a grace period. The rules are one pure function over
//  StoreKit snapshots, so they are tested here without StoreKit.
//
//  Why not StoreKitTest: an SKTestSession purchase is process-wide. This test target runs its
//  suites in parallel inside the one host app, and dozens of tests read the subscription
//  (GLSubscription.shared reads `Transaction.currentEntitlements` when it first loads), so a
//  test purchase would leak into them. The live reads (`MBAILiveStoreKit`) are thin mappings
//  from StoreKit's own types onto the facts tested here.
//

import Foundation
import GoldLifeAI
import StoreKit
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MBAIEntitlementTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func txn(_ productID: String = SubscriptionManager.aiMonthlyID,
                     expiresIn seconds: TimeInterval? = 86_400,
                     revoked: Bool = false, upgraded: Bool = false, purchased: Bool = true,
                     jws: String = "jws") -> MBAITransactionFacts {
        MBAITransactionFacts(productID: productID,
                             expirationDate: seconds.map { now.addingTimeInterval($0) },
                             revocationDate: revoked ? now.addingTimeInterval(-60) : nil,
                             isUpgraded: upgraded,
                             isPurchasedByThisPerson: purchased,
                             jws: jws)
    }

    private final class FakeStoreKit: MBAIStoreKitReading {
        var transactions: [MBAITransactionFacts] = []
        var statuses: [MBAIStatusFacts] = []
        var statusFails = false
        func aiTransactions() async -> [MBAITransactionFacts] { transactions }
        func aiStatuses() async throws -> [MBAIStatusFacts] {
            if statusFails { throw CancellationError() }
            return statuses
        }
    }

    // MARK: The product setup

    @Test func onlyUnlimitedPlansExistBecauseAIIsBYOK() {
        let subs = SubscriptionManager.shared
        #expect(subs.entitlingProductIDs.count == 2)
        #expect(SubscriptionManager.productIDs == [SubscriptionManager.monthlyID, SubscriptionManager.annualID])
        #expect(subs.bundleID == "com.evolvedbygl.GLSmallBusiness")
        #expect(Bundle.main.bundleIdentifier == subs.bundleID, "the id the App Store signs receipts for")
    }

    /// The local StoreKit configuration matches what App Store Connect holds: only the two
    /// Unlimited (Pro) plans ($12.99 / month and $89.99 / year), no AI subscription tier.
    @Test func storeKitConfigurationContainsOnlyUnlimitedPlans() throws {
        let url = try #require(Bundle.main.url(forResource: "GLSmallBusiness", withExtension: "storekit"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        let group = try #require(groups.first { $0["id"] as? String == SubscriptionManager.groupID })
        let subs = try #require(group["subscriptions"] as? [[String: Any]])
        #expect(subs.count == 2)
        func product(_ id: String) throws -> [String: Any] {
            try #require(subs.first { $0["productID"] as? String == id })
        }
        for id in [SubscriptionManager.monthlyID, SubscriptionManager.annualID] {
            let entry = try product(id)
            #expect(entry["groupNumber"] as? Int == 2)
            let intro = try #require(entry["introductoryOffer"] as? [String: Any])
            #expect(intro["paymentMode"] as? String == "free")
            #expect(intro["subscriptionPeriod"] as? String == "P1M")
            #expect(intro["numberOfPeriods"] as? Int == 1)
        }
        #expect(subs.first { $0["productID"] as? String == SubscriptionManager.aiMonthlyID } == nil)
        #expect(subs.first { $0["productID"] as? String == SubscriptionManager.aiAnnualID } == nil)
    }

    // MARK: The decision

    @Test func aCurrentProPlusAIPeriodIsEntitledAndHandsOverItsJWS() {
        let decision = MBAIEntitlement.decide(transactions: [txn(jws: "signed")], statuses: [], now: now)
        #expect(decision.current?.jws == "signed")
        #expect(decision.renewalIssue == nil && !decision.statusUnknown)
    }

    @Test func plainProExpiredRevokedUpgradedOrSharedIsNotEntitled() {
        let notCurrent: [MBAITransactionFacts] = [
            txn(SubscriptionManager.monthlyID),            // plain Pro
            txn(SubscriptionManager.annualID),
            txn(expiresIn: -1),                            // ended a second ago
            txn(expiresIn: 0),                             // ends exactly now: not "> now"
            txn(expiresIn: nil),                           // no expiry is never current
            txn(revoked: true),                            // refunded
            txn(upgraded: true),
            txn(purchased: false),                         // Family Sharing (off; server refuses)
            txn(jws: ""),
        ]
        for fact in notCurrent {
            #expect(MBAIEntitlement.decide(transactions: [fact], statuses: [], now: now).current == nil,
                    "\(fact) must not open the assistant")
        }
    }

    @Test func theLatestExpiryWinsAcrossMonthlyAndYearly() {
        let monthly = txn(SubscriptionManager.aiMonthlyID, expiresIn: 3_600, jws: "monthly")
        let yearly = txn(SubscriptionManager.aiAnnualID, expiresIn: 86_400 * 300, jws: "yearly")
        #expect(MBAIEntitlement.decide(transactions: [monthly, yearly], statuses: [], now: now).current?.jws == "yearly")
        #expect(MBAIEntitlement.decide(transactions: [yearly, monthly], statuses: [], now: now).current?.jws == "yearly")
    }

    /// A9: grace and billing retry are NOT entitled — the gate says "update your payment".
    @Test func graceAndBillingRetryAreRenewalIssuesNotAccess() {
        // In grace, currentEntitlements still lists the transaction, but its expiry has passed.
        let lapsed = txn(expiresIn: -3_600)
        let grace = MBAIEntitlement.decide(
            transactions: [lapsed],
            statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: .inGracePeriod)], now: now)
        #expect(grace.current == nil && grace.renewalIssue == .gracePeriod)

        let retry = MBAIEntitlement.decide(
            transactions: [],
            statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiAnnualID, state: .inBillingRetryPeriod)], now: now)
        #expect(retry.current == nil && retry.renewalIssue == .billingRetry)

        let both = MBAIEntitlement.decide(
            transactions: [],
            statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: .inGracePeriod),
                       MBAIStatusFacts(productID: SubscriptionManager.aiAnnualID, state: .inBillingRetryPeriod)], now: now)
        #expect(both.renewalIssue == .billingRetry)

        // A current period outranks any stale status.
        let renewed = MBAIEntitlement.decide(
            transactions: [txn()],
            statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: .inBillingRetryPeriod)], now: now)
        #expect(renewed.current != nil && renewed.renewalIssue == nil)
    }

    @Test func expiredOrRevokedStatusesAreSimplyNotEntitled() {
        for state in [Product.SubscriptionInfo.RenewalState.expired, .revoked] {
            let decision = MBAIEntitlement.decide(
                transactions: [], statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: state)], now: now)
            #expect(decision == .init(current: nil, renewalIssue: nil, statusUnknown: false))
        }
        #expect(MBAIEntitlement.decide(transactions: [], statuses: [], now: now)
                == .init(current: nil, renewalIssue: nil, statusUnknown: false))
    }

    /// A17: when StoreKit can't confirm either way, never tell a maybe-payer to buy.
    @Test func anUnconfirmableAnswerIsUnknownNotUpgrade() {
        #expect(MBAIEntitlement.decide(transactions: [], statuses: nil, now: now).statusUnknown)
        let unsynced = MBAIEntitlement.decide(
            transactions: [], statuses: [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: .subscribed)], now: now)
        #expect(unsynced.statusUnknown && unsynced.current == nil)
        // A current period needs no status at all.
        #expect(MBAIEntitlement.decide(transactions: [txn()], statuses: nil, now: now).statusUnknown == false)
    }

    // MARK: Comped

    @Test func onlyTheServersCompAnswerCountsAsComped() {
        #expect(MBAIEntitlement.isCompSource(entitled: true, source: "owner"))
        #expect(MBAIEntitlement.isCompSource(entitled: true, source: "comp"))
        // /entitlement?app=my_business also says entitled for a paying subscriber.
        #expect(!MBAIEntitlement.isCompSource(entitled: true, source: "subscription"))
        #expect(!MBAIEntitlement.isCompSource(entitled: false, source: "owner"))
        #expect(!MBAIEntitlement.isCompSource(entitled: false, source: "none"))
    }

    // MARK: The observable object

    @Test func theObjectAnswersFromItsLastRefreshAndReadsCompLive() async {
        let store = FakeStoreKit()
        var comped = false
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { comped }, now: { now })
        // Before the first refresh nothing has been READ: a paying Pro + AI subscriber must not
        // meet Upgrade for the two StoreKit round-trips a cold launch takes (A17).
        #expect(!entitlement.hasLoaded && !entitlement.isAIEntitled)
        #expect(entitlement.subscriptionState == .unconfirmed)

        // Plain Pro only (no AI transactions reach the reader): Upgrade.
        await entitlement.refresh()
        #expect(entitlement.hasLoaded && !entitlement.isAIEntitled && entitlement.aiRenewalIssue == nil)
        #expect(entitlement.subscriptionState == .notEntitled)
        #expect(await entitlement.currentAIJWS() == nil)

        // A comp answer opens it at once, without a refresh.
        comped = true
        #expect(entitlement.isAIEntitled && entitlement.subscriptionState == .entitled)
        #expect(await entitlement.currentAIJWS() == nil, "a comped account sends no StoreKit proof")
        comped = false

        // Billing retry: payment issue, not Upgrade.
        store.statuses = [MBAIStatusFacts(productID: SubscriptionManager.aiMonthlyID, state: .inBillingRetryPeriod)]
        await entitlement.refresh()
        #expect(!entitlement.isAIEntitled && entitlement.aiRenewalIssue == .billingRetry)
        #expect(entitlement.subscriptionState == .paymentIssue)
        // …and comp still wins over a renewal issue.
        comped = true
        #expect(entitlement.aiRenewalIssue == nil && entitlement.subscriptionState == .entitled)
        comped = false

        // StoreKit couldn't answer: couldn't confirm.
        store.statuses = []
        store.statusFails = true
        await entitlement.refresh()
        #expect(entitlement.subscriptionState == .unconfirmed)

        // Bought Pro + AI.
        store.statusFails = false
        store.transactions = [txn(jws: "fresh-jws")]
        await entitlement.refresh()
        #expect(entitlement.isAIEntitled && entitlement.subscriptionState == .entitled)
        #expect(await entitlement.currentAIJWS() == "fresh-jws")
    }
}
