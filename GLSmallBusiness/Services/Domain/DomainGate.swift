//
//  DomainGate.swift
//  GLSmallBusiness
//
//  The checks every domain write runs before it touches a model, in one place so a form and an
//  assistant tool can never disagree about them:
//    - read-only (lapsed or offline) for the write's OWN `MBWriteOperation`, through
//      `ReadOnlyGate.allowsUnattended` — the gate's non-UI path, which writes the developer's log
//      line. The person's half is the caller's: a form has already refused out loud with
//      `ReadOnlyGate.allows(_:into:)` before it calls a service, a tool reports the thrown error;
//    - the free-tier cap on creates, through `AccessGate.decide` (side-effect free), so the
//      sample-mode and DEBUG demo exemptions are exactly the ones every tap already gets;
//    - liveness: a record deleted under the caller (a sync pull, another device) is refused, never
//      written — writing a dead @Model traps, and a write onto a tombstone is lost on next sync;
//    - value rules (money, rates, hours and quantities ≥ 0 and finite; percentages ≤ 100).
//  Every refusal except read-only (already logged by the gate) is logged here: operation and code,
//  never a value.
//

import Foundation
import GoldLifeUI
import OSLog
import SwiftData

extension Logger {
    /// Domain-service refusals. Codes and operation names only — no names, amounts or ids.
    nonisolated static let domain = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GLSmallBusiness",
                                           category: "domain")
}

/// Who a write comes from. The screens keep the leniency they have always had with values that can
/// only have come from stored data — an old record's 150% discount (never a tax rate: the totals
/// don't clamp it), an ordinary credit line an older build carried onto a job's first invoice, a
/// customer whose delete cascade is past the Worker's row cap. A tool's input
/// is new input, so it gets every refusal the contract (AI_CONTRACT §5) lists. `.tool` is the
/// default so a new caller is strict unless it says otherwise.
nonisolated enum WriteOrigin: Sendable {
    case screen, tool
}

@MainActor
enum DomainGate {

    /// Refuses when the app is read-only for `operation` (lapsed or offline; sample mode is never
    /// read-only). Logs through `ReadOnlyGate`'s unattended surface.
    static func requireWritable(_ operation: MBWriteOperation,
                                _ subscription: SubscriptionManager? = nil) throws {
        let subscription = subscription ?? .shared
        guard ReadOnlyGate.allowsUnattended(operation, subscription) else {
            throw DomainError.readOnly(operation: operation.rawValue, lapsed: subscription.isLapsed)
        }
    }

    /// The create check: read-only first, then the `FreeTier` cap for `type` when there is one
    /// (`cap: nil` = an uncapped type, like projects). Same decision `AccessGate.attemptCreate`
    /// makes for a tap, minus the paywall — the caller decides how to offer that.
    static func requireCanCreate<T: PersistentModel>(_ type: T.Type, cap: Int?,
                                                     operation: MBWriteOperation,
                                                     in context: ModelContext,
                                                     _ subscription: SubscriptionManager? = nil) throws {
        let subscription = subscription ?? .shared
        try requireWritable(operation, subscription)
        guard let cap else { return }
        switch AccessGate.decide(type, cap: cap, in: context, subscription: subscription) {
        case .allowed:
            return
        case .atCap:
            throw refusal(.freeLimitReached(operation: operation.rawValue), operation)
        case .readOnly:
            // Unreachable after `requireWritable` (both read `isLapsed`); mapped rather than trusted.
            throw DomainError.readOnly(operation: operation.rawValue, lapsed: true)
        }
    }

    /// Refuses a record that is not in a context or is deleted. The LiveRows rule, applied to the
    /// record a write is about to touch.
    static func requireLive(_ model: (any PersistentModel)?, _ operation: MBWriteOperation) throws {
        guard let model, model.modelContext != nil, !model.isDeleted else {
            throw refusal(.recordNotFound, operation)
        }
    }

    /// Money, rates, hours, quantities: finite and ≥ 0.
    static func requireNonNegative(_ values: Double..., for operation: MBWriteOperation) throws {
        guard values.allSatisfy(DomainMoney.isNonNegative) else {
            throw refusal(.negativeValue, operation)
        }
    }

    /// A percentage: finite, 0 through 100.
    static func requirePercent(_ value: Double, for operation: MBWriteOperation) throws {
        guard DomainMoney.isPercent(value) else { throw refusal(.percentOutOfRange, operation) }
    }

    /// Logs the developer's half of a refusal and hands the error back to throw.
    static func refusal(_ error: DomainError, _ operation: MBWriteOperation) -> DomainError {
        Logger.domain.error(
            "domain refusal: operation=\(operation.rawValue, privacy: .public) code=\(error.code, privacy: .public)")
        return error
    }
}
