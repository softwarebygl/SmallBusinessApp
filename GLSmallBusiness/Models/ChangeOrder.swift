//
//  ChangeOrder.swift
//  GLSmallBusiness
//
//  A change order amends an invoice's scope mid-job: it lists the added (or removed) work, the
//  price change, and the revised total, and carries an approval status so there's a paper trail.
//  Added items can optionally be pushed onto the invoice as a new line-item group.
//
//  NOTE (schema): pre-launch, these new @Models fold into GLSchemaV1 (see GLSchema.swift). The
//  added `Invoice.changeOrders` relationship is optional/additive, per the CloudKit rules.
//

import Foundation
import SwiftData

enum ChangeOrderStatus: String, Codable, CaseIterable, Identifiable {
    case pending, approved, declined
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .approved: return String(localized: "Approved")
        case .declined: return String(localized: "Declined")
        }
    }
}

@Model
final class ChangeOrder {
    var number: String = ""
    var title: String = ""
    var createdAt: Date = Date.now
    var note: String = ""
    var statusRaw: String = ChangeOrderStatus.pending.rawValue
    /// Tax rate snapshot from the invoice at creation, applied to taxable change items.
    var taxRatePercent: Double = 0
    /// True once the items have been pushed onto the invoice as a group (prevents double-adding).
    var appliedToInvoice: Bool = false

    var invoice: Invoice?

    @Relationship(deleteRule: .cascade, inverse: \ChangeOrderLineItem.changeOrder)
    var lineItems: [ChangeOrderLineItem]?

    init(number: String = "", title: String = "", createdAt: Date = .now, taxRatePercent: Double = 0) {
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.taxRatePercent = taxRatePercent
    }
}

extension ChangeOrder {
    var status: ChangeOrderStatus {
        get { ChangeOrderStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var sortedLineItems: [ChangeOrderLineItem] {
        (lineItems ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Sum of line totals — negative when the change removes scope (a credit).
    var subtotal: Double { sortedLineItems.reduce(0) { $0 + $1.lineTotal } }

    var taxAmount: Double {
        let taxable = sortedLineItems.filter { $0.isTaxable }.reduce(0) { $0 + $1.lineTotal }
        return taxable * taxRatePercent / 100
    }

    /// The price change this order represents (can be negative).
    var total: Double { subtotal + taxAmount }

    /// CO-0001 style, sequenced per invoice.
    static func nextNumber(after existing: [ChangeOrder]) -> String {
        let highest = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "CO-", with: "")) }
            .max() ?? 0
        return String(format: "CO-%04d", highest + 1)
    }
}

@Model
final class ChangeOrderLineItem {
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.job
    var unitPrice: Double = 0
    var isTaxable: Bool = false
    var sortIndex: Int = 0

    var changeOrder: ChangeOrder?

    init(name: String = "", details: String = "", quantity: Double = 1,
         unit: UnitOfMeasure = .job, unitPrice: Double = 0, isTaxable: Bool = false, sortIndex: Int = 0) {
        self.name = name
        self.details = details
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.isTaxable = isTaxable
        self.sortIndex = sortIndex
    }

    var lineTotal: Double { quantity * unitPrice }
}
