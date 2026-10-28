//
//  MBMoneyToolsTests.swift
//  GLSmallBusinessTests — AI
//
//  Verifies the 5 Money AI tools (list_bank_transactions, classify_transaction,
//  set_merchant_rule, list_subscriptions, update_subscription), Law 6 read-only
//  enforcement, Undo reversibility, sync deletion routing, and ReadOnlyGate
//  operation mapping.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
import GoldLifeMoney
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBMoneyToolsTests {

    @Test func listBankTransactionsFiltersAndReturnsRuleClassification() async throws {
        let world = try MBWriteWorld()
        let txn1 = BankTransaction(
            plaidTransactionId: "plaid_tx_1",
            plaidAccountId: "acc_biz",
            name: "THE HOME DEPOT #0214",
            merchantName: "Home Depot",
            amountCents: 14550,
            date: "2026-10-15"
        )
        let txn2 = BankTransaction(
            plaidTransactionId: "plaid_tx_2",
            plaidAccountId: "acc_pers",
            name: "NETFLIX.COM",
            merchantName: "Netflix",
            amountCents: 1599,
            date: "2026-10-16"
        )
        let rule = TransactionCategoryRule(
            normalizedMerchantPattern: TransactionRuleEngine.normalizeMerchant("Home Depot"),
            displayMerchantName: "Home Depot",
            isBusiness: true
        )
        world.context.insert(txn1)
        world.context.insert(txn2)
        world.context.insert(rule)
        world.context.saveChanges()

        let outAll = MBWriteHarness.output(
            await MBWriteHarness.run(world.box, "list_bank_transactions", ["classification": "all"])
        )
        #expect(outAll["total_matching"]?.intValue == 2)

        let outBiz = MBWriteHarness.output(
            await MBWriteHarness.run(world.box, "list_bank_transactions", ["classification": "business"])
        )
        #expect(outBiz["total_matching"]?.intValue == 1)
        let rows = outBiz["transactions"]?.arrayValue ?? []
        #expect(rows.first?["merchant_name"]?.stringValue == "Home Depot")
        #expect(rows.first?["is_business"]?.boolValue == true)
        #expect(rows.first?["is_rule_match"]?.boolValue == true)
    }

    @Test func classifyTransactionWritesActivityUndoAndRefusesWhenReadOnly() async throws {
        let world = try MBWriteWorld()
        let txn = BankTransaction(
            plaidTransactionId: "plaid_tx_classify",
            plaidAccountId: "acc_1",
            name: "SHELL OIL",
            merchantName: "Shell",
            amountCents: 4200,
            date: "2026-10-18",
            isBusinessOverride: nil
        )
        world.context.insert(txn)
        world.context.saveChanges()
        let txnID = try #require(txn.syncID).uuidString

        // Lapsed & offline refuse (Law 6)
        let lapsedOutcome = await MBWriteHarness.run(
            world.box,
            "classify_transaction",
            ["transaction_id": .string(txnID), "is_business": true],
            state: .lapsed
        )
        #expect(MBWriteHarness.failureReason(lapsedOutcome) == "read_only_lapsed")

        let offlineOutcome = await MBWriteHarness.run(
            world.box,
            "classify_transaction",
            ["transaction_id": .string(txnID), "is_business": true],
            state: .offline
        )
        #expect(MBWriteHarness.failureReason(offlineOutcome) == "read_only_offline")
        #expect(txn.isBusinessOverride == nil)

        // Subscribed succeeds, emits activity, and supports Undo
        let okOutcome = await MBWriteHarness.run(
            world.box,
            "classify_transaction",
            ["transaction_id": .string(txnID), "is_business": true]
        )
        let out = MBWriteHarness.output(okOutcome)
        #expect(out["ok"]?.boolValue == true)
        #expect(txn.isBusinessOverride == true)
        #expect(MBWriteHarness.titles(okOutcome) == ["Classified transaction"])

        let revert = await MBWriteHarness.undoLatest(okOutcome)
        #expect(revert != nil)
        #expect(txn.isBusinessOverride == nil)
    }

    @Test func setMerchantRuleAppliesRetroactivelySupportsUndoAndRemovesViaSync() async throws {
        let world = try MBWriteWorld()
        let txn = BankTransaction(
            plaidTransactionId: "plaid_tx_hd",
            plaidAccountId: "acc_1",
            name: "THE HOME DEPOT #4410 FL",
            merchantName: "Home Depot",
            amountCents: 8900,
            date: "2026-10-19",
            isBusinessOverride: nil
        )
        world.context.insert(txn)
        world.context.saveChanges()

        // Create rule & retroactively classify matching transaction
        let createOutcome = await MBWriteHarness.run(
            world.box,
            "set_merchant_rule",
            ["merchant": "Home Depot", "is_business": true]
        )
        let createOut = MBWriteHarness.output(createOutcome)
        #expect(createOut["ok"]?.boolValue == true)
        #expect(createOut["updated_transactions"]?.intValue == 1)
        #expect(txn.isBusinessOverride == true)
        #expect(MBRecordLookup.all(TransactionCategoryRule.self, in: world.context).count == 1)

        // Undo reverts both the rule creation and the transaction override
        _ = await MBWriteHarness.undoLatest(createOutcome)
        #expect(MBRecordLookup.all(TransactionCategoryRule.self, in: world.context).isEmpty)
        #expect(txn.isBusinessOverride == nil)

        // Re-create and then remove rule
        _ = await MBWriteHarness.run(
            world.box,
            "set_merchant_rule",
            ["merchant": "Home Depot", "is_business": true]
        )
        #expect(MBRecordLookup.all(TransactionCategoryRule.self, in: world.context).count == 1)

        let removeOutcome = await MBWriteHarness.run(
            world.box,
            "set_merchant_rule",
            ["merchant": "Home Depot", "remove": true]
        )
        let removeOut = MBWriteHarness.output(removeOutcome)
        #expect(removeOut["removed"]?.boolValue == true)
        #expect(MBRecordLookup.all(TransactionCategoryRule.self, in: world.context).isEmpty)

        // Undo restores the deleted rule
        _ = await MBWriteHarness.undoLatest(removeOutcome)
        #expect(MBRecordLookup.all(TransactionCategoryRule.self, in: world.context).count == 1)
    }

    @Test func listAndUpdateSubscriptionsIncludeCancellationURLAndUndo() async throws {
        let world = try MBWriteWorld()
        let sub = RecurringSubscription(
            plaidStreamId: "stream_netflix",
            plaidAccountId: "acc_1",
            merchantName: "Netflix",
            amountCents: 2299,
            isoCurrencyCode: "USD",
            cadenceRaw: "monthly",
            lastDate: "2026-10-01",
            nextExpectedDate: "2026-11-01",
            isActive: true,
            isBusinessOverride: false
        )
        world.context.insert(sub)
        world.context.saveChanges()
        let subID = try #require(sub.syncID).uuidString

        let listOut = MBWriteHarness.output(
            await MBWriteHarness.run(world.box, "list_subscriptions", [:])
        )
        let subs = listOut["subscriptions"]?.arrayValue ?? []
        #expect(subs.count == 1)
        #expect(subs.first?["cancellation_url"]?.stringValue?.contains("netflix.com") == true)

        // Update subscription classification and active tracking
        let updateOutcome = await MBWriteHarness.run(
            world.box,
            "update_subscription",
            ["subscription_id": .string(subID), "is_business": true, "is_active": false]
        )
        let updateOut = MBWriteHarness.output(updateOutcome)
        #expect(updateOut["ok"]?.boolValue == true)
        #expect(sub.isBusinessOverride == true)
        #expect(sub.isActive == false)

        // Active-only list_subscriptions now excludes hidden subscription unless include_inactive is true
        let activeOnly = MBWriteHarness.output(
            await MBWriteHarness.run(world.box, "list_subscriptions", [:])
        )
        #expect((activeOnly["subscriptions"]?.arrayValue ?? []).isEmpty)

        let withInactive = MBWriteHarness.output(
            await MBWriteHarness.run(world.box, "list_subscriptions", ["include_inactive": true])
        )
        #expect((withInactive["subscriptions"]?.arrayValue ?? []).count == 1)

        // Undo restores previous classification and active state
        _ = await MBWriteHarness.undoLatest(updateOutcome)
        #expect(sub.isBusinessOverride == false)
        #expect(sub.isActive == true)
    }

    @Test func mapMoneyOperationCoversEveryGoldLifeMoneyOperationTag() {
        #expect(ReadOnlyGate.mapMoneyOperation("connectBank") == .connectBank)
        #expect(ReadOnlyGate.mapMoneyOperation("disconnectBank") == .disconnectBank)
        #expect(ReadOnlyGate.mapMoneyOperation("refreshBanks") == .refreshBanks)
        #expect(ReadOnlyGate.mapMoneyOperation("classifyTransaction") == .classifyTransaction)
        #expect(ReadOnlyGate.mapMoneyOperation("applyBulkRule") == .applyBulkRule)
        #expect(ReadOnlyGate.mapMoneyOperation("updateAccountDefault") == .updateAccountDefault)
        #expect(ReadOnlyGate.mapMoneyOperation("saveRule") == .saveRule)
        #expect(ReadOnlyGate.mapMoneyOperation("addRule") == .saveRule)
        #expect(ReadOnlyGate.mapMoneyOperation("deleteRule") == .deleteRule)
        #expect(ReadOnlyGate.mapMoneyOperation("toggleSubscriptionTracking") == .toggleSubscriptionTracking)
        #expect(ReadOnlyGate.mapMoneyOperation("updateSubscription") == .updateSubscription)
    }
}
