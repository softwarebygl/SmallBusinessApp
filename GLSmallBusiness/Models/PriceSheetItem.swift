//
//  PriceSheetItem.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 9/15/26.
//
//  A PriceSheetItem is a reusable catalog entry for services, labor rates, and materials.
//  It provides 100% field parity with EstimateLineItem / InvoiceLineItem (name, details,
//  unit, unitPrice, labor vs material kind, taxable status, line discount, and category).
//  The AI Assistant and manual document creators query this catalog to populate lines
//  automatically with consistent pricing and terms.
//

import Foundation
import SwiftData

@Model
final class PriceSheetItem {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    var updatedAt: Date?
    var createdAt: Date = Date.now

    var name: String = ""
    var details: String = ""
    var defaultQuantity: Double = 1.0
    var unitRaw: String = UnitOfMeasure.squareFoot.rawValue
    var unitPrice: Double = 0.0
    var kindRaw: String = LineItemKind.labor.rawValue
    var isTaxable: Bool = false
    var category: String = ""
    var discountTypeRaw: String = AdjustmentType.none.rawValue
    var discountValue: Double = 0.0
    var sortIndex: Int = 0

    init(
        name: String = "",
        details: String = "",
        defaultQuantity: Double = 1.0,
        unit: UnitOfMeasure = .squareFoot,
        unitPrice: Double = 0.0,
        kind: LineItemKind = .labor,
        isTaxable: Bool = false,
        category: String = "",
        discountType: AdjustmentType = .none,
        discountValue: Double = 0.0,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.details = details
        self.defaultQuantity = defaultQuantity
        self.unitRaw = unit.rawValue
        self.unitPrice = unitPrice
        self.kindRaw = kind.rawValue
        self.isTaxable = isTaxable
        self.category = category
        self.discountTypeRaw = discountType.rawValue
        self.discountValue = discountValue
        self.sortIndex = sortIndex
    }

    var unit: UnitOfMeasure {
        get { UnitOfMeasure(rawValue: unitRaw) ?? .squareFoot }
        set { unitRaw = newValue.rawValue }
    }

    var kind: LineItemKind {
        get { LineItemKind(rawValue: kindRaw) ?? .labor }
        set { kindRaw = newValue.rawValue }
    }

    var discountType: AdjustmentType {
        get { AdjustmentType(rawValue: discountTypeRaw) ?? .none }
        set { discountTypeRaw = newValue.rawValue }
    }

    /// The line this item makes at its default quantity — the same exact line math as a document
    /// line (law 60), each amount rounded once.
    var money: LineMoney {
        LineMoney(quantity: defaultQuantity, unitPrice: unitPrice, discountType: discountType, discountValue: discountValue)
    }
    var grossTotal: Double { DomainMoney.roundedToCents(money.gross) }
    var lineDiscount: Double { DomainMoney.roundedToCents(money.discount) }
    var netTotal: Double { DomainMoney.roundedToCents(money.floored) }
}
