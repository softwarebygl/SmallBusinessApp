//
//  MBStatusTool.swift
//  GLSmallBusiness — AI
//
//  `set_status` for the four records that have one — through `EstimateService`, `InvoiceService`,
//  `ChangeOrderService` and `JobService`, the same calls the detail screens' status controls make.
//
//  Paid, overdue and expired are not statuses: they follow from the numbers and the dates, so the
//  way to mark an invoice paid is `record_payment`. A paid invoice's status is locked (offer a
//  change order); a change order billed to a paid invoice can't leave Approved. Marking a $0
//  invoice Sent, or un-approving a charge, can make an invoice read Paid — which locks it — so
//  those ask first.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBSetStatusTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let kindName = args.string("kind"), let kind = MBRecordKind(rawValue: kindName),
              [.estimate, .contract, .invoice, .changeOrder, .job].contains(kind) else {
            return MBToolFailure.invalid("kind must be estimate, contract, invoice, change_order or job.")
        }
        guard let id = args.string("id") else { return MBToolFailure.invalid("id is required.") }
        guard let status = args.string("status") else { return MBToolFailure.invalid("status is required.") }

        switch kind {
        case .estimate: return estimate(id, status, store)
        case .contract: return contract(id, status, store)
        case .invoice: return invoice(id, status, store)
        case .changeOrder: return changeOrder(id, status, store)
        default: return job(id, status, store)
        }
    }

    // MARK: Contract

    private func contract(_ id: String, _ raw: String, _ store: ModelContext) -> GLAIToolOutcome {
        guard let status = ContractStatus(rawValue: raw) else {
            return MBToolFailure.invalid("A contract's status is draft, signed, inProgress or completed.")
        }
        guard let contract = MBRecordLookup.record(.contract, id: id, as: Contract.self, in: store) else {
            return MBToolFailure.notFound(.contract)
        }
        let recordID = MBIDs.id(contract, env)
        let ref = MBWrite.ref(.contract, recordID)
        let before = contract.status
        contract.statusRaw = status.rawValue
        if status == .completed {
            contract.completedAt = .now
        }
        if let job = contract.scheduledJob {
            if status == .inProgress { job.statusRaw = JobStatus.inProgress.rawValue }
            else if status == .completed { job.statusRaw = JobStatus.completed.rawValue }
        }
        store.saveChanges()
        env.ledger.note(recordID, MBFingerprint.of(contract))
        let dto = MBRecordDTO(env: env, context: store)
        let undo = MBUndo.entry(ref, title: MBWriteStrings.undoTitle(contract: contract.number),
                                ledger: env.ledger,
                                fingerprint: { MBWrite.contract(recordID, env).map(MBFingerprint.of) }) { [env] in
            guard let store = env.context(), let contract = MBWrite.contract(recordID, env) else {
                return MBUndo.recordGone
            }
            contract.statusRaw = before.rawValue
            store.saveChanges()
            env.ledger.note(recordID, MBFingerprint.of(contract))
            return MBUndo.reverted(.updated, MBWriteSymbol.contract, MBWriteStrings.contractRestored,
                                   detail: contract.number, record: ref)
        }
        return .result(["ok": true, "contract": dto.row(contract)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.status,
                                               title: MBWriteStrings.contractStatusChanged,
                                               detail: "\(contract.number) · \(status.label)", record: ref)],
                       undo: undo)
    }

    // MARK: Estimate

    private func estimate(_ id: String, _ raw: String, _ store: ModelContext) -> GLAIToolOutcome {
        guard let status = EstimateStatus(rawValue: raw) else {
            return MBToolFailure.invalid("An estimate's status is draft, sent, accepted or declined.")
        }
        guard let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
            return MBToolFailure.notFound(.estimate)
        }
        let recordID = MBIDs.id(estimate, env)
        let ref = MBWrite.ref(.estimate, recordID)
        let before = estimate.status
        do {
            try EstimateService.setStatus(estimate, status, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(estimate))
        let dto = MBRecordDTO(env: env, context: store)
        let undo = MBUndo.entry(ref, title: MBWriteStrings.undoTitle(estimate: estimate.number),
                                ledger: env.ledger,
                                fingerprint: { MBWrite.estimate(recordID, env).map(MBFingerprint.of) }) { [env] in
            guard let store = env.context(), let estimate = MBWrite.estimate(recordID, env) else {
                return MBUndo.recordGone
            }
            do {
                try EstimateService.setStatus(estimate, before, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(estimate))
            return MBUndo.reverted(.updated, MBWriteSymbol.estimate, MBWriteStrings.estimateRestored,
                                   detail: estimate.number, record: ref)
        }
        return .result(["ok": true, "estimate": dto.row(estimate)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.status,
                                               title: MBWriteStrings.estimateStatusChanged,
                                               detail: "\(estimate.number) · \(status.label)", record: ref)],
                       undo: undo)
    }

    // MARK: Invoice

    private func invoice(_ id: String, _ raw: String, _ store: ModelContext) -> GLAIToolOutcome {
        guard let status = InvoiceStatus(rawValue: raw) else {
            return MBToolFailure.invalid(
                "An invoice's status is draft or sent. Paid and overdue follow from the numbers and dates.")
        }
        guard let invoice = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) else {
            return MBToolFailure.notFound(.invoice)
        }
        let recordID = MBIDs.id(invoice, env)
        let ref = MBWrite.ref(.invoice, recordID)
        if invoice.isMoneyLocked { return MBToolFailure.domain(.paidLocked, ref) }
        let before = invoice.status
        guard !MoneyLockPreview.wouldLock(invoice, status: status) else {
            let number = invoice.number
            return .needsConfirmation(GLAIConfirmation(
                recordIDs: [recordID],
                line: MBWriteStrings.confirmWouldLock(number),
                actionLabel: MBWriteStrings.confirmContinue,
                isDestructive: false,
                declinedMessage: "The user chose not to change the status of \(number).",
                perform: { [env] in
                    Self.applyInvoiceStatus(recordID, status, before: before, env: env, keepUndo: false)
                }))
        }
        return Self.applyInvoiceStatus(recordID, status, before: before, env: env, keepUndo: true)
    }

    static func applyInvoiceStatus(_ recordID: String, _ status: InvoiceStatus, before: InvoiceStatus,
                                   env: MBToolEnvironment, keepUndo: Bool) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.invoice, recordID)
        guard let store = env.context(), let invoice = MBWrite.invoice(recordID, env) else {
            return MBToolFailure.notFound(.invoice)
        }
        do {
            try InvoiceService.setStatus(invoice, status, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(invoice))
        let payments = invoice.sortedPayments.count
        let undo = keepUndo
            ? MBUndo.entry(ref, title: MBWriteStrings.undoTitle(invoice: invoice.number), ledger: env.ledger,
                           fingerprint: { MBWrite.invoice(recordID, env).map(MBFingerprint.of) },
                           dropReason: MBInvoiceDraftBuilder.dropReason(ref, env: env, paymentsAtWrite: payments)) {
                guard let store = env.context(), let invoice = MBWrite.invoice(recordID, env) else {
                    return MBUndo.recordGone
                }
                do {
                    try InvoiceService.setStatus(invoice, before, in: store, subscription: env.subscription())
                } catch {
                    return MBWrite.revertFailure(error)
                }
                env.ledger.note(recordID, MBFingerprint.of(invoice))
                return MBUndo.reverted(.updated, MBWriteSymbol.invoice, MBWriteStrings.invoiceRestored,
                                       detail: invoice.number, record: ref)
            }
            : nil
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "invoice": dto.row(invoice), "locked_paid": .bool(invoice.isMoneyLocked)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.status,
                                               title: MBWriteStrings.invoiceStatusChanged,
                                               detail: "\(invoice.number) · \(status.label)", record: ref)],
                       undo: undo)
    }

    // MARK: Change order

    private func changeOrder(_ id: String, _ raw: String, _ store: ModelContext) -> GLAIToolOutcome {
        guard let status = ChangeOrderStatus(rawValue: raw) else {
            return MBToolFailure.invalid("A change order's status is pending, approved or declined.")
        }
        guard let order = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) else {
            return MBToolFailure.notFound(.changeOrder)
        }
        let recordID = MBIDs.id(order, env)
        let ref = MBWrite.ref(.changeOrder, recordID)
        if order.isBilledToLockedInvoice, status != .approved {
            return MBToolFailure.domain(.paidLocked, ref)
        }
        let before = order.status
        let wasApplied = order.appliedToInvoice
        // Taking an added charge back off can leave the invoice fully paid — which locks it.
        if status != .approved, MoneyLockPreview.wouldLock(removing: order), let invoice = order.invoice {
            let number = invoice.number
            return .needsConfirmation(GLAIConfirmation(
                recordIDs: [recordID, MBIDs.id(invoice, env)],
                line: MBWriteStrings.confirmWouldLock(number),
                actionLabel: MBWriteStrings.confirmContinue,
                isDestructive: false,
                declinedMessage: "The user chose not to change the status of \(order.number).",
                perform: { [env] in
                    Self.applyChangeOrderStatus(recordID, status, before: before, wasApplied: wasApplied,
                                                env: env, keepUndo: false)
                }))
        }
        return Self.applyChangeOrderStatus(recordID, status, before: before, wasApplied: wasApplied,
                                           env: env, keepUndo: true)
    }

    static func applyChangeOrderStatus(_ recordID: String, _ status: ChangeOrderStatus,
                                       before: ChangeOrderStatus, wasApplied: Bool,
                                       env: MBToolEnvironment, keepUndo: Bool) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.changeOrder, recordID)
        guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
            return MBToolFailure.notFound(.changeOrder)
        }
        let matched: Bool
        do {
            matched = try ChangeOrderService.setStatus(order, status, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(order))
        let undo = keepUndo ? undoStatus(recordID, number: order.number, before: before,
                                         wasApplied: wasApplied, env: env) : nil
        let dto = MBRecordDTO(env: env, context: store)
        var output: [String: GLAIJSON] = ["ok": true, "change_order": dto.row(order)]
        if !matched {
            output["items_left_on_invoice"] = true
            output["message"] = "Its billed items couldn't be matched on the invoice, so they are still there. Tell the user to remove them on the invoice."
        }
        return .result(.object(output),
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.status,
                                               title: MBWriteStrings.changeOrderStatusChanged,
                                               detail: "\(order.number) · \(status.label)", record: ref)],
                       undo: undo)
    }

    private static func undoStatus(_ recordID: String, number: String, before: ChangeOrderStatus,
                                   wasApplied: Bool, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.changeOrder, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(changeOrder: number), ledger: env.ledger,
                            fingerprint: { MBWrite.changeOrder(recordID, env).map(MBFingerprint.of) },
                            dropReason: {
                                guard let order = MBWrite.changeOrder(recordID, env),
                                      order.invoice?.isMoneyLocked == true else { return nil }
                                return MBWriteStrings.undoDroppedPaid
                            }) {
            guard let store = env.context(), let order = MBWrite.changeOrder(recordID, env) else {
                return MBUndo.recordGone
            }
            // Putting an order back on Approved does NOT re-add its items (approving never does):
            // the items go back the way "Add items to invoice" puts them there.
            let needsReapply = wasApplied && !order.appliedToInvoice && before == .approved
            if needsReapply, MoneyLockPreview.wouldLock(applying: order) {
                return .failed(MBWriteStrings.undoWouldPayInvoice)
            }
            do {
                _ = try ChangeOrderService.setStatus(order, before, in: store, subscription: env.subscription())
                if needsReapply {
                    try ChangeOrderService.applyToInvoice(order, in: store, subscription: env.subscription())
                }
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(order))
            return MBUndo.reverted(.updated, MBWriteSymbol.changeOrder, MBWriteStrings.changeOrderRestored,
                                   detail: order.number, record: ref)
        }
    }

    // MARK: Job

    private func job(_ id: String, _ raw: String, _ store: ModelContext) -> GLAIToolOutcome {
        guard let status = JobStatus(rawValue: raw) else {
            return MBToolFailure.invalid("A job's status is scheduled, inProgress or completed.")
        }
        guard let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
            return MBToolFailure.notFound(.job)
        }
        let recordID = MBIDs.id(job, env)
        let ref = MBWrite.ref(.job, recordID)
        let before = job.status
        let completedAt = job.completedAt
        do {
            try JobService.setStatus(status, for: job, in: store, now: env.now(),
                                     subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(job))
        let title = job.displayTitle
        let undo = MBUndo.entry(ref, title: MBWriteStrings.undoTitle(job: title), ledger: env.ledger,
                                fingerprint: { MBWrite.job(recordID, env).map(MBFingerprint.of) }) { [env] in
            guard let store = env.context(), let job = MBWrite.job(recordID, env) else { return MBUndo.recordGone }
            do {
                // The original completion date goes back too — it starts the warranty clock.
                try JobService.setStatus(before, for: job, in: store, now: completedAt ?? env.now(),
                                         subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.of(job))
            return MBUndo.reverted(.updated, MBWriteSymbol.job, MBWriteStrings.jobRestored,
                                   detail: job.displayTitle, record: ref)
        }
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "job": dto.row(job)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.status,
                                               title: MBWriteStrings.jobStatusChanged,
                                               detail: "\(title) · \(status.label)", record: ref)],
                       undo: undo)
    }
}
