//
//  MBChangeOrderTools.swift
//  GLSmallBusiness — AI
//
//  The `money` area: `save_change_order` and `apply_change_order`, through `ChangeOrderService` —
//  the same calls the Change Order form and "Add items to invoice" make (law 58).
//
//  A change order is how a PAID invoice still gets extra work (or money back): creating one is a
//  create, which the paid lock allows. Editing an order whose items are already billed on a paid
//  invoice is refused (`.paidLocked` → "change the change order itself"). Anything written to or
//  under a money-locked invoice, and anything that would MAKE the invoice read Paid, asks the
//  person first (contract §5) — and a confirmed write keeps no Undo.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - save_change_order

@MainActor
struct MBSaveChangeOrderTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)

        if let id = args.string("id") {
            guard let order = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) else {
                return MBToolFailure.notFound(.changeOrder)
            }
            let recordID = MBIDs.id(order, env)
            let ref = MBWrite.ref(.changeOrder, recordID)
            if order.isBilledToLockedInvoice { return MBToolFailure.domain(.paidLocked, ref) }
            switch Self.draft(ChangeOrderDraft(order), args) {
            case .outcome(let outcome): return outcome
            case .value(let draft):
                // Under a money-locked invoice: allowed (the order isn't billed), but asked first.
                if order.invoice?.isMoneyLocked == true, let invoice = order.invoice {
                    let number = invoice.number
                    return .needsConfirmation(GLAIConfirmation(
                        recordIDs: [recordID, MBIDs.id(invoice, env)],
                        line: MBWriteStrings.confirmPaidInvoiceEdit(number),
                        actionLabel: MBWriteStrings.confirmContinue,
                        isDestructive: false,
                        declinedMessage: "The user chose not to change \(order.number).",
                        perform: { [env] in Self.save(recordID, draft, env: env, keepUndo: false) }))
                }
                // An applied order's rows are re-pushed onto the invoice, so an edit that takes
                // enough off can settle it — and close the door behind the person (contract §5).
                if let invoice = order.invoice, MoneyLockPreview.wouldLock(order, applying: draft) {
                    let number = invoice.number
                    return .needsConfirmation(GLAIConfirmation(
                        recordIDs: [recordID, MBIDs.id(invoice, env)],
                        line: MBWriteStrings.confirmWouldLock(number),
                        actionLabel: MBWriteStrings.confirmContinue,
                        isDestructive: false,
                        declinedMessage: "The user chose not to change \(order.number).",
                        perform: { [env] in Self.save(recordID, draft, env: env, keepUndo: false) }))
                }
                return Self.save(recordID, draft, env: env, keepUndo: true)
            }
        }

        guard let invoiceID = args.string("invoice_id"),
              let invoice = MBRecordLookup.record(.invoice, id: invoiceID, as: Invoice.self, in: store) else {
            return MBToolFailure.invalid("A new change order needs invoice_id. Use find to get the invoice id.")
        }
        switch Self.draft(ChangeOrderDraft(title: "", note: "", items: []), args) {
        case .outcome(let outcome): return outcome
        case .value(let draft):
            guard draft.hasNamedItem else {
                return MBToolFailure.domain(.itemRequired, MBWrite.ref(.invoice, MBIDs.id(invoice, env)))
            }
            let invoiceRecordID = MBIDs.id(invoice, env)
            if invoice.isMoneyLocked {
                let number = invoice.number
                return .needsConfirmation(GLAIConfirmation(
                    recordIDs: [invoiceRecordID],
                    line: MBWriteStrings.confirmPaidInvoiceEdit(number),
                    actionLabel: MBWriteStrings.confirmContinue,
                    isDestructive: false,
                    declinedMessage: "The user chose not to add a change order to \(number).",
                    perform: { [env] in Self.create(invoiceRecordID, draft, env: env, keepUndo: false) }))
            }
            return Self.create(invoiceRecordID, draft, env: env, keepUndo: true)
        }
    }

    // MARK: The writes

    static func create(_ invoiceID: String, _ draft: ChangeOrderDraft, env: MBToolEnvironment,
                       keepUndo: Bool) -> GLAIToolOutcome {
        guard let store = env.context(), let invoice = MBWrite.invoice(invoiceID, env) else {
            return MBToolFailure.notFound(.invoice)
        }
        let order: ChangeOrder
        do {
            order = try ChangeOrderService.create(draft, on: invoice, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, MBWrite.ref(.invoice, invoiceID))
        }
        let recordID = MBIDs.id(order, env)
        let ref = MBWrite.ref(.changeOrder, recordID)
        env.ledger.note(recordID, MBFingerprint.of(order))
        let number = order.number
        let dto = MBRecordDTO(env: env, context: store)
        let undo = keepUndo ? undoCreate(recordID, number: number, env: env) : nil
        return .result(["ok": true, "change_order": dto.row(order)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.changeOrder,
                                               title: MBWriteStrings.changeOrderCreated,
                                               detail: number, record: ref)],
                       undo: undo)
    }

    static func save(_ recordID: String, _ draft: ChangeOrderDraft, env: MBToolEnvironment,
                     keepUndo: Bool) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.changeOrder, recordID)
        guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
            return MBToolFailure.notFound(.changeOrder)
        }
        let before = ChangeOrderDraft(order)
        let matched: Bool
        do {
            matched = try ChangeOrderService.update(order, with: draft, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(order))
        let number = order.number
        let undo = keepUndo ? undoEdit(recordID, number: number, before: before, env: env) : nil
        let dto = MBRecordDTO(env: env, context: store)
        var output: [String: GLAIJSON] = ["ok": true, "change_order": dto.row(order)]
        if !matched {
            output["items_left_on_invoice"] = true
            output["message"] = "Its billed items couldn't be matched on the invoice, so the invoice still bills the old amounts. Tell the user to fix them on the invoice."
        }
        return .result(.object(output),
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.changeOrder,
                                               title: MBWriteStrings.changeOrderUpdated,
                                               detail: number, record: ref)],
                       undo: undo)
    }

    // MARK: Arguments

    /// Only the sent fields change; `items` replaces the whole list (the manifest's rule).
    static func draft(_ base: ChangeOrderDraft, _ args: MBArguments) -> MBStep<ChangeOrderDraft> {
        var draft = base
        if let value = args.json["title"]?.stringValue { draft.title = value }
        if let value = args.json["note"]?.stringValue { draft.note = value }
        guard args.has("items") else { return .value(draft) }
        var lines: [ChangeOrderLineDraft] = []
        for raw in args.objects("items") {
            let item = MBArguments(json: raw)
            guard let name = item.string("name") else {
                return .outcome(MBToolFailure.invalid("Every change order item needs a name."))
            }
            var line = ChangeOrderLineDraft()
            line.name = name
            line.quantity = item.number("quantity") ?? 1
            if let unit = item.raw("unit", UnitOfMeasure.self) { line.unit = unit }
            line.unitPrice = item.number("unit_price") ?? 0
            line.isCredit = item.bool("is_credit") ?? false
            line.isTaxable = item.bool("taxable") ?? false
            lines.append(line)
        }
        draft.items = lines
        return .value(draft)
    }

    // MARK: Undo

    private static func undoCreate(_ recordID: String, number: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.changeOrder, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(changeOrder: number), ledger: env.ledger,
                            fingerprint: { MBWrite.changeOrder(recordID, env).map(MBFingerprint.of) },
                            dropReason: { lockedReason(recordID, env) }) {
            guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
                return MBUndo.recordGone
            }
            let label = order.number
            do {
                try DeletionService.delete([.changeOrder(order)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.changeOrder,
                                   MBWriteStrings.deleted(.changeOrder), detail: label, record: nil)
        }
    }

    private static func undoEdit(_ recordID: String, number: String, before: ChangeOrderDraft,
                                 env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.changeOrder, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(changeOrder: number), ledger: env.ledger,
                            fingerprint: { MBWrite.changeOrder(recordID, env).map(MBFingerprint.of) },
                            dropReason: { lockedReason(recordID, env) }) {
            guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
                return MBUndo.recordGone
            }
            do {
                _ = try ChangeOrderService.update(order, with: before, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(order))
            return MBUndo.reverted(.updated, MBWriteSymbol.changeOrder, MBWriteStrings.changeOrderRestored,
                                   detail: order.number, record: ref)
        }
    }

    /// Money landed on the invoice after the write: the entry is dropped, and the card says why.
    static func lockedReason(_ recordID: String, _ env: MBToolEnvironment) -> LocalizedStringResource? {
        guard let order = MBWrite.changeOrder(recordID, env),
              order.invoice?.isMoneyLocked == true else { return nil }
        return MBWriteStrings.undoDroppedPaid
    }
}

// MARK: - apply_change_order

@MainActor
struct MBApplyChangeOrderTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let id = args.string("id"),
              let order = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) else {
            return MBToolFailure.notFound(.changeOrder)
        }
        let recordID = MBIDs.id(order, env)
        let ref = MBWrite.ref(.changeOrder, recordID)
        guard let invoice = order.invoice else { return MBToolFailure.domain(.recordNotFound, ref) }
        guard order.status == .approved else {
            return .failure(GLAIFailure(
                reason: DomainError.changeOrderNotApproved.code,
                message: "Only an approved change order can be added to the invoice. Ask the user, then set_status it to approved first.",
                personReason: DomainError.changeOrderNotApproved.personReason, record: ref))
        }
        guard !order.appliedToInvoice else {
            let dto = MBRecordDTO(env: env, context: store)
            return .result(["ok": true, "already_applied": true, "change_order": dto.row(order),
                            "invoice": dto.row(invoice)])
        }
        // A credit that covers the balance would leave the invoice paid — and locked.
        if MoneyLockPreview.wouldLock(applying: order) {
            let number = invoice.number
            return .needsConfirmation(GLAIConfirmation(
                recordIDs: [recordID, MBIDs.id(invoice, env)],
                line: MBWriteStrings.confirmWouldLock(number),
                actionLabel: MBWriteStrings.confirmContinue,
                isDestructive: false,
                declinedMessage: "The user chose not to add \(order.number) to \(number).",
                perform: { [env] in Self.apply(recordID, env: env, keepUndo: false) }))
        }
        return Self.apply(recordID, env: env, keepUndo: true)
    }

    static func apply(_ recordID: String, env: MBToolEnvironment, keepUndo: Bool) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.changeOrder, recordID)
        guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
            return MBToolFailure.notFound(.changeOrder)
        }
        do {
            try ChangeOrderService.applyToInvoice(order, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(order))
        let number = order.number
        let dto = MBRecordDTO(env: env, context: store)
        let invoiceRow = order.invoice.map { dto.row($0) } ?? .null
        let undo = keepUndo ? undoApply(recordID, number: number, env: env) : nil
        return .result(["ok": true, "change_order": dto.row(order), "invoice": invoiceRow],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.changeOrder,
                                               title: MBWriteStrings.changeOrderApplied,
                                               detail: number, record: ref)],
                       undo: undo)
    }

    /// Taking the items back off is the same write "Add items to invoice" reverses — through the
    /// status door the screens use, then straight back to Approved.
    private static func undoApply(_ recordID: String, number: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.changeOrder, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(changeOrder: number), ledger: env.ledger,
                            fingerprint: { MBWrite.changeOrder(recordID, env).map(MBFingerprint.of) },
                            dropReason: { MBSaveChangeOrderTool.lockedReason(recordID, env) }) {
            guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
                return MBUndo.recordGone
            }
            // Dropping the charge can leave the invoice fully paid — which would lock it.
            if MoneyLockPreview.wouldLock(removing: order) {
                return .failed(MBWriteStrings.undoWouldPayInvoice)
            }
            do {
                _ = try ChangeOrderService.setStatus(order, .pending, in: store, subscription: env.subscription())
                _ = try ChangeOrderService.setStatus(order, .approved, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(order))
            return MBUndo.reverted(.updated, MBWriteSymbol.changeOrder, MBWriteStrings.changeOrderRestored,
                                   detail: order.number, record: ref)
        }
    }
}
