//
//  MBInvoiceTools.swift
//  GLSmallBusiness — AI
//
//  `create_invoice` and `edit_invoice` — through `InvoiceService` and `EstimateService`, the same
//  saves the Invoice form, "Convert to invoice" and "Bill this job" run (law 58).
//
//  The three doors a person has, and so the model has:
//    • standalone for a customer;
//    • from an estimate (its lines, its deposit; an options estimate needs the chosen options, and
//      an estimate already invoiced hands back that invoice instead of a second one);
//    • for a job (progress billing, optionally with the job's photos, documents and expenses).
//
//  Money rules the app already has, kept here: a PAID invoice takes only the amount due now, the
//  Pay button and job files — anything else is refused with "offer a change order"; change-order
//  rows are read-only; and any edit that would make the invoice read Paid asks first, because that
//  closes the door behind the person (`MoneyLockPreview`).
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - Shared draft work

@MainActor
enum MBInvoiceDraftBuilder {

    /// The fields both tools take. Only the sent ones change.
    static func patched(_ draft: InvoiceDraft, _ args: MBArguments, _ value: MBValue) throws -> InvoiceDraft {
        var draft = draft
        if let title = args.json["job_title"]?.stringValue { draft.jobTitle = title }
        if let terms = args.raw("payment_terms", PaymentTerms.self) { draft.paymentTerms = terms }
        else if args.has("payment_terms") {
            throw MBDocumentPatcher<InvoiceGroupDraft>.PatchError
                .invalid("payment_terms must be dueOnReceipt, net15, net30 or custom.")
        }
        if let due = value.parseDay(args.string("due_date")) { draft.dueDate = due }
        else if args.has("due_date") {
            throw MBDocumentPatcher<InvoiceGroupDraft>.PatchError.invalid("due_date must be a date, YYYY-MM-DD.")
        }
        if let amount = args.money("amount_due_now") { draft.amountDueNow = amount }
        if let detail = args.json["amount_due_detail"]?.stringValue { draft.amountDueDetail = detail }
        if let include = args.bool("include_pay_button") { draft.includePayLink = include }
        if let rate = args.number("tax_rate_percent") { draft.taxRatePercent = rate }
        if let type = args.raw("discount_type", AdjustmentType.self) { draft.discountType = type }
        if let value = args.number("discount_value") { draft.discountValue = value }
        if let notes = args.json["customer_notes"]?.stringValue { draft.customerNotes = notes }
        if let terms = args.json["terms"]?.stringValue { draft.terms = terms }
        if let includeZelle = args.bool("include_zelle") { draft.includeZelle = includeZelle }
        if let autoReminders = args.bool("auto_reminders_enabled") { draft.autoRemindersEnabled = autoReminders }
        draft.serviceAddress = MBWriteValue.address(draft.serviceAddress, patch: args.object("service_address"))
        return draft
    }

    /// `include_from_job`: which of the job's files come along.
    static func attachments(_ args: MBArguments) -> JobAttachmentSelection {
        let wanted = Set(args.strings("include_from_job"))
        return JobAttachmentSelection(photos: wanted.contains("photos"),
                                      documents: wanted.contains("documents"),
                                      expenses: wanted.contains("expenses"))
    }

    /// A patcher that knows this invoice's ids, and which rows a change order owns.
    static func patcher(for invoice: Invoice, env: MBToolEnvironment,
                        store: ModelContext) -> MBDocumentPatcher<InvoiceGroupDraft> {
        var groupsByID: [String: PersistentIdentifier] = [:]
        var linesByID: [String: PersistentIdentifier] = [:]
        var lockedGroups: Set<PersistentIdentifier> = []
        var lockedLines: Set<PersistentIdentifier> = []
        for group in invoice.sortedGroups {
            groupsByID[MBIDs.id(group, env)] = group.persistentModelID
            if group.changeOrder != nil { lockedGroups.insert(group.persistentModelID) }
            for line in group.sortedLineItems {
                linesByID[MBIDs.id(line, env)] = line.persistentModelID
                if line.fromChangeOrder { lockedLines.insert(line.persistentModelID) }
            }
        }
        return MBDocumentPatcher(env: env, store: store, groupsByID: groupsByID, linesByID: linesByID,
                                 lockedGroups: lockedGroups, lockedLines: lockedLines)
    }

    static func failure(_ error: any Error, _ record: GLAIRecordRef?) -> GLAIToolOutcome {
        if let patch = error as? MBDocumentPatcher<InvoiceGroupDraft>.PatchError {
            switch patch {
            case .invalid(let message): return MBToolFailure.invalid(message)
            case .refusal(let domain): return MBToolFailure.domain(domain, record)
            }
        }
        return MBToolFailure.unexpected(error, record)
    }

    static func detail(_ invoice: Invoice) -> String {
        "\(invoice.number) · \(MBWriteValue.amount(invoice.total))"
    }

    // MARK: Undo

    /// An invoice Undo entry is dropped when money landed on it after the write, or when it became
    /// money-locked (contract §4) — Undo never reaches past a payment.
    static func dropReason(_ ref: GLAIRecordRef, env: MBToolEnvironment,
                           paymentsAtWrite: Int) -> @MainActor @Sendable () -> LocalizedStringResource? {
        {
            guard let invoice = MBWrite.invoice(ref.id, env) else { return nil }
            if invoice.sortedPayments.count > paymentsAtWrite { return MBWriteStrings.undoDroppedPaymentRecorded }
            if invoice.isMoneyLocked { return MBWriteStrings.undoDroppedPaid }
            return nil
        }
    }

    static func undoCreate(_ ref: GLAIRecordRef, number: String, env: MBToolEnvironment,
                           paymentsAtWrite: Int) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(invoice: number), ledger: env.ledger,
                     fingerprint: { MBWrite.invoice(ref.id, env).map(MBFingerprint.of) },
                     dropReason: dropReason(ref, env: env, paymentsAtWrite: paymentsAtWrite)) {
            guard let store = env.context(), let invoice = MBWrite.invoice(ref.id, env) else {
                return MBUndo.recordGone
            }
            guard invoice.liveRows(invoice.changeOrders).isEmpty,
                  invoice.liveRows(invoice.scheduledJobs).isEmpty else {
                return .failed(MBWriteStrings.undoKeptHasRecords)
            }
            do {
                try DeletionService.delete([.invoice(invoice)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.invoice, MBWriteStrings.deleted(.invoice),
                                   detail: number, record: nil)
        }
    }

    static func undoEdit(_ ref: GLAIRecordRef, number: String, token: UUID, env: MBToolEnvironment,
                         paymentsAtWrite: Int, addedAttachments: [String]) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(invoice: number), ledger: env.ledger,
                     fingerprint: { MBWrite.invoice(ref.id, env).map(MBFingerprint.of) },
                     dropReason: dropReason(ref, env: env, paymentsAtWrite: paymentsAtWrite)) {
            guard let store = env.context(), let invoice = MBWrite.invoice(ref.id, env),
                  case .invoice(let before)? = env.ledger.snapshot(token) else { return MBUndo.recordGone }
            do {
                // The files this edit brought in go back off first, then the fields and rows.
                let copies = addedAttachments.compactMap {
                    MBRecordLookup.record(.attachment, id: $0, as: JobAttachment.self, in: store)
                }
                if !copies.isEmpty {
                    try DeletionService.delete(copies.map { DeletionService.Target.attachment($0) },
                                               in: store, subscription: env.subscription())
                }
                // `.screen` on the way back: every value here is the invoice's own stored one.
                try InvoiceService.update(invoice, with: before, origin: .screen, in: store,
                                          subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(ref.id, MBFingerprint.of(invoice))
            return MBUndo.reverted(.updated, MBWriteSymbol.invoice, MBWriteStrings.invoiceRestored,
                                   detail: invoice.number, record: ref)
        }
    }
}

// MARK: - create_invoice

@MainActor
struct MBCreateInvoiceTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        if args.string("from_estimate_id") != nil { return fromEstimate(args, store) }
        if args.string("job_id") != nil { return forJob(args, store) }
        if args.string("customer_id") != nil { return standalone(args, store) }
        return MBToolFailure.invalid(
            "Send customer_id for a standalone invoice, from_estimate_id to convert an estimate, or job_id to bill a job.")
    }

    // MARK: From an estimate

    private func fromEstimate(_ args: MBArguments, _ store: ModelContext) -> GLAIToolOutcome {
        guard let id = args.string("from_estimate_id"),
              let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
            return MBToolFailure.notFound(.estimate)
        }
        var chosen: Set<PersistentIdentifier>?
        if estimate.isOptionsMode {
            let wanted = Set(args.strings("option_group_ids"))
            let picked = estimate.sortedGroups.filter { wanted.contains(MBIDs.id($0, env)) }
            guard picked.count == wanted.count else {
                return MBToolFailure.invalid("One of the option_group_ids isn't a group on this estimate. Read it with get.")
            }
            chosen = Set(picked.map(\.persistentModelID))
        }
        // Every argument is parsed BEFORE the conversion: a bad `payment_terms` must refuse while
        // no invoice exists, never after one has been minted and the estimate marked converted.
        let value = MBValue(calendar: env.calendar)
        do {
            _ = try MBInvoiceDraftBuilder.patched(InvoiceDraft(), args, value)
            if !args.objects("groups").isEmpty {
                _ = try MBDocumentPatcher<InvoiceGroupDraft>(env: env, store: store)
                    .newGroups(args.objects("groups"))
            }
        } catch {
            return MBInvoiceDraftBuilder.failure(error, MBWrite.ref(.estimate, id))
        }
        let conversion: EstimateService.Conversion
        do {
            conversion = try EstimateService.convertToInvoice(
                estimate, chosenGroupIDs: chosen, force: args.bool("create_another") ?? false,
                in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, MBWrite.ref(.estimate, id))
        }
        let dto = MBRecordDTO(env: env, context: store)
        switch conversion {
        case .alreadyConverted(let invoice):
            // Nothing was written: the person decides whether they want a second invoice.
            return .result([
                "ok": true,
                "already_invoiced": true,
                "invoice": dto.row(invoice),
                "message": "This estimate was already invoiced. Ask the user whether they want another invoice; if so, call again with create_another true.",
            ])
        case .created(let invoice):
            return finish(invoice, args: args, store: store, extraGroups: true)
        }
    }

    // MARK: For a job

    private func forJob(_ args: MBArguments, _ store: ModelContext) -> GLAIToolOutcome {
        guard let id = args.string("job_id"),
              let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
            return MBToolFailure.notFound(.job)
        }
        guard let customer = job.customer, !customer.isDeleted else {
            return MBToolFailure.domain(.customerRequired, MBWrite.ref(.job, id))
        }
        let value = MBValue(calendar: env.calendar)
        var draft = InvoiceService.jobBillingDraft(for: job)
        do {
            draft = try MBInvoiceDraftBuilder.patched(draft, args, value)
            if !args.objects("groups").isEmpty {
                let patcher = MBDocumentPatcher<InvoiceGroupDraft>(env: env, store: store)
                draft.groups += try patcher.newGroups(args.objects("groups"))
            }
        } catch {
            return MBInvoiceDraftBuilder.failure(error, MBWrite.ref(.job, id))
        }
        let invoice: Invoice
        do {
            invoice = try InvoiceService.create(draft, for: customer, job: job,
                                                attachments: MBInvoiceDraftBuilder.attachments(args),
                                                origin: .tool, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, MBWrite.ref(.job, id))
        }
        return created(invoice, store: store)
    }

    // MARK: Standalone

    private func standalone(_ args: MBArguments, _ store: ModelContext) -> GLAIToolOutcome {
        guard let id = args.string("customer_id"),
              let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
            return MBToolFailure.notFound(.customer)
        }
        let value = MBValue(calendar: env.calendar)
        var draft = InvoiceDraft()
        do {
            draft = try MBInvoiceDraftBuilder.patched(draft, args, value)
            let patcher = MBDocumentPatcher<InvoiceGroupDraft>(env: env, store: store)
            draft.groups = try patcher.newGroups(args.objects("groups"))
        } catch {
            return MBInvoiceDraftBuilder.failure(error, nil)
        }
        let invoice: Invoice
        do {
            invoice = try InvoiceService.create(draft, for: customer, origin: .tool, in: store,
                                                subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }
        return created(invoice, store: store)
    }

    // MARK: Shared endings

    /// An invoice made from an estimate, then given whatever else the model sent.
    private func finish(_ invoice: Invoice, args: MBArguments, store: ModelContext,
                        extraGroups: Bool) -> GLAIToolOutcome {
        let value = MBValue(calendar: env.calendar)
        var draft = InvoiceDraft(invoice)
        var changed = false
        do {
            let patched = try MBInvoiceDraftBuilder.patched(draft, args, value)
            changed = patched != draft
            draft = patched
            if extraGroups, !args.objects("groups").isEmpty {
                let patcher = MBDocumentPatcher<InvoiceGroupDraft>(env: env, store: store)
                draft.groups += try patcher.newGroups(args.objects("groups"))
                changed = true
            }
        } catch {
            // Unreachable: `fromEstimate` parses the same arguments before it converts. Kept as
            // a partial result all the same — the invoice exists, so it is never a bare failure.
            return created(invoice, store: store, notApplied: "The rest of what you asked for couldn't be read.")
        }
        if changed {
            do {
                try InvoiceService.update(invoice, with: draft, origin: .tool, in: store,
                                          subscription: env.subscription())
            } catch {
                // The invoice is real. Report the fields that didn't take ALONGSIDE it, never
                // instead of it — a bare failure would tell the person nothing was created.
                let reason = (error as? DomainError).map { GLAIStrings.english($0.personReason) }
                return created(invoice, store: store,
                               notApplied: reason ?? "The other details didn't save.")
            }
        }
        return created(invoice, store: store)
    }

    private func created(_ invoice: Invoice, store: ModelContext,
                         notApplied: String? = nil) -> GLAIToolOutcome {
        let id = MBIDs.id(invoice, env)
        let ref = MBWrite.ref(.invoice, id)
        env.ledger.note(id, MBFingerprint.of(invoice))
        let dto = MBRecordDTO(env: env, context: store)
        var output: [String: GLAIJSON] = ["ok": true, "id": .string(id), "invoice": dto.row(invoice)]
        if let notApplied {
            output["some_fields_not_applied"] = true
            output["message"] = .string("The invoice was created. \(notApplied) Tell the user which part didn't take.")
        }
        return .result(.object(output),
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.invoice,
                                               title: MBWriteStrings.invoiceCreated,
                                               detail: MBInvoiceDraftBuilder.detail(invoice), record: ref)],
                       undo: MBInvoiceDraftBuilder.undoCreate(ref, number: invoice.number, env: env,
                                                              paymentsAtWrite: invoice.sortedPayments.count))
    }
}

// MARK: - edit_invoice

@MainActor
struct MBEditInvoiceTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    /// What a PAID invoice still takes (the fields the lock exempts: InvoiceService).
    static let allowedWhenPaid: Set<String> = [
        "id", "amount_due_now", "amount_due_detail", "include_pay_button", "include_from_job",
    ]

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let id = args.string("id") else {
            return MBToolFailure.invalid("id is required. Use find kind invoice to get it.")
        }
        guard let invoice = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) else {
            return MBToolFailure.notFound(.invoice)
        }
        let recordID = MBIDs.id(invoice, env)
        let ref = MBWrite.ref(.invoice, recordID)

        if invoice.isMoneyLocked { return paidInvoiceEdit(recordID, ref: ref, args: args, invoice: invoice) }

        let value = MBValue(calendar: env.calendar)
        let before = InvoiceDraft(invoice)
        var draft: InvoiceDraft
        do {
            draft = try MBInvoiceDraftBuilder.patched(before, args, value)
            draft.groups = try MBInvoiceDraftBuilder.patcher(for: invoice, env: env, store: store)
                .apply(args, to: draft.groups)
        } catch {
            return MBInvoiceDraftBuilder.failure(error, ref)
        }

        let beforeToken = env.ledger.stash(.invoice(before))
        let draftToken = env.ledger.stash(.invoice(draft))
        // An edit that makes the invoice read Paid closes the door behind the person: ask first.
        guard !MoneyLockPreview.wouldLock(invoice, applying: draft) else {
            let number = invoice.number
            return .needsConfirmation(GLAIConfirmation(
                recordIDs: [recordID],
                line: MBWriteStrings.confirmWouldLock(number),
                actionLabel: MBWriteStrings.confirmContinue,
                isDestructive: false,
                declinedMessage: "The user chose not to make this change to \(number).",
                perform: { [env] in
                    MBEditInvoiceTool.apply(recordID, beforeToken: beforeToken, draftToken: draftToken,
                                            args: args, env: env, keepUndo: false)
                }))
        }
        return Self.apply(recordID, beforeToken: beforeToken, draftToken: draftToken, args: args,
                          env: env, keepUndo: true)
    }

    // MARK: The write

    /// The edit itself: fields and rows through `InvoiceService.update`, then any job files the
    /// model asked for. A confirmed edit keeps no Undo (contract §5).
    static func apply(_ recordID: String, beforeToken: UUID, draftToken: UUID, args: MBArguments,
                      env: MBToolEnvironment, keepUndo: Bool) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.invoice, recordID)
        guard let store = env.context(), let invoice = MBWrite.invoice(recordID, env) else {
            return MBToolFailure.notFound(.invoice)
        }
        guard case .invoice(let draft)? = env.ledger.snapshot(draftToken) else {
            return MBToolFailure.unavailable
        }
        let paymentsAtWrite = invoice.sortedPayments.count
        do {
            try InvoiceService.update(invoice, with: draft, origin: .tool, in: store,
                                      subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        var activity: [GLAIActivity] = [
            GLAIActivity(kind: .updated, symbol: MBWriteSymbol.invoice, title: MBWriteStrings.invoiceUpdated,
                         detail: MBInvoiceDraftBuilder.detail(invoice), record: ref),
        ]
        var added: [String] = []
        var filesProblem: String?
        let selection = MBInvoiceDraftBuilder.attachments(args)
        if selection != .none {
            switch importFiles(selection, into: invoice, env: env, store: store) {
            case .value(let ids):
                added = ids
                if !ids.isEmpty {
                    activity.append(GLAIActivity(kind: .updated, symbol: MBWriteSymbol.document,
                                                 title: MBWriteStrings.jobFilesAdded,
                                                 detail: invoice.number, record: ref))
                }
            case .problem(let message):
                filesProblem = message
            }
        }
        env.ledger.note(recordID, MBFingerprint.of(invoice))
        let dto = MBRecordDTO(env: env, context: store)
        let undo = keepUndo
            ? MBInvoiceDraftBuilder.undoEdit(ref, number: invoice.number, token: beforeToken, env: env,
                                             paymentsAtWrite: paymentsAtWrite, addedAttachments: added)
            : nil
        var output: [String: GLAIJSON] = ["ok": true, "id": .string(recordID), "invoice": dto.row(invoice),
                                          "locked_paid": .bool(invoice.isMoneyLocked)]
        if let filesProblem {
            output["files_not_added"] = true
            output["message"] = .string(filesProblem)
        }
        return .result(.object(output), activity: activity, undo: undo)
    }

    /// Either the ids of the copies this import made (so Undo can take exactly those back off), or
    /// why no file came across. Never a `GLAIToolOutcome`: by the time this runs the edit itself is
    /// already saved, so a file problem is a PARTIAL result — it can never be the whole answer.
    enum ImportResult {
        case value([String])
        case problem(String)
    }

    /// The job's photos, documents or expense scans, copied onto the invoice.
    private static func importFiles(_ selection: JobAttachmentSelection, into invoice: Invoice,
                                    env: MBToolEnvironment,
                                    store: ModelContext) -> ImportResult {
        guard let job = invoice.job, !job.isDeleted else {
            return .problem("The change was saved, but this invoice doesn't bill a job, so there were no job files to bring in. Tell the user that part didn't apply.")
        }
        let known = Set(invoice.liveRows(invoice.attachments).map(\.persistentModelID))
        do {
            _ = try InvoiceService.importJobAttachments(selection, from: job, into: invoice, in: store,
                                                        subscription: env.subscription())
        } catch {
            let reason = (error as? DomainError).map { GLAIStrings.english($0.personReason) }
                ?? "They didn't save."
            return .problem("The change was saved, but the job's files didn't come across. \(reason) Tell the user that part didn't apply.")
        }
        let copies = invoice.liveRows(invoice.attachments).filter { !known.contains($0.persistentModelID) }
        return .value(copies.map { MBIDs.id($0, env) })
    }

    // MARK: A paid invoice

    /// A paid invoice takes only what the lock exempts, and says so plainly for anything else.
    private func paidInvoiceEdit(_ recordID: String, ref: GLAIRecordRef, args: MBArguments,
                                 invoice: Invoice) -> GLAIToolOutcome {
        let sent = Set(args.json.objectValue?.keys.map { $0 } ?? [])
        guard sent.subtracting(Self.allowedWhenPaid).isEmpty else {
            return MBToolFailure.domain(.paidLocked, ref)
        }
        guard sent.count > 1 else {
            return MBToolFailure.invalid("Send what to change: amount_due_now, include_pay_button or include_from_job.")
        }
        let number = invoice.number
        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [recordID],
            line: MBWriteStrings.confirmPaidInvoiceEdit(number),
            actionLabel: MBWriteStrings.confirmContinue,
            isDestructive: false,
            declinedMessage: "The user chose not to change \(number).",
            perform: { [env] in MBEditInvoiceTool.applyToPaid(recordID, args: args, env: env) }))
    }

    /// The lock-exempt writes, each through its own service call (the same ones the invoice screen
    /// makes): the amount due now, the Pay button, and the job's files.
    static func applyToPaid(_ recordID: String, args: MBArguments, env: MBToolEnvironment) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.invoice, recordID)
        guard let store = env.context(), let invoice = MBWrite.invoice(recordID, env) else {
            return MBToolFailure.notFound(.invoice)
        }
        var activity: [GLAIActivity] = []
        do {
            if args.has("amount_due_now") || args.has("amount_due_detail") {
                let amount = args.money("amount_due_now") ?? invoice.amountDueNow
                let detail = args.json["amount_due_detail"]?.stringValue ?? invoice.amountDueDetail
                try InvoiceService.setAmountDue(invoice, amount: amount, detail: detail, in: store,
                                                subscription: env.subscription())
            }
            if let include = args.bool("include_pay_button") {
                try InvoiceService.setIncludePayLink(invoice, include, in: store, subscription: env.subscription())
            }
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        activity.append(GLAIActivity(kind: .updated, symbol: MBWriteSymbol.invoice,
                                     title: MBWriteStrings.invoiceUpdated,
                                     detail: MBInvoiceDraftBuilder.detail(invoice), record: ref))
        var filesProblem: String?
        let selection = MBInvoiceDraftBuilder.attachments(args)
        if selection != .none {
            switch importFiles(selection, into: invoice, env: env, store: store) {
            case .value(let ids) where !ids.isEmpty:
                activity.append(GLAIActivity(kind: .updated, symbol: MBWriteSymbol.document,
                                             title: MBWriteStrings.jobFilesAdded,
                                             detail: invoice.number, record: ref))
            case .value:
                break
            case .problem(let message):
                filesProblem = message
            }
        }
        env.ledger.note(recordID, MBFingerprint.of(invoice))
        let dto = MBRecordDTO(env: env, context: store)
        // Confirmed: no Undo (contract §5).
        var output: [String: GLAIJSON] = ["ok": true, "invoice": dto.row(invoice), "locked_paid": true]
        if let filesProblem {
            output["files_not_added"] = true
            output["message"] = .string(filesProblem)
        }
        return .result(.object(output), activity: activity)
    }
}
