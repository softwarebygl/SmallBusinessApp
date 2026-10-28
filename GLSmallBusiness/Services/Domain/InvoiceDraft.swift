//
//  InvoiceDraft.swift
//  GLSmallBusiness
//
//  The editable shape of an invoice — what InvoiceFormScreen holds in @State and what the
//  assistant's tools build — handed to InvoiceService. Moved here from the form, unchanged.
//  `modelID` is the live row a draft was read from (see DocumentDrafts.swift).
//

import Foundation
import SwiftData

struct InvoiceLineDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var details = ""
    var quantity = 1.0
    var unit: UnitOfMeasure = .squareFoot
    var unitPrice = 0.0
    var kind: LineItemKind = .labor
    var isTaxable = false
    var discountType: AdjustmentType = .none
    var discountValue = 0.0
    /// Change-order line items are billed at FULL price (the whole-invoice discount doesn't apply)
    /// and taxed at the full rate, so the invoice matches the signed change order. This flag MUST
    /// round-trip through the form, or editing an invoice would silently re-discount those lines.
    var fromChangeOrder = false
    /// The saved row this draft was opened from. nil for a line typed into the form, and for a line
    /// carried over from an estimate or another invoice — those are NEW rows on this invoice.
    var modelID: PersistentIdentifier? = nil

    init() {}

    init(from item: InvoiceLineItem) {
        modelID = item.persistentModelID
        name = item.name
        details = item.details
        quantity = item.quantity
        unit = item.unit
        unitPrice = item.unitPrice
        kind = item.kind
        isTaxable = item.isTaxable
        discountType = item.discountType
        discountValue = item.discountValue
        fromChangeOrder = item.fromChangeOrder
    }

    init(from item: EstimateLineItem) {
        name = item.name
        details = item.details
        quantity = item.quantity
        unit = item.unit
        unitPrice = item.unitPrice
        kind = item.kind
        isTaxable = item.isTaxable
        discountType = item.discountType
        discountValue = item.discountValue
    }

    /// A new line copied from a Price Sheet item (the form's "From Price Sheet" menu).
    init(priceSheetItem item: PriceSheetItem) {
        name = item.name
        details = item.details
        quantity = item.defaultQuantity
        unit = item.unit
        unitPrice = item.unitPrice
        kind = item.kind
        isTaxable = item.isTaxable
        discountType = item.discountType
        discountValue = item.discountValue
    }

    /// This line's money, exact — the saved line's formula (law 60).
    var money: LineMoney {
        LineMoney(quantity: quantity, unitPrice: unitPrice, discountType: discountType, discountValue: discountValue)
    }
    var grossLineTotal: Double { DomainMoney.roundedToCents(money.gross) }
    var lineDiscount: Double { DomainMoney.roundedToCents(money.discount) }
    var lineTotal: Double { DomainMoney.roundedToCents(money.floored) }
    /// Signed total for change-order lines — a credit keeps its negative sign so the preview
    /// matches the saved invoice's math (see `InvoiceLineItem.signedLineTotal`).
    var signedLineTotal: Double { DomainMoney.roundedToCents(money.signed) }
    var exactLineTotal: Decimal { money.floored }
    var exactSignedLineTotal: Decimal { money.signed }
}

struct InvoiceGroupDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var note = ""
    var lines: [InvoiceLineDraft]
    /// Round-tripped through the save so a group pushed from a change order keeps its link —
    /// otherwise an invoice edit could orphan applied change orders into "legacy" ones.
    var changeOrder: ChangeOrder?
    /// The saved row this draft was opened from. nil for a group added in the form, and for a group
    /// carried over from an estimate or another invoice — those are NEW rows on this invoice.
    var modelID: PersistentIdentifier? = nil

    init() {
        lines = [InvoiceLineDraft()]
    }

    init(name: String = "", note: String = "", lines: [InvoiceLineDraft]) {
        self.name = name
        self.note = note
        self.lines = lines
    }

    init(from group: InvoiceGroup) {
        modelID = group.persistentModelID
        name = group.name
        note = group.note
        changeOrder = group.changeOrder
        lines = group.sortedLineItems.map { InvoiceLineDraft(from: $0) }
        if lines.isEmpty { lines = [InvoiceLineDraft()] }
    }

    init(from group: EstimateGroup) {
        name = group.name
        note = group.note
        lines = group.sortedLineItems.map { InvoiceLineDraft(from: $0) }
        if lines.isEmpty { lines = [InvoiceLineDraft()] }
    }

    // Signed for change-order lines so a credit shows negative — matching the saved invoice's math.
    var subtotal: Double {
        DomainMoney.roundedToCents(lines.reduce(Decimal(0)) {
            $0 + ($1.fromChangeOrder ? $1.exactSignedLineTotal : $1.exactLineTotal)
        })
    }
}

/// Everything the invoice form edits. The number, created date and customer are not editable.
struct InvoiceDraft: Equatable {
    var jobTitle = ""
    var status: InvoiceStatus = .draft
    var paymentTerms: PaymentTerms = .net30
    /// Used only for `.custom` terms; any other term dates the invoice from its created date.
    var dueDate = PaymentTerms.net30.dueDate(from: .now) ?? .now
    var taxRatePercent = 0.0
    var discountType: AdjustmentType = .none
    var discountValue = 0.0
    var customerNotes = ""
    var terms = ""
    var serviceAddress = Address()
    /// A deposit or milestone request; 0 asks for the full balance.
    var amountDueNow = 0.0
    var amountDueDetail = ""
    /// The Pay button choice. nil on a create = the business's Get Paid default (the form seeds the
    /// same default before it shows the toggle); nil on an edit = leave it as it is.
    var includePayLink: Bool? = nil
    /// The Zelle details choice. nil on a create = the business's Zelle default if configured; nil on an edit = leave it as it is.
    var includeZelle: Bool? = nil
    var autoRemindersEnabled: Bool = false
    var reminderStartTriggerRaw: String = ReminderStartTrigger.oneWeekBeforeDue.rawValue
    var reminderFrequencyRaw: String = ReminderFrequency.weekly.rawValue
    var groups: [InvoiceGroupDraft] = [InvoiceGroupDraft()]

    init() {}

    /// The invoice's current values — the starting point for an edit.
    init(_ invoice: Invoice) {
        jobTitle = invoice.jobTitle
        status = invoice.status
        paymentTerms = invoice.paymentTerms
        dueDate = invoice.dueDate
        taxRatePercent = invoice.taxRatePercent
        discountType = invoice.discountType
        discountValue = invoice.discountValue
        customerNotes = invoice.customerNotes
        terms = invoice.terms
        serviceAddress = invoice.serviceAddress
        amountDueNow = invoice.amountDueNow
        amountDueDetail = invoice.amountDueDetail
        includePayLink = invoice.includePayLink
        includeZelle = invoice.includeZelle
        autoRemindersEnabled = invoice.autoRemindersEnabled
        reminderStartTriggerRaw = invoice.reminderStartTriggerRaw
        reminderFrequencyRaw = invoice.reminderFrequencyRaw
        let drafts = invoice.sortedGroups.map { InvoiceGroupDraft(from: $0) }
        groups = drafts.isEmpty ? [InvoiceGroupDraft()] : drafts
    }

    /// The totals this draft would bill — `Invoice.totals`' formula (InvoiceMath) over the drafts.
    var totals: EstimateTotals {
        InvoiceMath.totals(groups: groups, taxRatePercent: taxRatePercent,
                           discountType: discountType, discountValue: discountValue)
    }
}
