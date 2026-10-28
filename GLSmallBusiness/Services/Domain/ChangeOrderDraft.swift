//
//  ChangeOrderDraft.swift
//  GLSmallBusiness
//
//  The editable shape of a change order — what ChangeOrderFormScreen holds in @State and what
//  the assistant's tools build — handed to ChangeOrderService. Moved here from the form.
//

import Foundation
import SwiftData

/// One change-order item as the form edits it: a price MAGNITUDE plus Charge/Credit. The service
/// stores a credit as a negative unit price.
struct ChangeOrderLineDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = .job
    var unitPrice: Double = 0
    var isCredit = false
    var isTaxable = false
    /// The live row this draft came from, so the save updates it IN PLACE. nil for a row added in
    /// the form — the save inserts that one fresh.
    var modelID: PersistentIdentifier? = nil
    /// Signed total, exact — credits subtract from the change order (removed work).
    var exactLineTotal: Decimal {
        let magnitude = DomainMoney.product(quantity, abs(unitPrice))
        return isCredit ? -magnitude : magnitude
    }
    /// The same, rounded once — what the form shows.
    var lineTotal: Double { DomainMoney.roundedToCents(exactLineTotal) }

    init() {}

    init(name: String, quantity: Double = 1, unit: UnitOfMeasure = .job, unitPrice: Double,
         isCredit: Bool = false, isTaxable: Bool = false) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.isCredit = isCredit
        self.isTaxable = isTaxable
    }

    init(from item: ChangeOrderLineItem) {
        name = item.name
        quantity = item.quantity
        unit = item.unit
        // The model stores credits as a NEGATIVE unit price; the form edits the magnitude
        // and a Charge/Credit switch, and the save puts the sign back.
        unitPrice = abs(item.unitPrice)
        isCredit = item.unitPrice < 0
        isTaxable = item.isTaxable
        modelID = item.persistentModelID
    }
}

struct ChangeOrderDraft: Equatable {
    var title = ""
    var note = ""
    var items: [ChangeOrderLineDraft] = [ChangeOrderLineDraft()]
    var status: ChangeOrderStatus = .pending

    init(title: String = "", note: String = "", items: [ChangeOrderLineDraft] = [ChangeOrderLineDraft()], status: ChangeOrderStatus = .pending) {
        self.title = title
        self.note = note
        self.items = items
        self.status = status
    }

    init(_ changeOrder: ChangeOrder) {
        title = changeOrder.title
        note = changeOrder.note
        status = changeOrder.status
        let rows = changeOrder.sortedLineItems.map { ChangeOrderLineDraft(from: $0) }
        items = rows.isEmpty ? [ChangeOrderLineDraft()] : rows
    }

    /// At least one item with a description — what the form's Save requires.
    var hasNamedItem: Bool {
        items.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
