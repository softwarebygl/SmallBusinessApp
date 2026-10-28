//
//  PaymentProcessor.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import Foundation
import SwiftData

/// RETIRED (dormant). The manual processing-fee tracker was removed from the UI — there's no longer a
/// way to create a processor or tag a payment with one. This @Model is KEPT, not deleted, because the app
/// is live and a deployed CloudKit production schema can't drop a record type; removing it would break
/// sync for existing users. Existing snapshots on `InvoicePayment` still feed Statistics / the year-end
/// export so historical fee deductions stay accurate. Do not re-surface without a replacement design.
///
/// (Historically: a service the business uses to take payments and the fee it charges per transaction —
/// a percentage plus an optional flat amount, e.g. 2.9% + $0.30. The chosen processor's fee was
/// snapshotted onto the payment so later edits never rewrote past fees.)
@Model
final class PaymentProcessor {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var name: String = ""
    /// Percentage of each payment taken as a fee (e.g. 2.9 for 2.9%).
    var feePercent: Double = 0
    /// Flat per-transaction charge in dollars (e.g. 0.30), added on top of the percentage.
    var flatFee: Double = 0
    var createdAt: Date = Date.now

    var businessProfile: BusinessProfile?

    init(name: String = "", feePercent: Double = 0, flatFee: Double = 0, createdAt: Date = .now) {
        self.name = name
        self.feePercent = feePercent
        self.flatFee = flatFee
        self.createdAt = createdAt
    }

    /// The fee charged on a payment of `amount`: percentage of the amount plus the flat fee.
    func fee(on amount: Double) -> Double { Self.fee(on: amount, percent: feePercent, flat: flatFee) }

    /// The fee formula, worked out exactly and rounded once to the cent (law 60). Shared with
    /// `InvoicePayment.processingFee`, which applies it to the rates snapshotted on the payment.
    nonisolated static func fee(on amount: Double, percent: Double, flat: Double) -> Double {
        DomainMoney.roundedToCents(DomainMoney.product(amount, percent) * DomainMoney.hundredth + DomainMoney.decimal(flat))
    }

    /// Compact human description of the fee — "2.9% + $0.30", "2.9%", "$0.30", or "" when both are 0.
    var feeDescription: String {
        let pct = feePercent > 0 ? "\(feePercent.formatted(.number.precision(.fractionLength(0...2))))%" : ""
        let flat = flatFee > 0 ? flatFee.formatted(.money) : ""
        return [pct, flat].filter { !$0.isEmpty }.joined(separator: " + ")
    }
}
