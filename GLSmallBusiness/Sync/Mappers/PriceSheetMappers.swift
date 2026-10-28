//
//  PriceSheetMappers.swift
//  GLSmallBusiness
//
//  GLSync payload mapper for the Price Sheet (Menu > Documents > Catalog & Pricing), manifest key
//  `price_sheet_item` — the 24th sync type, added 2026-10-03 (QA finding F3). Until then the
//  catalog never left the phone, so a sign-out or a session ending wiped it for good while
//  What's New promised everything comes back.
//
//  Contract (gl-business-api sync-manifest.json `price_sheet_item`): no parent (an item belongs
//  to the account), nothing protected (a catalog price charges no one — a document line COPIES
//  it, and that line's price is protected), no blobs, PII class none. Payload keys are the
//  model's own stored property names, the raw enum columns included (`unitRaw`, `kindRaw`,
//  `discountTypeRaw`). Derived money (`grossTotal`, `lineDiscount`, `netTotal`) is never sent.
//
//  Same rules as every mapper (GLSyncMappable.swift): a PATCH may carry only the fields another
//  device touched, so an absent key leaves the local value alone; an unknown enum value degrades
//  to the model's own default rather than failing the record.
//

import Foundation
import SwiftData

extension PriceSheetItem: GLSyncMappable {

    static var glSyncType: String { "price_sheet_item" }

    /// Top-level record — manifest `price_sheet_item.parent: null`.
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
            "name": GLSyncValue.string(name),
            "details": GLSyncValue.string(details),
            "defaultQuantity": GLSyncValue.double(defaultQuantity),
            "unitRaw": GLSyncValue.raw(unit),
            "unitPrice": GLSyncValue.double(unitPrice),
            "kindRaw": GLSyncValue.raw(kind),
            "isTaxable": GLSyncValue.bool(isTaxable),
            "category": GLSyncValue.string(category),
            // The discount TYPE rides with its VALUE: a type flip alone changes the price.
            "discountTypeRaw": GLSyncValue.raw(discountType),
            "discountValue": GLSyncValue.double(discountValue),
            "sortIndex": GLSyncValue.int(sortIndex),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        name = GLSyncValue.string(payload, "name", default: name)
        details = GLSyncValue.string(payload, "details", default: details)
        defaultQuantity = GLSyncValue.double(payload, "defaultQuantity", default: defaultQuantity)
        // Read through the enum, so an unknown value lands as the default case rather than as a
        // raw string the item would keep forever.
        if payload["unitRaw"] != nil {
            unit = GLSyncValue.raw(payload, "unitRaw", default: UnitOfMeasure.squareFoot)
        }
        unitPrice = GLSyncValue.double(payload, "unitPrice", default: unitPrice)
        if payload["kindRaw"] != nil {
            kind = GLSyncValue.raw(payload, "kindRaw", default: LineItemKind.labor)
        }
        isTaxable = GLSyncValue.bool(payload, "isTaxable", default: isTaxable)
        category = GLSyncValue.string(payload, "category", default: category)
        if payload["discountTypeRaw"] != nil {
            discountType = GLSyncValue.raw(payload, "discountTypeRaw", default: AdjustmentType.none)
        }
        discountValue = GLSyncValue.double(payload, "discountValue", default: discountValue)
        sortIndex = GLSyncValue.int(payload, "sortIndex", default: sortIndex)
    }
}

// MARK: - Property audit
//
// The payload keys `glSyncPayload()` emits, reconciled against the model's stored properties by
// GLSyncMappingTests (GLSYNC-SPEC.md §8). `GLSyncMapperAudit` itself is declared once, in
// InvoiceMappers.swift; this file only extends it.

extension GLSyncMapperAudit {

    nonisolated static let priceSheetProperties: [String: [String]] = [
        "price_sheet_item": [
            "syncID", "updatedAt", "createdAt", "name", "details", "defaultQuantity", "unitRaw",
            "unitPrice", "kindRaw", "isTaxable", "category", "discountTypeRaw", "discountValue",
            "sortIndex",
        ],
    ]
}
