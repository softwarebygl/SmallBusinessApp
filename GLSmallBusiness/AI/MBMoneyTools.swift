//
//  MBMoneyTools.swift
//  GLSmallBusiness — AI
//
//  Bank transaction search & classification, merchant categorization rules, and recurring
//  subscription inspection & management tools for GoldLifeAI Assistant.
//

import Foundation
import SwiftData
import GoldLifeAI
import GoldLifeUI
import GoldLifeMoney

// MARK: - list_bank_transactions

@MainActor
struct MBListBankTransactionsTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        let accountId = args.string("account_id")
        let classification = args.string("classification") // "all", "business", "personal"
        let query = args.string("query")
        let limit = args.int("limit") ?? 20

        let descriptor = FetchDescriptor<BankTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let rulesDescriptor = FetchDescriptor<TransactionCategoryRule>()

        guard let allTxns = try? store.fetch(descriptor),
              let rules = try? store.fetch(rulesDescriptor) else {
            return .result([
                "ok": .bool(true),
                "total_matching": .number(0),
                "transactions": .array([])
            ])
        }

        let liveRules = rules.filter { !$0.isDeleted }
        let filtered = allTxns.filter { txn in
            guard !txn.isDeleted else { return false }
            if let accountId, !accountId.isEmpty, txn.plaidAccountId != accountId {
                return false
            }
            let res = TransactionRuleEngine.effectiveClassification(for: txn, rules: liveRules)
            if classification == "business" && !res.isBusiness { return false }
            if classification == "personal" && res.isBusiness { return false }
            if let query, !query.isEmpty {
                return RecordSearch.matches(query, in: [txn.merchantName, txn.name, txn.date])
            }
            return true
        }

        let slice = filtered.prefix(max(1, min(limit, 100)))
        let items: [GLAIJSON] = slice.map { txn in
            let res = TransactionRuleEngine.effectiveClassification(for: txn, rules: liveRules)
            return .object([
                "id": .string(txn.syncID?.uuidString ?? ""),
                "merchant_name": .string(txn.merchantName),
                "name": .string(txn.name),
                "amount": .string(txn.amountDecimal.description),
                "amount_cents": .number(Double(txn.amountCents)),
                "date": .string(txn.date),
                "is_business": .bool(res.isBusiness),
                "is_rule_match": .bool(res.matchedRule != nil),
                "is_tracked_subscription": .bool(txn.isTrackedSubscription),
                "account_id": .string(txn.plaidAccountId)
            ])
        }

        return .result([
            "ok": .bool(true),
            "total_matching": .number(Double(filtered.count)),
            "transactions": .array(items)
        ])
    }
}

// MARK: - classify_transaction

@MainActor
struct MBClassifyTransactionTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        guard let idString = args.string("transaction_id"), let syncID = UUID(uuidString: idString) else {
            return MBToolFailure.invalid("transaction_id must be a valid UUID string.")
        }

        guard let isBusiness = args.bool("is_business") else {
            return MBToolFailure.invalid("is_business must be true or false.")
        }

        do {
            try DomainGate.requireWritable(.classifyTransaction, env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }

        var descriptor = FetchDescriptor<BankTransaction>(
            predicate: #Predicate { $0.syncID == syncID }
        )
        descriptor.fetchLimit = 1

        guard let txn = (try? store.fetch(descriptor))?.first(where: { !$0.isDeleted }) else {
            return .failure(GLAIFailure(
                reason: "not_found",
                message: "No bank_transaction has that id. Use list_bank_transactions to get the right id.",
                personReason: GLAIStrings.notAvailableHere,
                showsToPerson: false
            ))
        }

        let previousOverride = txn.isBusinessOverride
        txn.isBusinessOverride = isBusiness
        txn.updatedAt = Date()
        try? store.save()

        let merchant = txn.displayMerchantTitle
        let recordRef = GLAIRecordRef(kind: "bank_transaction", id: syncID.uuidString)
        let ledger = env.ledger
        let fp = Self.fingerprint(txn)
        ledger.note(recordRef.id, fp)

        let activity = GLAIActivity(
            kind: .updated,
            symbol: MBWriteSymbol.payment,
            title: MBWriteStrings.transactionClassified,
            detail: "\(merchant) → \(isBusiness ? "Business" : "Personal")",
            record: recordRef
        )

        let envCopy = env
        let undo = MBUndo.entry(
            recordRef,
            title: MBWriteStrings.undoTitle(transaction: merchant),
            ledger: ledger,
            fingerprint: {
                guard let ctx = envCopy.context() else { return nil }
                var fetch = FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.syncID == syncID })
                fetch.fetchLimit = 1
                guard let live = (try? ctx.fetch(fetch))?.first(where: { !$0.isDeleted }) else { return nil }
                return Self.fingerprint(live)
            },
            revert: {
                guard let ctx = envCopy.context() else { return MBUndo.recordGone }
                do {
                    try DomainGate.requireWritable(.classifyTransaction, envCopy.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                var fetch = FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.syncID == syncID })
                fetch.fetchLimit = 1
                guard let live = (try? ctx.fetch(fetch))?.first(where: { !$0.isDeleted }) else {
                    return MBUndo.recordGone
                }
                live.isBusinessOverride = previousOverride
                live.updatedAt = Date()
                try? ctx.save()
                ledger.note(recordRef.id, Self.fingerprint(live))
                return MBUndo.reverted(
                    .updated,
                    MBWriteSymbol.payment,
                    MBWriteStrings.transactionRestored,
                    detail: merchant,
                    record: recordRef
                )
            }
        )

        return .result(
            [
                "ok": .bool(true),
                "transaction_id": .string(syncID.uuidString),
                "merchant_name": .string(merchant),
                "is_business": .bool(isBusiness)
            ],
            activity: [activity],
            undo: undo
        )
    }

    private static func fingerprint(_ txn: BankTransaction) -> String {
        let flag = txn.isBusinessOverride.map { $0 ? "1" : "0" } ?? "nil"
        let stamp = txn.updatedAt.map { String(Int($0.timeIntervalSince1970 * 1_000)) } ?? "-"
        return "\(flag)|\(stamp)"
    }
}

// MARK: - set_merchant_rule

@MainActor
struct MBSetMerchantRuleTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    private struct TxnSnapshot: Sendable {
        let syncID: UUID
        let previousOverride: Bool?
        let previousRuleID: UUID?
    }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        guard let merchant = args.string("merchant") else {
            return MBToolFailure.invalid("merchant is required.")
        }
        let pattern = TransactionRuleEngine.normalizeMerchant(merchant)
        guard !pattern.isEmpty else {
            return MBToolFailure.invalid("merchant could not be normalized to a valid pattern.")
        }

        let remove = args.bool("remove") ?? false

        do {
            try DomainGate.requireWritable(remove ? .deleteRule : .saveRule, env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }

        let allRules = ((try? store.fetch(FetchDescriptor<TransactionCategoryRule>())) ?? []).filter { !$0.isDeleted }
        let existingRule = allRules.first(where: { $0.normalizedMerchantPattern == pattern })
        let ledger = env.ledger
        let envCopy = env

        if remove {
            guard let existingRule else {
                return .failure(GLAIFailure(
                    reason: "not_found",
                    message: "No merchant rule exists for '\(merchant)'.",
                    personReason: GLAIStrings.notAvailableHere,
                    showsToPerson: false
                ))
            }
            let ruleID = existingRule.syncID ?? UUID()
            let prevDisplay = existingRule.displayMerchantName
            let prevIsBiz = existingRule.isBusiness
            let recordRef = GLAIRecordRef(kind: "transaction_category_rule", id: ruleID.uuidString)

            store.deleteSynced(existingRule)
            try? store.save()
            ledger.note(recordRef.id, "deleted")

            let activity = GLAIActivity(
                kind: .deleted,
                symbol: MBWriteSymbol.deleted,
                title: MBWriteStrings.merchantRuleRemoved,
                detail: prevDisplay,
                record: recordRef
            )

            let undo = MBUndo.entry(
                recordRef,
                title: MBWriteStrings.undoTitle(merchantRule: prevDisplay),
                ledger: ledger,
                fingerprint: {
                    guard let ctx = envCopy.context() else { return nil }
                    let live = ((try? ctx.fetch(FetchDescriptor<TransactionCategoryRule>())) ?? [])
                        .first(where: { !$0.isDeleted && ($0.syncID == ruleID || $0.normalizedMerchantPattern == pattern) })
                    return live.map(Self.fingerprint) ?? "deleted"
                },
                revert: {
                    guard let ctx = envCopy.context() else { return MBUndo.recordGone }
                    do {
                        try DomainGate.requireWritable(.saveRule, envCopy.subscription())
                    } catch {
                        return MBWrite.revertFailure(error)
                    }
                    let restored = TransactionCategoryRule(
                        syncID: ruleID,
                        normalizedMerchantPattern: pattern,
                        displayMerchantName: prevDisplay,
                        isBusiness: prevIsBiz,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    ctx.insert(restored)
                    try? ctx.save()
                    ledger.note(recordRef.id, Self.fingerprint(restored))
                    return MBUndo.reverted(
                        .created,
                        MBWriteSymbol.payment,
                        MBWriteStrings.merchantRuleRestored,
                        detail: prevDisplay,
                        record: recordRef
                    )
                }
            )

            return .result(
                [
                    "ok": .bool(true),
                    "removed": .bool(true),
                    "normalized_pattern": .string(pattern)
                ],
                activity: [activity],
                undo: undo
            )
        }

        guard let isBusiness = args.bool("is_business") else {
            return MBToolFailure.invalid("is_business is required when creating or updating a merchant rule.")
        }

        let hadExisting = existingRule != nil
        let prevRuleIsBusiness = existingRule?.isBusiness ?? false
        let prevRuleDisplay = existingRule?.displayMerchantName ?? merchant

        let allTxns = ((try? store.fetch(FetchDescriptor<BankTransaction>())) ?? []).filter { !$0.isDeleted }
        let matchingSnapshots: [TxnSnapshot] = allTxns.compactMap { txn in
            let txnPattern = TransactionRuleEngine.normalizeMerchant(txn.merchantName.isEmpty ? txn.name : txn.merchantName)
            guard txnPattern == pattern, let id = txn.syncID else { return nil }
            return TxnSnapshot(
                syncID: id,
                previousOverride: txn.isBusinessOverride,
                previousRuleID: txn.matchedRuleSyncID
            )
        }

        TransactionRuleEngine.applyBulkRule(
            merchantName: merchant,
            isBusiness: isBusiness,
            transactions: allTxns,
            existingRules: allRules,
            insertRule: { store.insert($0) }
        )
        try? store.save()

        let updatedRules = ((try? store.fetch(FetchDescriptor<TransactionCategoryRule>())) ?? []).filter { !$0.isDeleted }
        guard let activeRule = updatedRules.first(where: { $0.normalizedMerchantPattern == pattern }) else {
            return MBToolFailure.unavailable
        }
        if activeRule.syncID == nil {
            activeRule.syncID = UUID()
            try? store.save()
        }
        let ruleID = activeRule.syncID ?? UUID()
        let recordRef = GLAIRecordRef(kind: "transaction_category_rule", id: ruleID.uuidString)
        ledger.note(recordRef.id, Self.fingerprint(activeRule))

        let activity = GLAIActivity(
            kind: hadExisting ? .updated : .created,
            symbol: MBWriteSymbol.payment,
            title: MBWriteStrings.merchantRuleSaved,
            detail: "\(merchant) → \(isBusiness ? "Business" : "Personal")",
            record: recordRef
        )

        let undo = MBUndo.entry(
            recordRef,
            title: MBWriteStrings.undoTitle(merchantRule: merchant),
            ledger: ledger,
            fingerprint: {
                guard let ctx = envCopy.context() else { return nil }
                let live = ((try? ctx.fetch(FetchDescriptor<TransactionCategoryRule>())) ?? [])
                    .first(where: { !$0.isDeleted && ($0.syncID == ruleID || $0.normalizedMerchantPattern == pattern) })
                return live.map(Self.fingerprint)
            },
            revert: {
                guard let ctx = envCopy.context() else { return MBUndo.recordGone }
                do {
                    try DomainGate.requireWritable(hadExisting ? .saveRule : .deleteRule, envCopy.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                let rulesNow = ((try? ctx.fetch(FetchDescriptor<TransactionCategoryRule>())) ?? []).filter { !$0.isDeleted }
                guard let liveRule = rulesNow.first(where: { $0.syncID == ruleID || $0.normalizedMerchantPattern == pattern }) else {
                    return MBUndo.recordGone
                }
                if hadExisting {
                    liveRule.isBusiness = prevRuleIsBusiness
                    liveRule.displayMerchantName = prevRuleDisplay
                    liveRule.updatedAt = Date()
                    ledger.note(recordRef.id, Self.fingerprint(liveRule))
                } else {
                    ctx.deleteSynced(liveRule)
                    ledger.note(recordRef.id, "deleted")
                }

                let txnsNow = ((try? ctx.fetch(FetchDescriptor<BankTransaction>())) ?? []).filter { !$0.isDeleted }
                let snapshotByID = Dictionary(uniqueKeysWithValues: matchingSnapshots.map { ($0.syncID, $0) })
                let now = Date()
                for txn in txnsNow {
                    if let id = txn.syncID, let snap = snapshotByID[id] {
                        txn.isBusinessOverride = snap.previousOverride
                        txn.matchedRuleSyncID = snap.previousRuleID
                        txn.updatedAt = now
                    }
                }
                try? ctx.save()
                return MBUndo.reverted(
                    hadExisting ? .updated : .deleted,
                    MBWriteSymbol.payment,
                    MBWriteStrings.merchantRuleRestored,
                    detail: merchant,
                    record: recordRef
                )
            }
        )

        return .result(
            [
                "ok": .bool(true),
                "rule_id": .string(ruleID.uuidString),
                "merchant": .string(merchant),
                "normalized_pattern": .string(pattern),
                "is_business": .bool(isBusiness),
                "updated_transactions": .number(Double(matchingSnapshots.count))
            ],
            activity: [activity],
            undo: undo
        )
    }

    private static func fingerprint(_ rule: TransactionCategoryRule) -> String {
        let flag = rule.isBusiness ? "1" : "0"
        let stamp = rule.updatedAt.map { String(Int($0.timeIntervalSince1970 * 1_000)) } ?? "-"
        return "\(rule.normalizedMerchantPattern)|\(flag)|\(stamp)"
    }
}

// MARK: - list_subscriptions

@MainActor
struct MBListSubscriptionsTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        let accountId = args.string("account_id")
        let classification = args.string("classification") // "all", "business", "personal"
        let includeInactive = args.bool("include_inactive") ?? false

        let descriptor = FetchDescriptor<RecurringSubscription>(
            sortBy: [SortDescriptor(\.nextExpectedDate)]
        )

        guard let allSubs = try? store.fetch(descriptor) else {
            return .result([
                "ok": .bool(true),
                "subscriptions": .array([])
            ])
        }

        let filtered = allSubs.filter { sub in
            guard !sub.isDeleted else { return false }
            if !includeInactive && !sub.isActive {
                return false
            }
            if let accountId, !accountId.isEmpty, sub.plaidAccountId != accountId {
                return false
            }
            let isBiz = sub.isBusinessOverride ?? false
            if classification == "business" && !isBiz { return false }
            if classification == "personal" && isBiz { return false }
            return true
        }

        let burn = SubscriptionBurnCalculator.calculateBurn(subscriptions: filtered)

        let items: [GLAIJSON] = filtered.map { sub in
            let cancelURL = SubscriptionCancellationCatalog.cancellationTarget(for: sub.merchantName).url.absoluteString
            return .object([
                "id": .string(sub.syncID?.uuidString ?? ""),
                "merchant_name": .string(sub.merchantName),
                "amount": .string(sub.amountDecimal.description),
                "amount_cents": .number(Double(sub.amountCents)),
                "cadence": .string(sub.cadenceRaw),
                "next_expected_date": .string(sub.nextExpectedDate),
                "is_business": .bool(sub.isBusinessOverride ?? false),
                "is_active": .bool(sub.isActive),
                "account_id": .string(sub.plaidAccountId),
                "cancellation_url": .string(cancelURL)
            ])
        }

        return .result([
            "ok": .bool(true),
            "monthly_burn": .string(burn.monthly.description),
            "annual_burn": .string(burn.annual.description),
            "total_subscriptions": .number(Double(filtered.count)),
            "subscriptions": .array(items)
        ])
    }
}

// MARK: - update_subscription

@MainActor
struct MBUpdateSubscriptionTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        guard let idString = args.string("subscription_id"), let syncID = UUID(uuidString: idString) else {
            return MBToolFailure.invalid("subscription_id must be a valid UUID string.")
        }

        let newIsBusiness = args.bool("is_business")
        let newIsActive = args.bool("is_active")
        guard newIsBusiness != nil || newIsActive != nil else {
            return MBToolFailure.invalid("Provide at least one of is_business or is_active.")
        }

        do {
            try DomainGate.requireWritable(.updateSubscription, env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }

        var descriptor = FetchDescriptor<RecurringSubscription>(
            predicate: #Predicate { $0.syncID == syncID }
        )
        descriptor.fetchLimit = 1

        guard let sub = (try? store.fetch(descriptor))?.first(where: { !$0.isDeleted }) else {
            return .failure(GLAIFailure(
                reason: "not_found",
                message: "No recurring_subscription has that id. Use list_subscriptions to get the right id.",
                personReason: GLAIStrings.notAvailableHere,
                showsToPerson: false
            ))
        }

        let prevIsBusiness = sub.isBusinessOverride
        let prevIsActive = sub.isActive

        if let newIsBusiness { sub.isBusinessOverride = newIsBusiness }
        if let newIsActive { sub.isActive = newIsActive }
        sub.updatedAt = Date()
        try? store.save()

        let merchant = sub.merchantName
        let recordRef = GLAIRecordRef(kind: "recurring_subscription", id: syncID.uuidString)
        let ledger = env.ledger
        ledger.note(recordRef.id, Self.fingerprint(sub))

        let activity = GLAIActivity(
            kind: .updated,
            symbol: MBWriteSymbol.payment,
            title: MBWriteStrings.subscriptionUpdated,
            detail: merchant,
            record: recordRef
        )

        let envCopy = env
        let undo = MBUndo.entry(
            recordRef,
            title: MBWriteStrings.undoTitle(subscription: merchant),
            ledger: ledger,
            fingerprint: {
                guard let ctx = envCopy.context() else { return nil }
                var fetch = FetchDescriptor<RecurringSubscription>(predicate: #Predicate { $0.syncID == syncID })
                fetch.fetchLimit = 1
                guard let live = (try? ctx.fetch(fetch))?.first(where: { !$0.isDeleted }) else { return nil }
                return Self.fingerprint(live)
            },
            revert: {
                guard let ctx = envCopy.context() else { return MBUndo.recordGone }
                do {
                    try DomainGate.requireWritable(.updateSubscription, envCopy.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                var fetch = FetchDescriptor<RecurringSubscription>(predicate: #Predicate { $0.syncID == syncID })
                fetch.fetchLimit = 1
                guard let live = (try? ctx.fetch(fetch))?.first(where: { !$0.isDeleted }) else {
                    return MBUndo.recordGone
                }
                live.isBusinessOverride = prevIsBusiness
                live.isActive = prevIsActive
                live.updatedAt = Date()
                try? ctx.save()
                ledger.note(recordRef.id, Self.fingerprint(live))
                return MBUndo.reverted(
                    .updated,
                    MBWriteSymbol.payment,
                    MBWriteStrings.subscriptionRestored,
                    detail: merchant,
                    record: recordRef
                )
            }
        )

        let cancelURL = SubscriptionCancellationCatalog.cancellationTarget(for: sub.merchantName).url.absoluteString
        return .result(
            [
                "ok": .bool(true),
                "subscription_id": .string(syncID.uuidString),
                "merchant_name": .string(merchant),
                "is_business": .bool(sub.isBusinessOverride ?? false),
                "is_active": .bool(sub.isActive),
                "cancellation_url": .string(cancelURL)
            ],
            activity: [activity],
            undo: undo
        )
    }

    private static func fingerprint(_ sub: RecurringSubscription) -> String {
        let biz = sub.isBusinessOverride.map { $0 ? "1" : "0" } ?? "nil"
        let active = sub.isActive ? "1" : "0"
        let stamp = sub.updatedAt.map { String(Int($0.timeIntervalSince1970 * 1_000)) } ?? "-"
        return "\(biz)|\(active)|\(stamp)"
    }
}
