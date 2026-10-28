//
//  InvoiceService.swift
//  GLSmallBusiness
//
//  Every invoice write — the Invoice form (standalone and job billing), the detail screen's Record
//  Payment, Ask for a Deposit, Pay-button toggle and job-photo import, and (later) the assistant's
//  tools — so there is one save path to get right.
//
//  The paid lock (PaidInvoiceLock.swift) is enforced HERE for every edit the app refuses on a paid
//  invoice: the form's save and a status or terms change. Not for the writes the server exempts and
//  the app has always allowed on a paid invoice: payments (creates), the amount-due request, the
//  Pay-button choice and attachments.
//

import Foundation
import SwiftData

/// Which of a job's files a new job-billing invoice copies (the form's Job Attachments toggles).
nonisolated struct JobAttachmentSelection: Equatable, Sendable {
    var photos = false
    var documents = false
    var expenses = false

    static let none = JobAttachmentSelection()
}

@MainActor
enum InvoiceService {

    // MARK: Create / update

    /// Adds an invoice for `customer`, numbered INV-####. With `job` it BILLS that job (progress
    /// billing: `invoice.job`), and `attachments` copies the chosen job files onto it.
    @discardableResult
    static func create(_ draft: InvoiceDraft, for customer: Customer, job: ScheduledJob? = nil,
                       contract: Contract? = nil,
                       attachments: JobAttachmentSelection = .none, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws -> Invoice {
        try DomainGate.requireCanCreate(Invoice.self, cap: FreeTier.invoices,
                                        operation: .saveInvoice, in: context, subscription)
        try DomainGate.requireLive(customer, .saveInvoice)
        if let job {
            try DomainGate.requireLive(job, .saveInvoice)
            // Billing another customer's job would bill (and copy the files of) the wrong person.
            // The form always passes the job's own customer, so only a tool can meet this.
            if let owner = job.customer, owner.persistentModelID != customer.persistentModelID {
                throw DomainGate.refusal(.jobBelongsToAnotherCustomer, .saveInvoice)
            }
        }
        if let contract {
            try DomainGate.requireLive(contract, .saveInvoice)
        }
        try validate(draft, origin, existing: nil, carriedFrom: job)
        let profile = EstimateService.businessProfile(in: context)
        let invoice = Invoice(customer: customer)
        let existing = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        invoice.number = Invoice.nextNumber(after: existing, profile: profile)
        invoice.job = job   // progress-billing link (nil for a standalone invoice)
        invoice.contract = contract
        if invoice.job == nil, let linkedJob = contract?.scheduledJob {
            invoice.job = linkedJob
        }
        context.insert(invoice)
        if let job { copyAttachments(attachments, from: job, to: invoice, in: context) }
        var seeded = draft
        // The form seeds the Pay button from the Get Paid default before it shows the toggle.
        if seeded.includePayLink == nil { seeded.includePayLink = profile?.payLinkDefaultOn ?? true }
        if seeded.includeZelle == nil { seeded.includeZelle = (profile?.zelleIsConfigured == true) ? (profile?.zelleDefaultOn ?? false) : false }
        write(seeded, to: invoice, in: context)
        context.saveChanges()
        return invoice
    }

    /// Edits an invoice in place. Refused on a paid invoice (`paidLocked`): the server would refuse
    /// every money edit inside it, and the app refuses the whole form rather than guess.
    static func update(_ invoice: Invoice, with draft: InvoiceDraft, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveInvoice, subscription)
        try DomainGate.requireLive(invoice, .saveInvoice)
        try requireUnlocked(invoice, .saveInvoice)
        try validate(draft, origin, existing: invoice)
        write(draft, to: invoice, in: context)
        context.saveChanges()
    }

    /// What a job's FIRST billing invoice starts from: the scope of the document that created the
    /// job (its estimate, else the invoice it was scheduled from), so the agreed work isn't typed
    /// twice. No scope once the job has any billing invoice (drafts included) — carrying it again
    /// would double the job's billed total. Title and service address always come from the job.
    ///
    /// An estimate carries the way Convert to Invoice does (`Invoice.make`): a classic estimate
    /// brings all its groups, its discount, and its deposit as the amount due now. An OPTIONS
    /// estimate brings only the option(s) the customer chose (`chosenGroupIDs`, from the option
    /// picker — none chosen carries no lines) and never the estimate-level discount or deposit:
    /// both are sized against every option together, which the customer was never quoted.
    static func jobBillingDraft(for job: ScheduledJob,
                                chosenGroupIDs: Set<PersistentIdentifier>? = nil) -> InvoiceDraft {
        var draft = InvoiceDraft()
        draft.jobTitle = job.displayTitle
        draft.serviceAddress = job.serviceAddress
        guard job.liveRows(job.billingInvoices).isEmpty else { return draft }
        if let estimate = job.estimate, !estimate.sortedGroups.isEmpty {
            if estimate.isOptionsMode {
                let ids = chosenGroupIDs ?? []
                let chosen = estimate.sortedGroups.filter { ids.contains($0.persistentModelID) }
                if !chosen.isEmpty { draft.groups = chosen.map { InvoiceGroupDraft(from: $0) } }
            } else {
                draft.groups = estimate.sortedGroups.map { InvoiceGroupDraft(from: $0) }
                draft.discountType = estimate.discountType
                draft.discountValue = estimate.discountValue
                if estimate.depositAmount > 0 {
                    draft.amountDueNow = estimate.depositAmount
                    draft.amountDueDetail = mbLoc("Deposit to start")
                }
            }
            draft.taxRatePercent = estimate.taxRatePercent
            draft.terms = estimate.terms
            draft.customerNotes = estimate.customerNotes
        } else if let source = job.invoice, !source.sortedGroups.isEmpty {
            // Strip the change-order link (saving it would flip the to-one inverse and steal
            // ChangeOrder.invoiceGroup from the source invoice's group, corrupting both) and drop
            // the row identities: these are copies. Lines keep `fromChangeOrder`, so a change-order
            // credit stays a credit (signed, not floored to $0) and change-order work stays at full
            // price outside the invoice discount — the carried total equals the source's total.
            // On the new invoice those lines show read-only; the group can be removed as a whole.
            draft.groups = source.sortedGroups.map { group in
                var copy = InvoiceGroupDraft(from: group)
                copy.changeOrder = nil
                copy.modelID = nil
                for index in copy.lines.indices {
                    copy.lines[index].modelID = nil
                }
                return copy
            }
            draft.taxRatePercent = source.taxRatePercent
            draft.discountType = source.discountType
            draft.discountValue = source.discountValue
            draft.terms = source.terms
            draft.customerNotes = source.customerNotes
        }
        return draft
    }

    /// True when a job's first invoice must ask which option the customer chose before it can
    /// carry any work: the job came from an OPTIONS estimate and has no billing invoice yet.
    static func jobBillingNeedsOptionChoice(for job: ScheduledJob) -> Bool {
        guard job.liveRows(job.billingInvoices).isEmpty, let estimate = job.estimate else { return false }
        return estimate.isOptionsMode
    }

    // MARK: Single fields

    /// Draft / Sent. Refused on a paid invoice, as the form (the only door today) is.
    static func setStatus(_ invoice: Invoice, _ status: InvoiceStatus, in context: ModelContext,
                          subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveInvoice, subscription)
        try DomainGate.requireLive(invoice, .saveInvoice)
        try requireUnlocked(invoice, .saveInvoice)
        setIfChanged(invoice, \.status, status)
        context.saveChanges()
    }

    /// Payment terms, and the due date that follows: `.custom` uses `customDueDate` (or keeps the
    /// current date when none is given); every other term dates from the invoice's created date.
    static func setPaymentTerms(_ invoice: Invoice, _ terms: PaymentTerms, customDueDate: Date? = nil,
                                in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveInvoice, subscription)
        try DomainGate.requireLive(invoice, .saveInvoice)
        try requireUnlocked(invoice, .saveInvoice)
        setIfChanged(invoice, \.paymentTerms, terms)
        setIfChanged(invoice, \.dueDate, dueDate(for: terms, picked: customDueDate ?? invoice.dueDate,
                                                   createdAt: invoice.createdAt))
        context.saveChanges()
    }

    /// Ask for a deposit or milestone: `amount` 0 asks for the full balance. Allowed on a paid
    /// invoice (the field is lock-exempt). The amount may exceed the balance; what the customer is
    /// asked for is capped by `Invoice.currentAmountDue`. Stored rounded to the cent (law 60).
    static func setAmountDue(_ invoice: Invoice, amount: Double, detail: String, in context: ModelContext,
                             subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.setAmountDue, subscription)
        try DomainGate.requireLive(invoice, .setAmountDue)
        try DomainGate.requireNonNegative(amount, for: .setAmountDue)
        setIfChanged(invoice, \.amountDueNow, DomainMoney.roundedToCents(amount))
        setIfChanged(invoice, \.amountDueDetail, DocumentDraftRules.trim(detail))
        context.saveChanges()
    }

    /// Include the "Pay this invoice" button when this invoice is sent.
    static func setIncludePayLink(_ invoice: Invoice, _ include: Bool, in context: ModelContext,
                                  subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.togglePayLink, subscription)
        try DomainGate.requireLive(invoice, .togglePayLink)
        setIfChanged(invoice, \.includePayLink, include)
        context.saveChanges()
    }

    /// Include Zelle payment details when this invoice is sent.
    static func setIncludeZelle(_ invoice: Invoice, _ include: Bool, in context: ModelContext,
                                subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.togglePayLink, subscription)
        try DomainGate.requireLive(invoice, .togglePayLink)
        setIfChanged(invoice, \.includeZelle, include)
        context.saveChanges()
    }

    /// Mark or clear past due flag on an invoice.
    static func setMarkedPastDue(_ invoice: Invoice, isPastDue: Bool, in context: ModelContext,
                                 subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveInvoice, subscription)
        try DomainGate.requireLive(invoice, .saveInvoice)
        setIfChanged(invoice, \.isMarkedPastDue, isPastDue)
        context.saveChanges()
    }

    /// Update automated reminders configuration on an invoice.
    static func setAutoReminders(_ invoice: Invoice, enabled: Bool, startTrigger: ReminderStartTrigger? = nil,
                                 frequency: ReminderFrequency? = nil, in context: ModelContext,
                                 subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveInvoice, subscription)
        try DomainGate.requireLive(invoice, .saveInvoice)
        setIfChanged(invoice, \.autoRemindersEnabled, enabled)
        if let startTrigger {
            setIfChanged(invoice, \.reminderStartTriggerRaw, startTrigger.rawValue)
        }
        if let frequency {
            setIfChanged(invoice, \.reminderFrequencyRaw, frequency.rawValue)
        }
        context.saveChanges()
    }

    // MARK: Payments

    /// The Record Payment sheet's over-balance test: the payment as it will show (whole cents, law 60)
    /// against the balance due, with the half-cent tolerance.
    static func paymentExceedsBalance(_ invoice: Invoice, amount: Double) -> Bool {
        DomainMoney.roundedToCents(amount) > invoice.balanceDue + DomainMoney.epsilon
    }

    /// Records a payment. A hand-entered amount must be more than zero and no more than the balance
    /// due; a payment reconciling a Stripe link (`stripeLinkId` set) may exceed it — the link
    /// collected its full amount, and refusing it would leave the books short of the payout. From a
    /// tool that exemption holds only for the invoice's OWN current link that no payment has claimed
    /// yet; any other id is treated as a hand-entered amount. (The screen passes the link its
    /// paid-prompt showed, as it always has.)
    ///
    /// A card-type payment matching the outstanding link's exact amount is stamped with that link,
    /// so the pay-status poll never prompts for it again; and the amount-due request is drawn down.
    ///
    /// The payment is stored rounded to the cent (law 60) — what its row, its receipt and the
    /// invoice's amount paid all show. New amounts arrive in whole cents (the form refuses a third
    /// decimal, the assistant's gate refuses a fraction of a cent), so this rounds only an older one.
    @discardableResult
    static func recordPayment(on invoice: Invoice, amount typed: Double, date: Date = .now,
                              method: PaymentMethod, note: String = "", stripeLinkId: String = "",
                              origin: WriteOrigin = .tool, in context: ModelContext,
                              subscription: SubscriptionManager? = nil) throws -> InvoicePayment {
        try DomainGate.requireWritable(.recordPayment, subscription)
        try DomainGate.requireLive(invoice, .recordPayment)
        // At least a cent as it will show: a sub-half-cent entry would record a $0.00 payment.
        let amount = DomainMoney.roundedToCents(typed)
        guard amount.isFinite, amount > 0 else {
            throw DomainGate.refusal(.amountRequired, .recordPayment)
        }
        let reconcilesLink: Bool = switch origin {
        case .screen: !stripeLinkId.isEmpty
        case .tool:
            !stripeLinkId.isEmpty && stripeLinkId == invoice.stripePaymentLinkId
                && !invoice.liveRows(invoice.payments).contains { $0.stripePaymentLinkId == stripeLinkId }
        }
        if !reconcilesLink, paymentExceedsBalance(invoice, amount: amount) {
            throw DomainGate.refusal(.exceedsBalance, .recordPayment)
        }
        let payment = InvoicePayment(amount: amount, date: date, method: method,
                                     note: DocumentDraftRules.trim(note))
        payment.stripePaymentLinkId = stripeLinkId   // ties a Stripe-prompt payment to its link
        // Manual path: a hand-recorded CARD payment matching the outstanding link's exact amount almost
        // certainly IS that link's payment — stamp it (if no payment claims the link yet) so
        // reconciliation stays exact when a later same-amount milestone mints a fresh link. A payment
        // dated BEFORE the link was minted belongs to an earlier milestone and stays unstamped.
        if stripeLinkId.isEmpty,
           method.couldSettleStripeLink,
           !invoice.stripePaymentLinkId.isEmpty,
           DomainMoney.wholeCents(amount) == invoice.stripePaymentLinkAmountCents,
           invoice.stripePaymentLinkMintedAt.map({ date >= Calendar.current.startOfDay(for: $0) }) ?? true,
           !invoice.liveRows(invoice.payments).contains(where: { $0.stripePaymentLinkId == invoice.stripePaymentLinkId }) {
            payment.stripePaymentLinkId = invoice.stripePaymentLinkId
        }
        payment.invoice = invoice
        context.insert(payment)
        // Draw the "amount due now" request down as it gets paid — including on the payment that
        // settles the invoice (lock-exempt; see `Invoice.drawDownAmountDueRequest`).
        invoice.drawDownAmountDueRequest(by: amount)
        context.saveChanges()
        return payment
    }

    // MARK: Attachments

    /// Copies a job's photos, documents and/or expense-receipt scans onto its invoice. Returns how
    /// many copies were made. Attachments are allowed on a paid invoice.
    @discardableResult
    static func importJobAttachments(_ selection: JobAttachmentSelection, from job: ScheduledJob,
                                     into invoice: Invoice, in context: ModelContext,
                                     subscription: SubscriptionManager? = nil) throws -> Int {
        try DomainGate.requireWritable(.addJobAttachment, subscription)
        try DomainGate.requireLive(invoice, .addJobAttachment)
        try DomainGate.requireLive(job, .addJobAttachment)
        let count = copyAttachments(selection, from: job, to: invoice, in: context)
        context.saveChanges()
        return count
    }

    // MARK: Internals

    /// `.custom` keeps the picked date; any other term dates from the created date.
    static func dueDate(for terms: PaymentTerms, picked: Date, createdAt: Date) -> Date {
        terms == .custom ? picked : (terms.dueDate(from: createdAt) ?? picked)
    }

    private static func requireUnlocked(_ invoice: Invoice, _ operation: MBWriteOperation) throws {
        if invoice.isMoneyLocked { throw DomainGate.refusal(.paidLocked, operation) }
    }

    /// Required title, non-negative amounts, and a tax rate of at most 100% for everyone. For a
    /// SCREEN, an ordinary line's unit price may be negative (a job's first invoice carried a credit
    /// that way before the carry kept `fromChangeOrder`, and those invoices must stay editable) and
    /// discount percentages are not capped (the form never capped a stored value; the totals clamp
    /// them). For a TOOL: every percentage is at most 100, a new line's price is ≥ 0,
    /// and change-order rows are read-only — a line flagged `fromChangeOrder` or a group linked to a
    /// change order must be one this invoice already has, unchanged (credits come only through a
    /// change order, and a link to another invoice's order would steal its group).
    private static func validate(_ draft: InvoiceDraft, _ origin: WriteOrigin, existing invoice: Invoice?,
                                 carriedFrom job: ScheduledJob? = nil) throws {
        guard !DocumentDraftRules.trim(draft.jobTitle).isEmpty else {
            throw DomainGate.refusal(.titleRequired, .saveInvoice)
        }
        try DomainGate.requireNonNegative(draft.taxRatePercent, draft.discountValue, draft.amountDueNow,
                                          for: .saveInvoice)
        // The totals never clamp a tax rate (150% bills 150%), so no origin may save one over 100.
        try DomainGate.requirePercent(draft.taxRatePercent, for: .saveInvoice)
        // Change-order lines are read-only in the form and carry a credit's negative price — they are
        // round-tripped, never validated as new input.
        let lines = draft.groups.flatMap(\.lines)
        for line in lines where !line.fromChangeOrder {
            try DomainGate.requireNonNegative(line.quantity, line.discountValue, for: .saveInvoice)
            if origin == .tool { try DomainGate.requireNonNegative(line.unitPrice, for: .saveInvoice) }
        }
        guard origin == .tool else { return }
        if draft.discountType == .percentage { try DomainGate.requirePercent(draft.discountValue, for: .saveInvoice) }
        for line in lines where !line.fromChangeOrder && line.discountType == .percentage {
            try DomainGate.requirePercent(line.discountValue, for: .saveInvoice)
        }
        try requireChangeOrderRowsUntouched(draft, on: invoice, carriedFrom: job)
    }

    /// The tool half of "change-order rows are read-only" (see `validate`).
    ///
    /// `carriedFrom` is the job a NEW billing invoice is being made for: its first invoice starts
    /// from `jobBillingDraft`, which copies the source invoice's change-order lines as new rows
    /// (they have no id on this invoice yet). Those exact rows are allowed through — anything else
    /// flagged `fromChangeOrder` is not.
    private static func requireChangeOrderRowsUntouched(_ draft: InvoiceDraft, on invoice: Invoice?,
                                                        carriedFrom job: ScheduledJob? = nil) throws {
        let groups = invoice.map { $0.liveRows($0.groups) } ?? []
        let groupsByID = Dictionary(groups.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        let lines = groups.flatMap { $0.liveRows($0.lineItems) }
        let linesByID = Dictionary(lines.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        var carry = CarriedChangeOrderLines(job: job)
        for groupDraft in draft.groups {
            if let order = groupDraft.changeOrder {
                guard let invoice, let id = groupDraft.modelID,
                      let stored = groupsByID[id],
                      stored.changeOrder?.persistentModelID == order.persistentModelID,
                      order.invoice?.persistentModelID == invoice.persistentModelID else {
                    throw DomainGate.refusal(.changeOrderLinesReadOnly, .saveInvoice)
                }
            }
            for line in groupDraft.lines where line.fromChangeOrder {
                if let id = line.modelID, let stored = linesByID[id], stored.fromChangeOrder,
                   stored.name == DocumentDraftRules.trim(line.name),
                   stored.quantity == line.quantity, stored.unitPrice == line.unitPrice {
                    continue
                }
                guard invoice == nil, carry.claim(line) else {
                    throw DomainGate.refusal(.changeOrderLinesReadOnly, .saveInvoice)
                }
            }
        }
    }

    /// The change-order lines a job's first invoice may carry in, counted so a tool can't send the
    /// same carried credit twice.
    private struct CarriedChangeOrderLines {
        private var counts: [String: Int] = [:]

        init(job: ScheduledJob?) {
            guard let job else { return }
            for line in jobBillingDraft(for: job).groups.flatMap(\.lines) where line.fromChangeOrder {
                counts[Self.key(line), default: 0] += 1
            }
        }

        /// True when this line is one of the carried rows (and takes it off the list).
        mutating func claim(_ line: InvoiceLineDraft) -> Bool {
            let key = Self.key(line)
            guard let left = counts[key], left > 0 else { return false }
            counts[key] = left - 1
            return true
        }

        private static func key(_ line: InvoiceLineDraft) -> String {
            [DocumentDraftRules.trim(line.name), String(line.quantity), String(line.unitPrice),
             line.isTaxable ? "t" : "f", line.discountType.rawValue, String(line.discountValue)]
                .joined(separator: "\u{1F}")
        }
    }

    @discardableResult
    private static func copyAttachments(_ selection: JobAttachmentSelection, from job: ScheduledJob,
                                        to invoice: Invoice, in context: ModelContext) -> Int {
        var copies = 0
        if selection.photos {
            for photo in job.photos {
                context.insert(JobAttachment(kind: .photo, name: photo.name, caption: photo.caption,
                                             data: photo.data, invoice: invoice))
                copies += 1
            }
        }
        if selection.documents {
            for doc in job.documents {
                context.insert(JobAttachment(kind: .document, name: doc.name, caption: doc.caption,
                                             data: doc.data, invoice: invoice))
                copies += 1
            }
        }
        if selection.expenses {
            for receipt in job.sortedReceipts where receipt.scanData != nil {
                context.insert(JobAttachment(
                    kind: .document,
                    name: "\(receipt.vendor.isEmpty ? "Expense" : receipt.vendor) Receipt.jpg",
                    caption: "Expense receipt: \(receipt.vendor) - \(receipt.total.formatted(.money))",
                    data: receipt.scanData,
                    invoice: invoice))
                copies += 1
            }
        }
        return copies
    }

    /// The form's save body: fields through `setIfChanged`, the service address compared whole,
    /// then the rows reconciled in place (change-order links and flags round-trip).
    private static func write(_ draft: InvoiceDraft, to invoice: Invoice, in context: ModelContext) {
        setIfChanged(invoice, \.jobTitle, DocumentDraftRules.trim(draft.jobTitle))
        setIfChanged(invoice, \.status, draft.status)
        setIfChanged(invoice, \.paymentTerms, draft.paymentTerms)
        setIfChanged(invoice, \.dueDate, dueDate(for: draft.paymentTerms, picked: draft.dueDate,
                                                   createdAt: invoice.createdAt))
        setIfChanged(invoice, \.taxRatePercent, draft.taxRatePercent)
        setIfChanged(invoice, \.discountType, draft.discountType)
        setIfChanged(invoice, \.discountValue, draft.discountValue)
        setIfChanged(invoice, \.customerNotes, draft.customerNotes)
        setIfChanged(invoice, \.terms, draft.terms)
        let address = DocumentDraftRules.trimmedAddress(draft.serviceAddress)
        if invoice.serviceAddress != address { invoice.serviceAddress = address }
        setIfChanged(invoice, \.amountDueNow, DomainMoney.roundedToCents(draft.amountDueNow))
        setIfChanged(invoice, \.amountDueDetail, DocumentDraftRules.trim(draft.amountDueDetail))
        if let include = draft.includePayLink { setIfChanged(invoice, \.includePayLink, include) }
        if let include = draft.includeZelle { setIfChanged(invoice, \.includeZelle, include) }
        setIfChanged(invoice, \.autoRemindersEnabled, draft.autoRemindersEnabled)
        setIfChanged(invoice, \.reminderStartTriggerRaw, draft.reminderStartTriggerRaw)
        setIfChanged(invoice, \.reminderFrequencyRaw, draft.reminderFrequencyRaw)

        RowReconciler.reconcile(
            existing: invoice.liveRows(invoice.groups),
            drafts: DocumentDraftRules.keptGroups(draft.groups),
            modelID: { $0.modelID },
            make: { _ in
                let group = InvoiceGroup()
                group.invoice = invoice
                context.insert(group)
                return group
            },
            update: { group, groupDraft, groupIndex in
                setIfChanged(group, \.name, groupDraft.name)
                setIfChanged(group, \.note, groupDraft.note)
                setIfChanged(group, \.sortIndex, groupIndex)
                // Keep applied change orders linked across edits.
                setIfChanged(group, \.changeOrder, groupDraft.changeOrder)
                RowReconciler.reconcile(
                    existing: group.liveRows(group.lineItems),
                    drafts: groupDraft.lines,
                    modelID: { $0.modelID },
                    make: { _ in
                        let item = InvoiceLineItem()
                        item.group = group
                        context.insert(item)
                        return item
                    },
                    update: { item, line, index in
                        setIfChanged(item, \.name, DocumentDraftRules.trim(line.name))
                        setIfChanged(item, \.details, DocumentDraftRules.trim(line.details))
                        setIfChanged(item, \.quantity, line.quantity)
                        setIfChanged(item, \.unit, line.unit)
                        setIfChanged(item, \.unitPrice, line.unitPrice)
                        setIfChanged(item, \.kind, line.kind)
                        setIfChanged(item, \.isTaxable, line.isTaxable)
                        setIfChanged(item, \.sortIndex, index)
                        setIfChanged(item, \.discountType, line.discountType)
                        setIfChanged(item, \.discountValue, line.discountValue)
                        setIfChanged(item, \.fromChangeOrder, line.fromChangeOrder)
                    },
                    delete: { context.deleteSynced($0) })
            },
            delete: { context.deleteSynced($0) })
    }
}
