//
//  MBExpenseCatalogTools.swift
//  GLSmallBusiness — AI
//
//  The `expenses` and `catalog` areas' writes: `save_receipt` (through `ReceiptService`, the
//  Receipt form's own save) and `save_price_item` (through `PriceSheetService`, the Price Sheet
//  item form's save). Photos and scans never come through here — the model never sees a receipt
//  image; `pick_media` hands the camera, the scanner or the file picker to the person, and only
//  `remove_photo` takes one off from this side.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - save_receipt

@MainActor
struct MBSaveReceiptTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        let dto = MBRecordDTO(env: env, context: store)

        if let id = args.string("id") {
            guard let receipt = MBRecordLookup.record(.receipt, id: id, as: Receipt.self, in: store) else {
                return MBToolFailure.notFound(.receipt)
            }
            let recordID = MBIDs.id(receipt, env)
            let ref = MBWrite.ref(.receipt, recordID)
            let before = MBReceiptSnapshot(receipt)
            switch Self.patched(ReceiptDraft(receipt), args, value, store) {
            case .outcome(let outcome): return outcome
            case .value(let draft):
                do {
                    try ReceiptService.update(receipt, with: draft, in: store, subscription: env.subscription())
                } catch {
                    return MBToolFailure.unexpected(error, ref)
                }
                env.ledger.note(recordID, MBFingerprint.stamp(receipt))
                return .result(["ok": true, "receipt": dto.row(receipt)],
                               activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.receipt,
                                                       title: MBWriteStrings.receiptUpdated,
                                                       detail: receipt.displayVendor, record: ref)],
                               undo: Self.undoEdit(recordID, before: before, env: env))
            }
        }

        switch Self.patched(ReceiptDraft(date: env.calendar.startOfDay(for: env.now())), args, value, store) {
        case .outcome(let outcome): return outcome
        case .value(let draft):
            let receipt: Receipt
            do {
                receipt = try ReceiptService.create(draft, in: store, subscription: env.subscription())
            } catch {
                return MBToolFailure.unexpected(error)
            }
            let recordID = MBIDs.id(receipt, env)
            let ref = MBWrite.ref(.receipt, recordID)
            env.ledger.note(recordID, MBFingerprint.stamp(receipt))
            return .result(["ok": true, "receipt": dto.row(receipt)],
                           activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.receipt,
                                                   title: MBWriteStrings.receiptAdded,
                                                   detail: receipt.displayVendor, record: ref)],
                           undo: Self.undoCreate(recordID, vendor: receipt.displayVendor, env: env))
        }
    }

    /// Only the sent fields change. `customer_id` / `job_id` null clears the link.
    static func patched(_ base: ReceiptDraft, _ args: MBArguments, _ value: MBValue,
                        _ store: ModelContext) -> MBStep<ReceiptDraft> {
        var draft = base
        if let vendor = args.json["vendor"]?.stringValue { draft.vendor = vendor }
        if args.has("date") {
            guard let date = value.parseDay(args.string("date")) else {
                return .outcome(MBToolFailure.invalid("date must be a day, YYYY-MM-DD."))
            }
            draft.date = date
        }
        if let total = args.money("total") { draft.total = total }
        if let category = args.json["category"]?.stringValue { draft.category = category }
        if let notes = args.json["notes"]?.stringValue { draft.notes = notes }
        if args.has("customer_id") {
            if args.isNull("customer_id") {
                draft.customer = nil
            } else {
                guard let id = args.string("customer_id"),
                      let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                    return .outcome(MBToolFailure.notFound(.customer))
                }
                draft.customer = customer
            }
        }
        if args.has("job_id") {
            if args.isNull("job_id") {
                draft.job = nil
            } else {
                guard let id = args.string("job_id"),
                      let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
                    return .outcome(MBToolFailure.notFound(.job))
                }
                draft.job = job
            }
        }
        if args.bool("remove_photo") == true {
            draft.scanData = nil
            draft.recognizedText = ""
        }
        return .value(draft)
    }

    // MARK: Undo

    static func undoCreate(_ recordID: String, vendor: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.receipt, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(receipt: vendor), ledger: env.ledger,
                            fingerprint: { MBReceiptSnapshot.find(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let receipt = MBReceiptSnapshot.find(recordID, env) else {
                return MBUndo.recordGone
            }
            let label = receipt.displayVendor
            do {
                try DeletionService.delete([.receipt(receipt)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.receipt, MBWriteStrings.deleted(.receipt),
                                   detail: label, record: nil)
        }
    }

    static func undoEdit(_ recordID: String, before: MBReceiptSnapshot, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.receipt, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(receipt: before.vendor), ledger: env.ledger,
                            fingerprint: { MBReceiptSnapshot.find(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let receipt = MBReceiptSnapshot.find(recordID, env) else {
                return MBUndo.recordGone
            }
            do {
                // `.screen` on the way back: these are the receipt's own stored values.
                try ReceiptService.update(receipt, with: before.draft(receipt, in: store), origin: .screen,
                                          in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(receipt))
            return MBUndo.reverted(.updated, MBWriteSymbol.receipt, MBWriteStrings.receiptRestored,
                                   detail: receipt.displayVendor, record: ref)
        }
    }
}

/// A receipt's "before" values, held as ids and plain values — never a `@Model` in an Undo closure.
@MainActor
struct MBReceiptSnapshot {
    let vendor: String
    let date: Date
    let total: Double
    let category: String
    let notes: String
    let customerID: String?
    let jobID: String?

    init(_ receipt: Receipt) {
        vendor = receipt.vendor
        date = receipt.date
        total = receipt.total
        category = receipt.category
        notes = receipt.notes
        customerID = receipt.customer?.syncID?.uuidString
        jobID = receipt.job?.syncID?.uuidString
    }

    /// The draft that puts those values back — the photo and its scanned text are left as they are.
    func draft(_ receipt: Receipt, in store: ModelContext) -> ReceiptDraft {
        var draft = ReceiptDraft(receipt)
        draft.vendor = vendor
        draft.date = date
        draft.total = total
        draft.category = category
        draft.notes = notes
        draft.customer = customerID.flatMap {
            MBRecordLookup.record(.customer, id: $0, as: Customer.self, in: store)
        }
        draft.job = jobID.flatMap { MBRecordLookup.record(.job, id: $0, as: ScheduledJob.self, in: store) }
        return draft
    }

    static func find(_ recordID: String, _ env: MBToolEnvironment) -> Receipt? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.receipt, id: recordID, as: Receipt.self, in: store)
    }
}

// MARK: - save_price_item

@MainActor
struct MBSavePriceItemTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let dto = MBRecordDTO(env: env, context: store)

        if let id = args.string("id") {
            guard let item = MBRecordLookup.record(.priceItem, id: id, as: PriceSheetItem.self, in: store) else {
                return MBToolFailure.notFound(.priceItem)
            }
            let recordID = MBIDs.id(item, env)
            let ref = MBWrite.ref(.priceItem, recordID)
            let before = PriceItemDraft(item)
            let draft = Self.patched(before, args)
            do {
                try PriceSheetService.update(item, with: draft, in: store, now: env.now(),
                                             subscription: env.subscription())
            } catch {
                return MBToolFailure.unexpected(error, ref)
            }
            env.ledger.note(recordID, MBFingerprint.of(item))
            return .result(["ok": true, "price_item": dto.row(item)],
                           activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.priceItem,
                                                   title: MBWriteStrings.priceItemUpdated,
                                                   detail: item.name, record: ref)],
                           undo: Self.undoEdit(recordID, before: before, env: env))
        }

        let draft = Self.patched(PriceItemDraft(), args)
        let item: PriceSheetItem
        do {
            item = try PriceSheetService.create(draft, in: store, now: env.now(), subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }
        let recordID = MBIDs.id(item, env)
        let ref = MBWrite.ref(.priceItem, recordID)
        env.ledger.note(recordID, MBFingerprint.of(item))
        return .result(["ok": true, "price_item": dto.row(item)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.priceItem,
                                               title: MBWriteStrings.priceItemAdded,
                                               detail: item.name, record: ref)],
                       undo: Self.undoCreate(recordID, name: item.name, env: env))
    }

    static func patched(_ base: PriceItemDraft, _ args: MBArguments) -> PriceItemDraft {
        var draft = base
        if let value = args.json["name"]?.stringValue { draft.name = value }
        if let value = args.json["category"]?.stringValue { draft.category = value }
        if let value = args.json["details"]?.stringValue { draft.details = value }
        if let value = args.number("default_quantity") { draft.defaultQuantity = value }
        if let unit = args.raw("unit", UnitOfMeasure.self) { draft.unit = unit }
        if let value = args.number("unit_price") { draft.unitPrice = value }
        if let kind = args.raw("kind", LineItemKind.self) { draft.kind = kind }
        if let taxable = args.bool("taxable") { draft.isTaxable = taxable }
        if let type = args.raw("discount_type", AdjustmentType.self) { draft.discountType = type }
        if let value = args.number("discount_value") { draft.discountValue = value }
        return draft
    }

    // MARK: Undo

    private static func item(_ recordID: String, _ env: MBToolEnvironment) -> PriceSheetItem? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.priceItem, id: recordID, as: PriceSheetItem.self, in: store)
    }

    static func undoCreate(_ recordID: String, name: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.priceItem, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(priceItem: name), ledger: env.ledger,
                            fingerprint: { item(recordID, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let item = item(recordID, env) else { return MBUndo.recordGone }
            let label = item.name
            do {
                try DeletionService.delete([.priceItem(item)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.priceItem, MBWriteStrings.deleted(.priceItem),
                                   detail: label, record: nil)
        }
    }

    static func undoEdit(_ recordID: String, before: PriceItemDraft, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.priceItem, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(priceItem: before.name), ledger: env.ledger,
                            fingerprint: { item(recordID, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let item = item(recordID, env) else { return MBUndo.recordGone }
            do {
                try PriceSheetService.update(item, with: before, origin: .screen, in: store,
                                             now: env.now(), subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(item))
            return MBUndo.reverted(.updated, MBWriteSymbol.priceItem, MBWriteStrings.priceItemRestored,
                                   detail: item.name, record: ref)
        }
    }
}
