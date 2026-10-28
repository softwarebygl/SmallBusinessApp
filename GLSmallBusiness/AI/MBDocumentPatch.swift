//
//  MBDocumentPatch.swift
//  GLSmallBusiness — AI
//
//  The groups-and-lines half of `create_estimate`, `edit_estimate`, `create_invoice` and
//  `edit_invoice`, written once for both documents.
//
//  A tool never writes rows itself: it builds the SAME draft the form holds (`EstimateDraft` /
//  `InvoiceDraft`, rows carrying the `modelID` of the live row they came from) and hands it to the
//  service, whose `RowReconciler` updates rows in place, inserts the new ones and deletes the ones
//  no draft names. That is why an edit here can't mint a second estimate (Pillar 2) and why an
//  untouched row queues no sync op.
//
//  Ids in and out are `syncID`s. A row the model names that isn't on this document is the model's
//  own slip (`invalid_arguments`, corrected by re-reading with `get`). Change-order rows are
//  off limits on an invoice (`changeOrderLinesReadOnly`): they are changed on the change order.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - What the two drafts have in common

/// One line of a money document, as the form's draft holds it.
protocol MBLinePatchable {
    init()
    init(priceSheetItem item: PriceSheetItem)
    var name: String { get set }
    var details: String { get set }
    var quantity: Double { get set }
    var unit: UnitOfMeasure { get set }
    var unitPrice: Double { get set }
    var kind: LineItemKind { get set }
    var isTaxable: Bool { get set }
    var discountType: AdjustmentType { get set }
    var discountValue: Double { get set }
    var modelID: PersistentIdentifier? { get set }
}

/// One group of lines, as the form's draft holds it.
protocol MBGroupPatchable {
    associatedtype Line: MBLinePatchable
    init(name: String, note: String, lines: [Line])
    var name: String { get set }
    var note: String { get set }
    var lines: [Line] { get set }
    var modelID: PersistentIdentifier? { get set }
}

extension EstimateLineDraft: MBLinePatchable {}
extension EstimateGroupDraft: MBGroupPatchable {}
extension InvoiceLineDraft: MBLinePatchable {}
extension InvoiceGroupDraft: MBGroupPatchable {}

// MARK: - The patcher

@MainActor
struct MBDocumentPatcher<Group: MBGroupPatchable> {

    /// Why a patch was refused. `invalid` is the model's own slip (it corrects it and calls again);
    /// `refusal` is a rule the app enforces for a person too.
    enum PatchError: Error {
        case invalid(String)
        case refusal(DomainError)
    }

    let env: MBToolEnvironment
    let store: ModelContext
    /// Group id (`syncID`) → the live row it names.
    var groupsByID: [String: PersistentIdentifier] = [:]
    /// Line id (`syncID`) → the live row it names.
    var linesByID: [String: PersistentIdentifier] = [:]
    /// Rows a change order owns: read-only here (invoices only).
    var lockedGroups: Set<PersistentIdentifier> = []
    var lockedLines: Set<PersistentIdentifier> = []

    // MARK: Building from scratch (create)

    /// The `groups` argument of a create: at least one group, each with at least one line.
    func newGroups(_ raw: [GLAIJSON]) throws -> [Group] {
        var groups: [Group] = []
        for entry in raw {
            let lines = try (entry["lines"]?.arrayValue ?? []).map { try newLine($0) }
            guard !lines.isEmpty else {
                throw PatchError.invalid("Every group needs at least one line.")
            }
            groups.append(Group(name: entry["name"]?.stringValue ?? "",
                                note: entry["note"]?.stringValue ?? "",
                                lines: lines))
        }
        guard !groups.isEmpty else { throw PatchError.invalid("Send at least one group of lines.") }
        return groups
    }

    /// A line the model described: the price sheet item it names (when it names one), then every
    /// field it sent on top.
    func newLine(_ raw: GLAIJSON) throws -> Group.Line {
        var line = Group.Line()
        if let itemID = raw["price_item_id"]?.stringValue {
            guard let item = MBRecordLookup.record(.priceItem, id: itemID, as: PriceSheetItem.self, in: store) else {
                throw PatchError.invalid("No price sheet item has the id \(itemID). Use find kind price_item.")
            }
            line = Group.Line(priceSheetItem: item)
        }
        try patch(&line, raw, isNew: true)
        guard !line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatchError.invalid("Every line needs a name.")
        }
        return line
    }

    // MARK: Patching an existing document (edit)

    /// The manifest's edit shape, in the order the form would do it: rename groups, remove what is
    /// named, then add or change lines.
    func apply(_ args: MBArguments, to groups: [Group]) throws -> [Group] {
        var groups = groups
        try rename(args.objects("groups"), in: &groups)
        try removeGroups(args.strings("remove_group_ids"), from: &groups)
        try removeLines(args.strings("remove_line_ids"), from: &groups)
        try patchLines(args.objects("lines"), in: &groups)
        return groups
    }

    private func rename(_ raw: [GLAIJSON], in groups: inout [Group]) throws {
        for entry in raw {
            guard let id = entry["group_id"]?.stringValue else {
                throw PatchError.invalid("Each group to rename needs its group_id.")
            }
            let index = try groupIndex(id, in: groups)
            try requireUnlockedGroup(groups[index])
            if let name = entry["name"]?.stringValue { groups[index].name = name }
            if let note = entry["note"]?.stringValue { groups[index].note = note }
        }
    }

    private func removeGroups(_ ids: [String], from groups: inout [Group]) throws {
        for id in ids {
            let index = try groupIndex(id, in: groups)
            try requireUnlockedGroup(groups[index])
            groups.remove(at: index)
        }
    }

    private func removeLines(_ ids: [String], from groups: inout [Group]) throws {
        for id in ids {
            let (groupIndex, lineIndex) = try lineIndex(id, in: groups)
            try requireUnlockedLine(groups[groupIndex].lines[lineIndex])
            groups[groupIndex].lines.remove(at: lineIndex)
        }
    }

    private func patchLines(_ raw: [GLAIJSON], in groups: inout [Group]) throws {
        // Several new lines naming the same new_group land in ONE new group, the way a person
        // would add them.
        var newGroupIndexes: [String: Int] = [:]
        for entry in raw {
            if let lineID = entry["line_id"]?.stringValue {
                let (groupIndex, lineIndex) = try self.lineIndex(lineID, in: groups)
                try requireUnlockedLine(groups[groupIndex].lines[lineIndex])
                if let itemID = entry["price_item_id"]?.stringValue {
                    guard let item = MBRecordLookup.record(.priceItem, id: itemID, as: PriceSheetItem.self, in: store) else {
                        throw PatchError.invalid("No price sheet item has the id \(itemID). Use find kind price_item.")
                    }
                    let saved = groups[groupIndex].lines[lineIndex].modelID
                    var replacement = Group.Line(priceSheetItem: item)
                    replacement.modelID = saved
                    groups[groupIndex].lines[lineIndex] = replacement
                }
                try patch(&groups[groupIndex].lines[lineIndex], entry, isNew: false)
                continue
            }

            let line = try newLine(entry)
            if let name = entry["new_group"]?.stringValue, !name.isEmpty {
                if let index = newGroupIndexes[name] {
                    groups[index].lines.append(line)
                } else {
                    groups.append(Group(name: name, note: "", lines: [line]))
                    newGroupIndexes[name] = groups.count - 1
                }
                continue
            }
            let index: Int
            if let groupID = entry["group_id"]?.stringValue {
                index = try groupIndex(groupID, in: groups)
            } else {
                guard let last = groups.indices.last else {
                    throw PatchError.invalid("This document has no group yet. Send new_group with the line.")
                }
                index = last
            }
            try requireUnlockedGroup(groups[index])
            groups[index].lines.append(line)
        }
    }

    // MARK: Change-order rows

    /// A group a change order owns is shown, never edited (InvoiceFormScreen): it comes off by
    /// declining or deleting that order.
    private func requireUnlockedGroup(_ group: Group) throws {
        guard let id = group.modelID, lockedGroups.contains(id) else { return }
        throw PatchError.refusal(.changeOrderLinesReadOnly)
    }

    /// A change-order line is read-only on the invoice (the form disables its delete).
    private func requireUnlockedLine(_ line: Group.Line) throws {
        guard let id = line.modelID, lockedLines.contains(id) else { return }
        throw PatchError.refusal(.changeOrderLinesReadOnly)
    }

    // MARK: Fields

    private func patch(_ line: inout Group.Line, _ raw: GLAIJSON, isNew: Bool) throws {
        let args = MBArguments(json: raw)
        if let name = raw["name"]?.stringValue { line.name = name }
        if let details = raw["details"]?.stringValue { line.details = details }
        if let quantity = args.number("quantity") { line.quantity = quantity }
        if let unit = args.raw("unit", UnitOfMeasure.self) { line.unit = unit }
        else if raw["unit"] != nil { throw PatchError.invalid("unit must be one of the listed units.") }
        if let price = args.number("unit_price") { line.unitPrice = price }
        var kindChanged = false
        if let kind = args.raw("kind", LineItemKind.self) {
            kindChanged = kind != line.kind
            line.kind = kind
        } else if raw["kind"] != nil {
            throw PatchError.invalid("kind must be labor or material.")
        }
        if let taxable = args.bool("taxable") {
            line.isTaxable = taxable
        } else if kindChanged, isNew {
            // The form's rule: materials are taxable by default, labor isn't (LineItemKind).
            line.isTaxable = line.kind.defaultTaxable
        }
        if let type = args.raw("discount_type", AdjustmentType.self) { line.discountType = type }
        else if raw["discount_type"] != nil { throw PatchError.invalid("discount_type must be none, percentage or fixed.") }
        if let value = args.number("discount_value") { line.discountValue = value }
    }

    // MARK: Ids

    private func groupIndex(_ id: String, in groups: [Group]) throws -> Int {
        guard let modelID = groupsByID[id], let index = groups.firstIndex(where: { $0.modelID == modelID }) else {
            throw PatchError.invalid("No group on this document has the id \(id). Read it with get first.")
        }
        return index
    }

    private func lineIndex(_ id: String, in groups: [Group]) throws -> (Int, Int) {
        guard let modelID = linesByID[id] else {
            throw PatchError.invalid("No line on this document has the id \(id). Read it with get first.")
        }
        for (groupIndex, group) in groups.enumerated() {
            if let lineIndex = group.lines.firstIndex(where: { $0.modelID == modelID }) {
                return (groupIndex, lineIndex)
            }
        }
        throw PatchError.invalid("No line on this document has the id \(id). Read it with get first.")
    }
}
