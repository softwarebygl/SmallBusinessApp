//
//  MBEstimateTools.swift
//  GLSmallBusiness — AI
//
//  `create_estimate` and `edit_estimate` — through `EstimateService`, the same save the Estimate
//  form's Save runs (law 58). The tools build the form's own `EstimateDraft`, so an edit updates
//  the rows in place and can never mint a second estimate (Pillar 2). Status changes are
//  `set_status`; converting to an invoice is `create_invoice`.
//

import Foundation
import SwiftData
import GoldLifeAI

// MARK: - Shared draft work

@MainActor
enum MBEstimateDraftBuilder {

    /// The document fields both tools take. Only the sent ones change.
    static func patched(_ draft: EstimateDraft, _ args: MBArguments, _ value: MBValue) -> EstimateDraft {
        var draft = draft
        if let title = args.json["job_title"]?.stringValue { draft.jobTitle = title }
        if let combine = args.bool("combine_totals") { draft.combineTotals = combine }
        if let day = value.parseDay(args.string("valid_until")) { draft.validUntil = day }
        if let rate = args.number("tax_rate_percent") { draft.taxRatePercent = rate }
        if let type = args.raw("discount_type", AdjustmentType.self) { draft.discountType = type }
        if let value = args.number("discount_value") { draft.discountValue = value }
        if let type = args.raw("deposit_type", AdjustmentType.self) { draft.depositType = type }
        if let value = args.number("deposit_value") { draft.depositValue = value }
        if let notes = args.json["customer_notes"]?.stringValue { draft.customerNotes = notes }
        if let terms = args.json["terms"]?.stringValue { draft.terms = terms }
        draft.serviceAddress = MBWriteValue.address(draft.serviceAddress, patch: args.object("service_address"))
        return draft
    }

    /// A deposit in dollars is an AMOUNT, so it is sent in whole cents like every other amount
    /// (law 60); a deposit percentage keeps what was sent. Checked on the patched draft, so a
    /// deposit that ENDS UP in dollars is held to it whichever argument put it there (the value,
    /// or a switch to `fixed` over a stored percentage). Nil when the deposit may stand.
    static func depositRefusal(_ draft: EstimateDraft, _ args: MBArguments) -> GLAIToolOutcome? {
        guard draft.depositType == .fixed, args.has("deposit_value") || args.has("deposit_type"),
              !DomainMoney.isWholeCents(draft.depositValue) else { return nil }
        return MBToolFailure.invalid("A fixed deposit_value is dollars, so it must be whole cents: "
                                     + "at most two decimals, like 250.50. Send it again in whole cents.")
    }

    /// A patcher that knows this estimate's group and line ids (`syncID`s, minted on first read).
    static func patcher(for estimate: Estimate, env: MBToolEnvironment,
                        store: ModelContext) -> MBDocumentPatcher<EstimateGroupDraft> {
        var groupsByID: [String: PersistentIdentifier] = [:]
        var linesByID: [String: PersistentIdentifier] = [:]
        for group in estimate.sortedGroups {
            groupsByID[MBIDs.id(group, env)] = group.persistentModelID
            for line in group.sortedLineItems {
                linesByID[MBIDs.id(line, env)] = line.persistentModelID
            }
        }
        return MBDocumentPatcher(env: env, store: store, groupsByID: groupsByID, linesByID: linesByID)
    }

    /// The model's slip vs. a rule a person meets too.
    static func failure(_ error: MBDocumentPatcher<EstimateGroupDraft>.PatchError,
                        _ record: GLAIRecordRef?) -> GLAIToolOutcome {
        switch error {
        case .invalid(let message): return MBToolFailure.invalid(message)
        case .refusal(let domain): return MBToolFailure.domain(domain, record)
        }
    }

    // MARK: Undo

    static func undoCreate(_ ref: GLAIRecordRef, number: String, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(estimate: number), ledger: env.ledger,
                     fingerprint: { MBWrite.estimate(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let estimate = MBWrite.estimate(ref.id, env) else {
                return MBUndo.recordGone
            }
            // An estimate a job or an invoice now hangs off is kept — deleting it would change
            // more than this request did.
            guard estimate.liveRows(estimate.scheduledJobs).isEmpty,
                  EstimateService.existingInvoice(convertedFrom: estimate, in: store) == nil else {
                return .failed(MBWriteStrings.undoKeptHasRecords)
            }
            do {
                try DeletionService.delete([.estimate(estimate)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.estimate, MBWriteStrings.deleted(.estimate),
                                   detail: number, record: nil)
        }
    }

    static func undoEdit(_ ref: GLAIRecordRef, number: String, token: UUID, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(estimate: number), ledger: env.ledger,
                     fingerprint: { MBWrite.estimate(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let estimate = MBWrite.estimate(ref.id, env),
                  case .estimate(let before)? = env.ledger.snapshot(token) else { return MBUndo.recordGone }
            do {
                // `.screen` on the way back: every value here is the estimate's own stored one.
                try EstimateService.update(estimate, with: before, origin: .screen, in: store,
                                           subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(ref.id, MBFingerprint.of(estimate))
            return MBUndo.reverted(.updated, MBWriteSymbol.estimate, MBWriteStrings.estimateRestored,
                                   detail: estimate.number, record: ref)
        }
    }
}

// MARK: - create_estimate

@MainActor
struct MBCreateEstimateTool: GLAITool {
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
        guard let customerID = args.string("customer_id") else {
            return MBToolFailure.invalid("customer_id is required. Use find kind customer to get it.")
        }
        guard let customer = MBRecordLookup.record(.customer, id: customerID, as: Customer.self, in: store) else {
            return MBToolFailure.notFound(.customer)
        }

        var draft = EstimateDraft()
        // The form's default: good for 30 days from today.
        draft.validUntil = env.now().addingTimeInterval(30 * 24 * 60 * 60)
        draft = MBEstimateDraftBuilder.patched(draft, args, value)
        if let refusal = MBEstimateDraftBuilder.depositRefusal(draft, args) { return refusal }
        let patcher = MBDocumentPatcher<EstimateGroupDraft>(env: env, store: store)
        do {
            draft.groups = try patcher.newGroups(args.objects("groups"))
        } catch let error as MBDocumentPatcher<EstimateGroupDraft>.PatchError {
            return MBEstimateDraftBuilder.failure(error, nil)
        } catch {
            return MBToolFailure.unexpected(error)
        }

        let estimate: Estimate
        do {
            estimate = try EstimateService.create(draft, for: customer, origin: .tool, in: store,
                                                  subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }
        let id = MBIDs.id(estimate, env)
        let ref = MBWrite.ref(.estimate, id)
        env.ledger.note(id, MBFingerprint.of(estimate))
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "id": .string(id), "estimate": dto.row(estimate)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.estimate,
                                               title: MBWriteStrings.estimateCreated,
                                               detail: detail(estimate), record: ref)],
                       undo: MBEstimateDraftBuilder.undoCreate(ref, number: estimate.number, env: env))
    }

    private func detail(_ estimate: Estimate) -> String {
        estimate.isOptionsMode
            ? estimate.number
            : "\(estimate.number) · \(MBWriteValue.amount(estimate.total))"
    }
}

// MARK: - edit_estimate

@MainActor
struct MBEditEstimateTool: GLAITool {
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
        guard let id = args.string("id") else {
            return MBToolFailure.invalid("id is required. Use find kind estimate to get it.")
        }
        guard let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
            return MBToolFailure.notFound(.estimate)
        }
        let recordID = MBIDs.id(estimate, env)
        let ref = MBWrite.ref(.estimate, recordID)

        let before = EstimateDraft(estimate)
        var draft = MBEstimateDraftBuilder.patched(before, args, value)
        if let refusal = MBEstimateDraftBuilder.depositRefusal(draft, args) { return refusal }
        do {
            draft.groups = try MBEstimateDraftBuilder.patcher(for: estimate, env: env, store: store)
                .apply(args, to: draft.groups)
        } catch let error as MBDocumentPatcher<EstimateGroupDraft>.PatchError {
            return MBEstimateDraftBuilder.failure(error, ref)
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }

        do {
            try EstimateService.update(estimate, with: draft, origin: .tool, in: store,
                                       subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(estimate))
        let token = env.ledger.stash(.estimate(before))
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "id": .string(recordID), "estimate": dto.row(estimate)],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.estimate,
                                               title: MBWriteStrings.estimateUpdated,
                                               detail: estimate.number, record: ref)],
                       undo: MBEstimateDraftBuilder.undoEdit(ref, number: estimate.number, token: token, env: env))
    }
}
