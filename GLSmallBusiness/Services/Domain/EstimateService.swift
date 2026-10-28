//
//  EstimateService.swift
//  GLSmallBusiness
//
//  Every estimate write — the Estimate form, the detail screen's status menu and Convert to
//  Invoice, and (later) the assistant's tools — so there is one save path to get right.
//
//  Rules kept from the form: a job title is required; the keep-filter (DocumentDraftRules) drops
//  blank lines and groups; rows are saved IN PLACE (RowReconciler) with `setIfChanged`, so an
//  untouched field or row queues no sync op; a new estimate's number comes only from
//  `Estimate.nextNumber` (which bumps the business profile's counter); the customer snapshot is
//  taken by `Estimate.init`. Scheduling a job from an estimate is not here (the job services own it).
//

import Foundation
import SwiftData

@MainActor
enum EstimateService {

    // MARK: Create / update

    /// Adds an estimate for `customer`, numbered EST-####.
    @discardableResult
    static func create(_ draft: EstimateDraft, for customer: Customer, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws -> Estimate {
        try DomainGate.requireCanCreate(Estimate.self, cap: FreeTier.estimates,
                                        operation: .saveEstimate, in: context, subscription)
        try DomainGate.requireLive(customer, .saveEstimate)
        try validate(draft, origin)
        let estimate = Estimate(customer: customer)
        let existing = (try? context.fetch(FetchDescriptor<Estimate>())) ?? []
        estimate.number = Estimate.nextNumber(after: existing, profile: businessProfile(in: context))
        context.insert(estimate)
        write(draft, to: estimate, in: context)
        context.saveChanges()
        return estimate
    }

    /// Edits an estimate in place. Estimates are never money-locked.
    static func update(_ estimate: Estimate, with draft: EstimateDraft, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveEstimate, subscription)
        try DomainGate.requireLive(estimate, .saveEstimate)
        try validate(draft, origin)
        write(draft, to: estimate, in: context)
        context.saveChanges()
    }

    // MARK: Single fields

    /// Draft / Sent / Accepted / Declined — the detail screen's status menu.
    static func setStatus(_ estimate: Estimate, _ status: EstimateStatus, in context: ModelContext,
                          subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveEstimate, subscription)
        try DomainGate.requireLive(estimate, .saveEstimate)
        setIfChanged(estimate, \.status, status)
        context.saveChanges()
    }

    /// The "valid until" date (the estimate reads Expired after that whole day).
    static func setValidUntil(_ estimate: Estimate, _ date: Date, in context: ModelContext,
                              subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveEstimate, subscription)
        try DomainGate.requireLive(estimate, .saveEstimate)
        setIfChanged(estimate, \.validUntil, date)
        context.saveChanges()
    }

    // MARK: Convert to invoice

    enum Conversion {
        /// A new invoice was made.
        case created(Invoice)
        /// Nothing was made: this estimate already has an invoice. Converting again is the caller's
        /// explicit choice (`force: true`) — the detail screen asks "Create Another Invoice".
        case alreadyConverted(Invoice)
    }

    /// The invoice this estimate was already turned into, if any (matched on the estimate number,
    /// the only link the two records keep).
    static func existingInvoice(convertedFrom estimate: Estimate, in context: ModelContext) -> Invoice? {
        let number = estimate.number
        guard !number.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.sourceEstimateNumber == number })
        return ((try? context.fetch(descriptor)) ?? []).first { !$0.isDeleted }
    }

    /// Turns the estimate into an invoice (`Invoice.make`): the frozen customer snapshot, service
    /// address, lines, tax and notes carry over; the deposit becomes the invoice's amount due now.
    /// An OPTIONS estimate converts only the chosen groups (`chosenGroupIDs`, required, and no
    /// discount or deposit); a classic estimate converts everything and ignores `chosenGroupIDs`.
    static func convertToInvoice(_ estimate: Estimate, chosenGroupIDs: Set<PersistentIdentifier>? = nil,
                                 force: Bool = false, in context: ModelContext,
                                 subscription: SubscriptionManager? = nil) throws -> Conversion {
        try DomainGate.requireWritable(.convertEstimateToInvoice, subscription)
        try DomainGate.requireLive(estimate, .convertEstimateToInvoice)
        // "Already converted" answers before the free cap: nothing would be created, so a tool
        // asking at the cap gets the existing invoice back, not a paywall refusal.
        if !force, let existing = existingInvoice(convertedFrom: estimate, in: context) {
            return .alreadyConverted(existing)
        }
        try DomainGate.requireCanCreate(Invoice.self, cap: FreeTier.invoices,
                                        operation: .convertEstimateToInvoice, in: context, subscription)
        var chosen: [EstimateGroup]?
        if estimate.isOptionsMode {
            let ids = chosenGroupIDs ?? []
            // A group deleted by a sync while the picker was open simply drops out; nothing left
            // must not mint a $0 invoice.
            let picked = estimate.sortedGroups.filter { ids.contains($0.persistentModelID) }
            guard !picked.isEmpty else {
                throw DomainGate.refusal(.optionsRequired, .convertEstimateToInvoice)
            }
            chosen = picked
        }
        let existing = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        let number = Invoice.nextNumber(after: existing, profile: businessProfile(in: context))
        let invoice = Invoice.make(from: estimate, number: number, chosenGroups: chosen, in: context)
        context.saveChanges()
        return .created(invoice)
    }

    // MARK: Internals

    /// The business profile whose counters number documents (the same "first profile" the forms'
    /// @Query hands `nextNumber`).
    static func businessProfile(in context: ModelContext) -> BusinessProfile? {
        (try? context.fetch(FetchDescriptor<BusinessProfile>()))?.first
    }

    /// Required title, non-negative amounts, and a tax rate of at most 100% for everyone (the form
    /// caps tax at the keyboard, and the totals never clamp it). The other percentage caps
    /// (discounts, deposit ≤ 100) are refused for a tool only: the form never capped a stored or
    /// carried value (an old 150% discount, "$ off 150" switched to "% off"), and the totals clamp it.
    private static func validate(_ draft: EstimateDraft, _ origin: WriteOrigin) throws {
        guard !DocumentDraftRules.trim(draft.jobTitle).isEmpty else {
            throw DomainGate.refusal(.titleRequired, .saveEstimate)
        }
        let lines = draft.groups.flatMap(\.lines)
        try DomainGate.requireNonNegative(draft.taxRatePercent, draft.discountValue, draft.depositValue,
                                          for: .saveEstimate)
        // The totals never clamp a tax rate (150% bills 150%), so no origin may save one over 100.
        try DomainGate.requirePercent(draft.taxRatePercent, for: .saveEstimate)
        for line in lines {
            try DomainGate.requireNonNegative(line.quantity, line.unitPrice, line.discountValue,
                                              for: .saveEstimate)
        }
        guard origin == .tool else { return }
        for line in lines where line.discountType == .percentage {
            try DomainGate.requirePercent(line.discountValue, for: .saveEstimate)
        }
        if draft.discountType == .percentage { try DomainGate.requirePercent(draft.discountValue, for: .saveEstimate) }
        if draft.depositType == .percentage { try DomainGate.requirePercent(draft.depositValue, for: .saveEstimate) }
    }

    /// The form's save body: fields through `setIfChanged`, the service address compared whole
    /// (its setter fans out to five columns), then the rows reconciled in place.
    private static func write(_ draft: EstimateDraft, to estimate: Estimate, in context: ModelContext) {
        setIfChanged(estimate, \.jobTitle, DocumentDraftRules.trim(draft.jobTitle))
        setIfChanged(estimate, \.status, draft.status)
        setIfChanged(estimate, \.validUntil, draft.validUntil)
        setIfChanged(estimate, \.taxRatePercent, draft.taxRatePercent)
        setIfChanged(estimate, \.combineTotals, draft.combineTotals)
        setIfChanged(estimate, \.discountType, draft.discountType)
        setIfChanged(estimate, \.discountValue, draft.discountValue)
        setIfChanged(estimate, \.depositType, draft.depositType)
        setIfChanged(estimate, \.depositValue, draft.depositValue)
        setIfChanged(estimate, \.customerNotes, draft.customerNotes)
        setIfChanged(estimate, \.terms, draft.terms)
        let address = DocumentDraftRules.trimmedAddress(draft.serviceAddress)
        if estimate.serviceAddress != address { estimate.serviceAddress = address }

        RowReconciler.reconcile(
            existing: estimate.liveRows(estimate.groups),
            drafts: DocumentDraftRules.keptGroups(draft.groups),
            modelID: { $0.modelID },
            make: { _ in
                let group = EstimateGroup()
                group.estimate = estimate
                context.insert(group)
                return group
            },
            update: { group, groupDraft, groupIndex in
                setIfChanged(group, \.name, groupDraft.name)
                setIfChanged(group, \.note, groupDraft.note)
                setIfChanged(group, \.sortIndex, groupIndex)
                RowReconciler.reconcile(
                    existing: group.liveRows(group.lineItems),
                    drafts: groupDraft.lines,
                    modelID: { $0.modelID },
                    make: { _ in
                        let item = EstimateLineItem()
                        item.group = group
                        context.insert(item)
                        return item
                    },
                    update: { item, line, lineIndex in
                        setIfChanged(item, \.name, DocumentDraftRules.trim(line.name))
                        setIfChanged(item, \.details, DocumentDraftRules.trim(line.details))
                        setIfChanged(item, \.quantity, line.quantity)
                        setIfChanged(item, \.unit, line.unit)
                        setIfChanged(item, \.unitPrice, line.unitPrice)
                        setIfChanged(item, \.kind, line.kind)
                        setIfChanged(item, \.isTaxable, line.isTaxable)
                        setIfChanged(item, \.sortIndex, lineIndex)
                        setIfChanged(item, \.discountType, line.discountType)
                        setIfChanged(item, \.discountValue, line.discountValue)
                    },
                    delete: { context.deleteSynced($0) })
            },
            delete: { context.deleteSynced($0) })
    }
}
