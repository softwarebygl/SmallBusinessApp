//
//  EstimateDraft.swift
//  GLSmallBusiness
//
//  The editable shape of an estimate — what EstimateFormScreen holds in @State and what the
//  assistant's tools build — handed to EstimateService. Moved here from the form, unchanged.
//  `modelID` is the live row a draft was read from (see DocumentDrafts.swift).
//  Wraps GLDocument from GoldLifeDocuments (law 87, Zero Duplication).
//

import Foundation
import SwiftData
import GoldLifeDocuments

struct EstimateLineDraft: Identifiable, Equatable {
    let id = UUID()
    var line: GLDocLine
    /// The live row this draft was read from. nil = a row added in the form; it gets inserted.
    var modelID: PersistentIdentifier? = nil

    var name: String {
        get { line.name }
        set { line.name = newValue }
    }
    var details: String {
        get { line.details }
        set { line.details = newValue }
    }
    var quantity: Double {
        get { line.quantity }
        set { line.quantity = newValue }
    }
    var unit: UnitOfMeasure {
        get { line.unit }
        set { line.unit = newValue }
    }
    var unitPrice: Double {
        get { line.unitPrice }
        set { line.unitPrice = newValue }
    }
    var kind: LineItemKind {
        get { line.kind }
        set { line.kind = newValue }
    }
    var isTaxable: Bool {
        get { line.isTaxable }
        set { line.isTaxable = newValue }
    }
    var discountType: AdjustmentType {
        get { line.discountType }
        set { line.discountType = newValue }
    }
    var discountValue: Double {
        get { line.discountValue }
        set { line.discountValue = newValue }
    }

    init() {
        self.line = GLDocLine()
    }

    init(line: GLDocLine, modelID: PersistentIdentifier? = nil) {
        self.line = line
        self.modelID = modelID
    }

    init(from item: EstimateLineItem) {
        modelID = item.persistentModelID
        let syncIDString = item.syncID?.uuidString ?? UUID().uuidString
        self.line = GLDocLine(id: syncIDString,
                              name: item.name,
                              details: item.details,
                              quantity: item.quantity,
                              unit: item.unit,
                              unitPrice: item.unitPrice,
                              kind: item.kind,
                              isTaxable: item.isTaxable,
                              discountType: item.discountType,
                              discountValue: item.discountValue)
    }

    /// A new line copied from a Price Sheet item (the forms' "From Price Sheet" menu).
    init(priceSheetItem item: PriceSheetItem) {
        self.line = GLDocLine(name: item.name,
                              details: item.details,
                              quantity: item.defaultQuantity,
                              unit: item.unit,
                              unitPrice: item.unitPrice,
                              kind: item.kind,
                              isTaxable: item.isTaxable,
                              discountType: item.discountType,
                              discountValue: item.discountValue)
    }

    /// This line's money, exact — the saved line's formula (law 60).
    var money: LineMoney { line.money }
    var grossLineTotal: Double { line.grossLineTotal }
    var lineDiscount: Double { line.lineDiscount }
    var lineTotal: Double { line.lineTotal }
    var exactLineTotal: Decimal { line.exactLineTotal }
}

struct EstimateGroupDraft: Identifiable, Equatable {
    let id = UUID()
    var group: GLDocGroup
    var lines: [EstimateLineDraft]
    /// The live row this draft was read from. nil = a group added in the form; it gets inserted.
    var modelID: PersistentIdentifier? = nil

    var name: String {
        get { group.name }
        set { group.name = newValue }
    }
    var note: String {
        get { group.note }
        set { group.note = newValue }
    }

    init() {
        self.group = GLDocGroup()
        self.lines = [EstimateLineDraft()]
    }

    init(name: String = "", note: String = "", lines: [EstimateLineDraft]) {
        self.group = GLDocGroup(name: name, note: note)
        self.lines = lines
    }

    init(from group: EstimateGroup) {
        modelID = group.persistentModelID
        let syncIDString = group.syncID?.uuidString ?? UUID().uuidString
        self.group = GLDocGroup(id: syncIDString, name: group.name, note: group.note)
        self.lines = group.sortedLineItems.map { EstimateLineDraft(from: $0) }
        if self.lines.isEmpty { self.lines = [EstimateLineDraft()] }
    }

    var subtotal: Double { DomainMoney.roundedToCents(lines.reduce(Decimal(0)) { $0 + $1.exactLineTotal }) }
}

/// Everything the estimate form edits. The number, created date and customer are not editable.
struct EstimateDraft: Equatable {
    var document: GLDocument
    var status: EstimateStatus = .draft
    /// The job site. Street 1, city, state and ZIP are trimmed on save; an empty Apt/Suite is nil.
    var serviceAddress = Address()
    var groups: [EstimateGroupDraft] = [EstimateGroupDraft()]

    var jobTitle: String {
        get { document.title }
        set { document.title = newValue }
    }
    var validUntil: Date {
        get { document.validUntil ?? Date.now.addingTimeInterval(30 * 24 * 60 * 60) }
        set { document.validUntil = newValue }
    }
    var taxRatePercent: Double {
        get { document.taxRatePercent }
        set { document.taxRatePercent = newValue }
    }
    var combineTotals: Bool {
        get { document.combineTotals }
        set { document.combineTotals = newValue }
    }
    var discountType: AdjustmentType {
        get { document.discountType }
        set { document.discountType = newValue }
    }
    var discountValue: Double {
        get { document.discountValue }
        set { document.discountValue = newValue }
    }
    var depositType: AdjustmentType {
        get { document.depositType }
        set { document.depositType = newValue }
    }
    var depositValue: Double {
        get { document.depositValue }
        set { document.depositValue = newValue }
    }
    var customerNotes: String {
        get { document.customerNotes }
        set { document.customerNotes = newValue }
    }
    var terms: String {
        get { document.terms }
        set { document.terms = newValue }
    }

    init() {
        self.document = GLDocument(kind: .estimate)
        self.status = .draft
        self.serviceAddress = Address()
        self.groups = [EstimateGroupDraft()]
    }

    /// The estimate's current values — the starting point for an edit.
    init(_ estimate: Estimate) {
        let syncIDString = estimate.syncID?.uuidString ?? UUID().uuidString
        self.document = GLDocument(
            id: syncIDString,
            kind: .estimate,
            number: estimate.number,
            title: estimate.jobTitle,
            status: estimate.status.documentStatus,
            createdAt: estimate.createdAt,
            validUntil: estimate.validUntil,
            combineTotals: estimate.combineTotals,
            taxRatePercent: estimate.taxRatePercent,
            discountType: estimate.discountType,
            discountValue: estimate.discountValue,
            depositType: estimate.depositType,
            depositValue: estimate.depositValue,
            customerNotes: estimate.customerNotes,
            terms: estimate.terms
        )
        self.status = estimate.status
        self.serviceAddress = estimate.serviceAddress
        let drafts = estimate.sortedGroups.map { EstimateGroupDraft(from: $0) }
        self.groups = drafts.isEmpty ? [EstimateGroupDraft()] : drafts
    }

    /// The same totals the form's Summary shows (the estimate formula over every group).
    var totals: EstimateTotals {
        EstimateTotals(lines: groups.flatMap(\.lines).map { ($0.exactLineTotal, $0.isTaxable) },
                       taxRatePercent: taxRatePercent,
                       discountType: discountType, discountValue: discountValue,
                       depositType: depositType, depositValue: depositValue)
    }

    /// Synchronizes `groups` and fields into `GLDocument` so the package representation matches.
    var glDocument: GLDocument {
        var doc = document
        doc.title = jobTitle
        doc.status = status.documentStatus
        doc.validUntil = validUntil
        doc.taxRatePercent = taxRatePercent
        doc.combineTotals = combineTotals
        doc.discountType = discountType
        doc.discountValue = discountValue
        doc.depositType = depositType
        doc.depositValue = depositValue
        doc.customerNotes = customerNotes
        doc.terms = terms
        doc.groups = groups.map { grp in
            var g = grp.group
            g.name = grp.name
            g.note = grp.note
            g.lines = grp.lines.map { ln in
                var l = ln.line
                l.name = ln.name
                l.details = ln.details
                l.quantity = ln.quantity
                l.unit = ln.unit
                l.unitPrice = ln.unitPrice
                l.kind = ln.kind
                l.isTaxable = ln.isTaxable
                l.discountType = ln.discountType
                l.discountValue = ln.discountValue
                return l
            }
            return g
        }
        return doc
    }
}
