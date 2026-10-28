//
//  MBToolSupport.swift
//  GLSmallBusiness — AI
//
//  What every My Business tool shares: where it reads from (`MBToolEnvironment`), the record
//  kinds the manifest names (`MBRecordKind`), how ids are handed out (`MBIDs`, always the
//  `syncID`, minted when a row has none), how values are spelled for the model (`MBValue`:
//  YYYY-MM-DD days, whole cents), the 8 KB / 1,200-character output budgets (`MBOutputFit`),
//  and the refusals a read tool can give (`MBToolFailure`).
//
//  Model-facing text in here is English on purpose (the model reads it; the person never does).
//  The person's half of a refusal is a catalog string resolved at draw time (law 6 ruling).
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - Environment

/// Card-payment status for one invoice, read from the card-payments Worker. A protocol so a test
/// never touches the network.
protocol MBCardPaymentReading {
    func payLinkStatus(appInvoiceID: String) async throws -> StripePayLinkStatusResponse
}

/// The live reader: `StripeBackendClient`, read only (the same call the invoice screen polls).
struct MBCardPaymentReader: MBCardPaymentReading {
    func payLinkStatus(appInvoiceID: String) async throws -> StripePayLinkStatusResponse {
        try await StripeBackendClient.shared.payLinkStatus(appInvoiceId: appInvoiceID)
    }
}

/// Where the tools read from. Providers, not values: the store behind them can be rebuilt or
/// unmounted (sign-out, account switch) while a conversation is alive, and a tool asks at the
/// moment it runs.
struct MBToolEnvironment {
    /// The signed-in store's main context; nil while none is mounted.
    var context: () -> ModelContext?
    /// The subscription the read-only gate reads (minting an id is saved only when writable).
    var subscription: () -> SubscriptionManager? = { .shared }
    var now: () -> Date = { .now }
    var calendar: Calendar = .current
    /// The device's legacy workdays mask (the schedule's fallback when no schedule was saved).
    var legacyMask: () -> Int = { WorkScheduleService.storedLegacyMask }
    var cardPayments: any MBCardPaymentReading = MBCardPaymentReader()
    /// The backup pause, when the mass-delete breaker is holding this device.
    var backupPause: () -> GLSyncBreakerTrip? = { GLSyncStatus.shared.pausedByMassDelete }
    /// What this conversation has written: Undo snapshots, the fingerprints Undo checks, and the
    /// idempotency keys of recorded payments. One per toolbox (a class, so every tool shares it).
    var ledger = MBWriteLedger()
}

// MARK: - Record kinds

/// The manifest's record kinds (contract §5), spelled exactly as `tools.mb-1.json` spells them.
enum MBRecordKind: String, CaseIterable {
    case customer, estimate, contract, invoice
    case changeOrder = "change_order"
    case job, receipt
    case priceItem = "price_item"
    case employee, subcontractor, project, payment
    case timeEntry = "time_entry"
    case paycheck
    case subPayment = "sub_payment"
    case attachment, document
    case business
    case workSchedule = "work_schedule"
    case appSettings = "app_settings"
    case goldLifeID = "gold_life_id"
    case deviceInfo = "device_info"

    /// Read without an id (`get kind:business`).
    var isSingleton: Bool {
        self == .business || self == .workSchedule || self == .appSettings
            || self == .goldLifeID || self == .deviceInfo
    }
}

// MARK: - Ids

/// Every record and child row is named by its `syncID` (contract §5). A row that has none yet is
/// given one through `DomainSyncIdentity.ensure` (saved unless the app is read-only).
@MainActor
enum MBIDs {
    static func id<T: PersistentModel & GLSyncIdentified>(_ record: T, _ env: MBToolEnvironment) -> String {
        guard let context = env.context(),
              let id = try? DomainSyncIdentity.ensure(record, in: context, subscription: env.subscription())
        else { return record.syncID?.uuidString ?? "" }
        return id.uuidString
    }

    /// Price sheet items are local-only (not `GLSyncIdentified`); their own minting rule.
    static func id(_ item: PriceSheetItem, _ env: MBToolEnvironment) -> String {
        guard let context = env.context(),
              let id = try? PriceSheetService.ensureID(item, in: context, subscription: env.subscription())
        else { return item.syncID?.uuidString ?? "" }
        return id.uuidString
    }

    static func uuid(_ text: String?) -> UUID? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return UUID(uuidString: text)
    }
}

// MARK: - Values

/// How a value is spelled for the model. Money is whole cents (half-up, `DomainMoney`); prices,
/// rates and quantities are exact (`rate`, law 60); a day is
/// `YYYY-MM-DD` in the business's calendar; a moment is ISO 8601 with its offset.
@MainActor
struct MBValue {
    let calendar: Calendar

    func money(_ value: Double) -> GLAIJSON { .number(DomainMoney.roundedToCents(value.isFinite ? value : 0)) }

    /// A price, rate or quantity, at FULL precision (law 60, owner ruling 2026-09-27: "prices and
    /// rates (e.g. $0.125 a piece) keep their precision and the line total rounds once"). The
    /// model must see $0.125, not $0.13, or its own arithmetic drifts from the app's. Amounts
    /// (totals, balances, payments) stay `money` — whole cents.
    func rate(_ value: Double) -> GLAIJSON { .number(value.isFinite ? value : 0) }

    func number(_ value: Double) -> GLAIJSON {
        guard value.isFinite else { return .number(0) }
        return .number((value * 100).rounded() / 100)
    }

    func int(_ value: Int) -> GLAIJSON { .number(Double(value)) }

    func day(_ date: Date) -> GLAIJSON { .string(dayString(date)) }

    func day(_ date: Date?) -> GLAIJSON { date.map(day) ?? .null }

    func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func moment(_ date: Date) -> GLAIJSON {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return .string(formatter.string(from: date))
    }

    /// `HH:mm`, 24-hour, from minutes after midnight (the work schedule's spelling).
    func clock(minutes: Int) -> GLAIJSON {
        let clamped = max(0, min(minutes, 24 * 60))
        return .string(String(format: "%02d:%02d", clamped / 60, clamped % 60))
    }

    func clock(_ date: Date) -> GLAIJSON {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clock(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// Record text, trimmed and cut to `limit` characters (with "…" when cut) so one long note can
    /// never crowd a whole record out of the 8 KB budget.
    func text(_ value: String, limit: Int = 600) -> GLAIJSON {
        .string(Self.clip(value, limit: limit))
    }

    static func clip(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(0, limit - 1))) + "…"
    }

    /// `YYYY-MM-DD` → the start of that day in the business's calendar. Nil for anything else.
    func parseDay(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.count == 10 else { return nil }
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }   // 2026-02-30 is not a day
        return calendar.startOfDay(for: date)
    }

    /// An ISO 8601 date-time with an offset (`2026-09-22T08:00:00-04:00`) — how the model spells a
    /// clock-in / clock-out. A plain day is accepted too, at the start of that day.
    func parseMoment(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        return parseDay(text)
    }

    func address(_ address: Address) -> GLAIJSON {
        guard !address.isEmpty else { return .null }
        return [
            "street1": text(address.street1, limit: 120),
            "street2": text(address.street2 ?? "", limit: 120),
            "city": text(address.city, limit: 80),
            "state": text(address.state, limit: 40),
            "postal_code": text(address.postalCode, limit: 20),
        ]
    }
}

// MARK: - Arguments

/// A tool call's arguments, read defensively (the schema check already ran in the loop, but a
/// tool never trusts the model).
struct MBArguments {
    let json: GLAIJSON

    func string(_ key: String) -> String? {
        guard let value = json[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int? { json[key]?.intValue }
}

// MARK: - Failures

/// The refusals a read tool gives. A bad argument or a wrong id is the model's own slip, which it
/// corrects itself — never a "Not done" row on the person's card (`showsToPerson: false`).
@MainActor
enum MBToolFailure {
    static func invalid(_ message: String) -> GLAIToolOutcome {
        .failure(GLAIFailure(reason: "invalid_arguments", message: message,
                             personReason: GLAIStrings.notAvailableHere, showsToPerson: false))
    }

    static func notFound(_ kind: MBRecordKind) -> GLAIToolOutcome {
        .failure(GLAIFailure(reason: "not_found",
                             message: "No \(kind.rawValue) has that id. Use find to get the right id.",
                             personReason: GLAIStrings.notAvailableHere, showsToPerson: false))
    }

    /// No store is mounted (signed out, account switch, store rebuild).
    static var unavailable: GLAIToolOutcome {
        .failure(GLAIFailure(reason: "not_available",
                             message: "The records aren't available right now. Tell the user plainly.",
                             personReason: GLAIStrings.errorGeneric))
    }
}

// MARK: - Output budget

/// Keeps every output inside its budget: 8 KB serialized online (the server's per-output rule,
/// contract §1), 1,200 characters on device (contract §6). Trimming drops rows from the END of the
/// named arrays, in order, and says so (`truncated: true`, `omitted: {array: n}`), so the model
/// knows to narrow its question or page on — it is never handed a silently partial answer.
@MainActor
enum MBOutputFit {
    /// A little under 8 KB: the loop adds nothing, but the margin keeps an exact-edge output legal.
    static let onlineBytes = GLAIWire.maxToolOutputBytes - 192

    enum Budget {
        case bytes(Int)
        case characters(Int)

        func size(of value: GLAIJSON) -> Int {
            switch self {
            case .bytes: return value.serializedByteCount
            case .characters: return value.serializedString.count
            }
        }

        var limit: Int {
            switch self {
            case .bytes(let n), .characters(let n): return n
            }
        }
    }

    static func budget(_ context: GLAIToolContext) -> Budget {
        if let limit = context.outputCharacterLimit { return .characters(max(200, limit - 20)) }
        return .bytes(onlineBytes)
    }

    static func fit(_ object: [String: GLAIJSON], trimming keys: [String], budget: Budget) -> GLAIJSON {
        var output = object
        if output["ok"] == nil { output["ok"] = true }
        var omitted: [String: Int] = [:]
        var current = GLAIJSON.object(output)
        while budget.size(of: current) > budget.limit {
            guard let key = keys.first(where: { (output[$0]?.arrayValue?.isEmpty == false) }),
                  var array = output[key]?.arrayValue else { break }
            // Drop in halves while far over, then one at a time, so a 50-row answer settles fast.
            let over = budget.size(of: current) - budget.limit
            let drop = min(array.count, over > budget.limit / 2 ? max(1, array.count / 2) : 1)
            array.removeLast(drop)
            omitted[key, default: 0] += drop
            output[key] = .array(array)
            output["truncated"] = true
            output["omitted"] = .object(omitted.mapValues { .number(Double($0)) })
            current = .object(output)
        }
        guard budget.size(of: current) > budget.limit else { return current }
        // Nothing left to trim and still too big (a record of very long fields): a short answer
        // that tells the model what to do instead of a broken one.
        var minimal: [String: GLAIJSON] = ["ok": true, "truncated": true,
                                           "message": "Too much to return at once. Ask for less (a narrower find, or get one record)."]
        for key in ["kind", "id", "number", "count"] { if let value = object[key] { minimal[key] = value } }
        return .object(minimal)
    }
}
