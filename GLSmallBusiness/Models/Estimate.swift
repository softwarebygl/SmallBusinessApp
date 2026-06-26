//
//  Estimate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData

// MARK: - Enums
// Marked `nonisolated` so their Codable conformances aren't main-actor isolated,
// which SwiftData requires to encode them from its nonisolated storage code.

nonisolated enum EstimateStatus: String, Codable, CaseIterable, Identifiable {
    case draft, sent, accepted, declined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: String(localized: "Draft")
        case .sent: String(localized: "Sent")
        case .accepted: String(localized: "Accepted")
        case .declined: String(localized: "Declined")
        }
    }
}

nonisolated enum LineItemKind: String, Codable, CaseIterable, Identifiable {
    case labor, material

    var id: String { rawValue }

    var label: String {
        switch self {
        case .labor: String(localized: "Labor")
        case .material: String(localized: "Material")
        }
    }

    /// Materials are taxable by default; labor usually isn't. User can override per line.
    var defaultTaxable: Bool { self == .material }
}

nonisolated enum UnitOfMeasure: String, Codable, CaseIterable, Identifiable {
    case squareFoot, linearFoot, squareYard, hour, day, each, lumpSum, job

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .squareFoot: String(localized: "sq ft")
        case .linearFoot: String(localized: "ln ft")
        case .squareYard: String(localized: "sq yd")
        case .hour: String(localized: "hr")
        case .day: String(localized: "day")
        case .each: String(localized: "ea")
        case .lumpSum: String(localized: "lump")
        case .job: String(localized: "job")
        }
    }

    var label: String {
        switch self {
        case .squareFoot: String(localized: "Square feet")
        case .linearFoot: String(localized: "Linear feet")
        case .squareYard: String(localized: "Square yards")
        case .hour: String(localized: "Hours")
        case .day: String(localized: "Days")
        case .each: String(localized: "Each")
        case .lumpSum: String(localized: "Lump sum")
        case .job: String(localized: "Job")
        }
    }
}

/// Shared shape for both discounts and deposits: off, a percentage, or a flat amount.
nonisolated enum AdjustmentType: String, Codable, CaseIterable, Identifiable {
    case none, percentage, fixed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "None")
        case .percentage: String(localized: "Percentage")
        case .fixed: String(localized: "Fixed amount")
        }
    }
}

// MARK: - Money math (single source of truth, shared by the model and the form preview)

nonisolated struct EstimateTotals {
    let subtotal: Double
    let discount: Double
    let tax: Double
    let total: Double
    let deposit: Double

    init(
        lines: [(lineTotal: Double, isTaxable: Bool)],
        taxRatePercent: Double,
        discountType: AdjustmentType,
        discountValue: Double,
        depositType: AdjustmentType,
        depositValue: Double
    ) {
        let sub = lines.reduce(0) { $0 + $1.lineTotal }
        let taxable = lines.filter(\.isTaxable).reduce(0) { $0 + $1.lineTotal }

        switch discountType {
        case .none: discount = 0
        case .percentage: discount = sub * (discountValue / 100)
        case .fixed: discount = min(discountValue, sub)
        }

        let discounted = sub - discount
        // Tax applies to taxable lines, reduced proportionally by any overall discount.
        if sub > 0, taxRatePercent > 0 {
            tax = taxable * (discounted / sub) * (taxRatePercent / 100)
        } else {
            tax = 0
        }

        subtotal = sub
        total = max(0, discounted + tax)

        switch depositType {
        case .none: deposit = 0
        case .percentage: deposit = total * (depositValue / 100)
        case .fixed: deposit = min(depositValue, total)
        }
    }
}

// MARK: - Estimate

@Model
final class Estimate {
    var number: String = ""
    var jobTitle: String = ""
    var createdAt: Date = Date.now
    var validUntil: Date = Date.now
    var status: EstimateStatus = EstimateStatus.draft

    // Customer snapshot — frozen at creation. Editing the Customer never changes this.
    var customerFirstName: String = ""
    var customerLastName: String = ""
    var customerBusinessName: String?
    var customerEmail: String = ""
    var customerPhone: String = ""
    var customerAddress: Address = Address()

    /// The job site / lot this estimate is for. Independent of the customer's (billing) address,
    /// so a GC's office stays put while each estimate can point at a different property.
    var serviceAddress: Address = Address()

    // Link back to the originating customer (for grouping/filtering only).
    var customer: Customer?

    // Financials
    var taxRatePercent: Double = 0
    var discountType: AdjustmentType = AdjustmentType.none
    var discountValue: Double = 0
    var depositType: AdjustmentType = AdjustmentType.none
    var depositValue: Double = 0

    // Content
    var customerNotes: String = ""
    var terms: String = ""

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \EstimateGroup.estimate)
    var groups: [EstimateGroup]?

    /// Calendar bookings made from this estimate. Nullify so deleting the estimate keeps the booking
    /// (it still carries its title/customer snapshot) rather than wiping it off the calendar.
    @Relationship(deleteRule: .nullify, inverse: \ScheduledJob.estimate)
    var scheduledJobs: [ScheduledJob]?

    init(
        number: String = "",
        jobTitle: String = "",
        createdAt: Date = .now,
        validUntil: Date? = nil,
        status: EstimateStatus = .draft,
        customer: Customer? = nil
    ) {
        self.number = number
        self.jobTitle = jobTitle
        self.createdAt = createdAt
        self.validUntil = validUntil ?? createdAt.addingTimeInterval(30 * 24 * 60 * 60)
        self.status = status
        self.customer = customer
        if let customer {
            self.customerFirstName = customer.firstName
            self.customerLastName = customer.lastName
            self.customerBusinessName = customer.businessName
            self.customerEmail = customer.email
            self.customerPhone = customer.phoneNumber
            self.customerAddress = customer.address
        }
    }
}

// MARK: - Estimate computed values

extension Estimate {
    var customerDisplayName: String {
        let full = [customerFirstName, customerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if let business = customerBusinessName?.trimmingCharacters(in: .whitespacesAndNewlines), !business.isEmpty {
            return business
        }
        return "Customer"
    }

    /// Recipient to pre-fill when emailing — the customer's CURRENT email, falling back to the
    /// snapshot taken at creation, so contact info added or changed later is still used.
    var recipientEmail: String {
        let live = (customer?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerEmail : live
    }
    /// Same, for texting — the customer's current mobile, falling back to the snapshot.
    var recipientPhone: String {
        let live = (customer?.phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerPhone : live
    }

    var sortedGroups: [EstimateGroup] {
        (groups ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allLineItems: [EstimateLineItem] {
        sortedGroups.flatMap { $0.sortedLineItems }
    }

    var totals: EstimateTotals {
        EstimateTotals(
            lines: allLineItems.map { ($0.lineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: discountType,
            discountValue: discountValue,
            depositType: depositType,
            depositValue: depositValue
        )
    }

    var subtotal: Double { totals.subtotal }
    var discountAmount: Double { totals.discount }
    var taxAmount: Double { totals.tax }
    var total: Double { totals.total }
    var depositAmount: Double { totals.deposit }

    var isExpired: Bool {
        guard status != .accepted, status != .declined else { return false }
        // Valid through the WHOLE "valid until" day — compare against the start of the next day, so the
        // badge doesn't flip to "Expired" partway through the day the estimate says it's valid until.
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1,
                                             to: Calendar.current.startOfDay(for: validUntil)) ?? validUntil
        return endOfDay <= .now
    }

    /// Status as shown to the user — surfaces "Expired" when past the valid-until date.
    var displayStatus: String {
        isExpired ? String(localized: "Expired") : status.label
    }

    static func nextNumber(after existing: [Estimate]) -> String {
        let highest = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "EST-", with: "")) }
            .max() ?? 0
        return String(format: "EST-%04d", highest + 1)
    }
}

// MARK: - Group

@Model
final class EstimateGroup {
    var name: String = ""
    var note: String = ""
    var sortIndex: Int = 0

    var estimate: Estimate?

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \EstimateLineItem.group)
    var lineItems: [EstimateLineItem]?

    init(name: String = "", note: String = "", sortIndex: Int = 0) {
        self.name = name
        self.note = note
        self.sortIndex = sortIndex
    }

    var sortedLineItems: [EstimateLineItem] {
        (lineItems ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var subtotal: Double {
        (lineItems ?? []).reduce(0) { $0 + $1.lineTotal }
    }
}

// MARK: - Line item

@Model
final class EstimateLineItem {
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.squareFoot
    var unitPrice: Double = 0
    var kind: LineItemKind = LineItemKind.labor
    var isTaxable: Bool = false
    var sortIndex: Int = 0

    var group: EstimateGroup?

    init(
        name: String = "",
        details: String = "",
        quantity: Double = 1,
        unit: UnitOfMeasure = .squareFoot,
        unitPrice: Double = 0,
        kind: LineItemKind = .labor,
        isTaxable: Bool = false,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.details = details
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.kind = kind
        self.isTaxable = isTaxable
        self.sortIndex = sortIndex
    }

    var lineTotal: Double {
        quantity * unitPrice
    }
}
