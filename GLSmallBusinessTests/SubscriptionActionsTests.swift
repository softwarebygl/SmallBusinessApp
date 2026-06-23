//
//  SubscriptionActionsTests.swift
//  GLSmallBusinessTests
//
//  The Error -> user-message mapping behind Restore Purchases / Redeem Code. The point is the
//  offline path: a network failure must produce a clear, actionable message (not silence), while a
//  user cancellation must produce nothing (nil = no alert).
//

import Testing
import Foundation
import StoreKit
@testable import GLSmallBusiness

@MainActor
struct SubscriptionActionsTests {

    // MARK: - Restore

    @Test func restoreUserCancelledShowsNothing() {
        #expect(SubscriptionActions.restoreFailureMessage(for: StoreKitError.userCancelled) == nil)
    }

    @Test func restoreNetworkErrorMentionsConnection() {
        let msg = SubscriptionActions.restoreFailureMessage(
            for: StoreKitError.networkError(URLError(.notConnectedToInternet)))
        #expect(msg != nil)
        #expect(msg?.localizedCaseInsensitiveContains("connection") == true)
    }

    @Test func restoreStorefrontErrorMentionsRegion() {
        let msg = SubscriptionActions.restoreFailureMessage(for: StoreKitError.notAvailableInStorefront)
        #expect(msg?.localizedCaseInsensitiveContains("region") == true)
    }

    @Test func restoreGenericErrorGivesFallbackMessage() {
        let msg = SubscriptionActions.restoreFailureMessage(for: NSError(domain: "test", code: 42))
        #expect(msg != nil)
        #expect(msg?.isEmpty == false)
    }

    // MARK: - Redeem

    @Test func redeemUserCancelledShowsNothing() {
        #expect(SubscriptionActions.redeemFailureMessage(for: StoreKitError.userCancelled) == nil)
    }

    @Test func redeemNetworkErrorMentionsConnection() {
        let msg = SubscriptionActions.redeemFailureMessage(
            for: StoreKitError.networkError(URLError(.timedOut)))
        #expect(msg?.localizedCaseInsensitiveContains("connection") == true)
    }

    @Test func redeemGenericErrorGivesFallbackMessage() {
        let msg = SubscriptionActions.redeemFailureMessage(for: NSError(domain: "test", code: 7))
        #expect(msg != nil)
        #expect(msg?.isEmpty == false)
    }
}
