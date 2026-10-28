//
//  MoneyMappers.swift
//  GLSmallBusiness
//

import Foundation
import SwiftData
import GoldLifeMoney

// MARK: - BankAccount Mapper
extension BankAccount: GLSyncMappable {
    static var glSyncType: String { "bank_account" }

    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "plaidAccountId": GLSyncValue.string(plaidAccountId),
            "itemId": GLSyncValue.string(itemId),
            "institutionName": GLSyncValue.string(institutionName),
            "name": GLSyncValue.string(name),
            "mask": GLSyncValue.string(mask),
            "subtypeRaw": GLSyncValue.string(subtypeRaw),
            "currentBalanceCents": GLSyncValue.int(Int(currentBalanceCents)),
            "isoCurrencyCode": GLSyncValue.string(isoCurrencyCode),
            "needsReauth": GLSyncValue.bool(needsReauth),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        plaidAccountId = GLSyncValue.string(payload, "plaidAccountId", default: plaidAccountId)
        itemId = GLSyncValue.string(payload, "itemId", default: itemId)
        institutionName = GLSyncValue.string(payload, "institutionName", default: institutionName)
        name = GLSyncValue.string(payload, "name", default: name)
        mask = GLSyncValue.string(payload, "mask", default: mask)
        subtypeRaw = GLSyncValue.string(payload, "subtypeRaw", default: subtypeRaw)
        currentBalanceCents = Int64(GLSyncValue.int(payload, "currentBalanceCents", default: Int(currentBalanceCents)))
        isoCurrencyCode = GLSyncValue.string(payload, "isoCurrencyCode", default: isoCurrencyCode)
        needsReauth = GLSyncValue.bool(payload, "needsReauth", default: needsReauth)
    }
}

// MARK: - BankTransaction Mapper
extension BankTransaction: GLSyncMappable {
    static var glSyncType: String { "bank_transaction" }

    var glSyncParentID: UUID? { bankAccountSyncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "plaidTransactionId": GLSyncValue.string(plaidTransactionId),
            "plaidAccountId": GLSyncValue.string(plaidAccountId),
            "name": GLSyncValue.string(name),
            "merchantName": GLSyncValue.string(merchantName),
            "amountCents": GLSyncValue.int(Int(amountCents)),
            "isoCurrencyCode": GLSyncValue.string(isoCurrencyCode),
            "date": GLSyncValue.string(date),
            "pending": GLSyncValue.bool(pending),
            "isBusinessOverride": isBusinessOverride.map { GLSyncValue.bool($0) } ?? NSNull(),
            "matchedRuleSyncID": matchedRuleSyncID.map { GLSyncValue.uuid($0) } ?? NSNull(),
            "isTrackedSubscription": GLSyncValue.bool(isTrackedSubscription),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        plaidTransactionId = GLSyncValue.string(payload, "plaidTransactionId", default: plaidTransactionId)
        plaidAccountId = GLSyncValue.string(payload, "plaidAccountId", default: plaidAccountId)
        name = GLSyncValue.string(payload, "name", default: name)
        merchantName = GLSyncValue.string(payload, "merchantName", default: merchantName)
        amountCents = Int64(GLSyncValue.int(payload, "amountCents", default: Int(amountCents)))
        isoCurrencyCode = GLSyncValue.string(payload, "isoCurrencyCode", default: isoCurrencyCode)
        date = GLSyncValue.string(payload, "date", default: date)
        pending = GLSyncValue.bool(payload, "pending", default: pending)
        if payload.keys.contains("isBusinessOverride") {
            isBusinessOverride = GLSyncValue.bool(payload, "isBusinessOverride")
        }
        if payload.keys.contains("matchedRuleSyncID") {
            matchedRuleSyncID = GLSyncValue.uuid(payload, "matchedRuleSyncID")
        }
        isTrackedSubscription = GLSyncValue.bool(payload, "isTrackedSubscription", default: isTrackedSubscription)
    }
}

// MARK: - TransactionCategoryRule Mapper
extension TransactionCategoryRule: GLSyncMappable {
    static var glSyncType: String { "transaction_category_rule" }

    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "createdAt": GLSyncValue.date(createdAt),
            "normalizedMerchantPattern": GLSyncValue.string(normalizedMerchantPattern),
            "displayMerchantName": GLSyncValue.string(displayMerchantName),
            "isBusiness": GLSyncValue.bool(isBusiness),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        if payload["createdAt"] != nil { createdAt = GLSyncValue.date(payload, "createdAt") }
        normalizedMerchantPattern = GLSyncValue.string(payload, "normalizedMerchantPattern", default: normalizedMerchantPattern)
        displayMerchantName = GLSyncValue.string(payload, "displayMerchantName", default: displayMerchantName)
        isBusiness = GLSyncValue.bool(payload, "isBusiness", default: isBusiness)
    }
}

// MARK: - RecurringSubscription Mapper
extension RecurringSubscription: GLSyncMappable {
    static var glSyncType: String { "recurring_subscription" }

    var glSyncParentID: UUID? { bankAccountSyncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "plaidStreamId": GLSyncValue.string(plaidStreamId),
            "plaidAccountId": GLSyncValue.string(plaidAccountId),
            "merchantName": GLSyncValue.string(merchantName),
            "amountCents": GLSyncValue.int(Int(amountCents)),
            "isoCurrencyCode": GLSyncValue.string(isoCurrencyCode),
            "cadenceRaw": GLSyncValue.string(cadenceRaw),
            "lastDate": GLSyncValue.string(lastDate),
            "nextExpectedDate": GLSyncValue.string(nextExpectedDate),
            "isActive": GLSyncValue.bool(isActive),
            "isBusinessOverride": isBusinessOverride.map { GLSyncValue.bool($0) } ?? NSNull(),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        plaidStreamId = GLSyncValue.string(payload, "plaidStreamId", default: plaidStreamId)
        plaidAccountId = GLSyncValue.string(payload, "plaidAccountId", default: plaidAccountId)
        merchantName = GLSyncValue.string(payload, "merchantName", default: merchantName)
        amountCents = Int64(GLSyncValue.int(payload, "amountCents", default: Int(amountCents)))
        isoCurrencyCode = GLSyncValue.string(payload, "isoCurrencyCode", default: isoCurrencyCode)
        cadenceRaw = GLSyncValue.string(payload, "cadenceRaw", default: cadenceRaw)
        lastDate = GLSyncValue.string(payload, "lastDate", default: lastDate)
        nextExpectedDate = GLSyncValue.string(payload, "nextExpectedDate", default: nextExpectedDate)
        isActive = GLSyncValue.bool(payload, "isActive", default: isActive)
        if payload.keys.contains("isBusinessOverride") {
            isBusinessOverride = GLSyncValue.bool(payload, "isBusinessOverride")
        }
    }
}

// MARK: - Property audit
extension GLSyncMapperAudit {
    nonisolated static let moneyProperties: [String: [String]] = [
        "bank_account": [
            "syncID", "updatedAt", "plaidAccountId", "itemId", "institutionName", "name",
            "mask", "subtypeRaw", "currentBalanceCents", "isoCurrencyCode", "needsReauth",
        ],
        "bank_transaction": [
            "syncID", "updatedAt", "plaidTransactionId", "plaidAccountId", "name", "merchantName",
            "amountCents", "isoCurrencyCode", "date", "pending", "isBusinessOverride",
            "matchedRuleSyncID", "isTrackedSubscription",
        ],
        "transaction_category_rule": [
            "syncID", "updatedAt", "createdAt", "normalizedMerchantPattern", "displayMerchantName",
            "isBusiness",
        ],
        "recurring_subscription": [
            "syncID", "updatedAt", "plaidStreamId", "plaidAccountId", "merchantName",
            "amountCents", "isoCurrencyCode", "cadenceRaw", "lastDate", "nextExpectedDate",
            "isActive", "isBusinessOverride",
        ],
    ]
}
