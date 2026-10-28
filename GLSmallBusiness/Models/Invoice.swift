//
//  Invoice.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData
@_exported import GoldLifeDocuments

// MARK: - Enums
// `nonisolated` so their Codable conformances aren't main-actor isolated (SwiftData requirement).

nonisolated enum InvoiceStatus: String, Codable, CaseIterable, Identifiable {
    /// The lifecycle the user controls. Paid / Partially Paid / Overdue are derived from
    /// payments and the due date — see `Invoice.displayStatus`.
    case draft, sent

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .draft: mbLoc("Draft")
        case .sent: mbLoc("Sent")
        }
    }
}

public typealias PaymentTerms = GoldLifeDocuments.PaymentTerms

extension PaymentTerms {
    @MainActor
    var label: String {
        switch self {
        case .dueOnReceipt: mbLoc("Due on receipt")
        case .net15: mbLoc("Net 15")
        case .net30: mbLoc("Net 30")
        case .custom: mbLoc("Custom date")
        }
    }
}

/// Declaration order is picker order: the traditional rails first, then the P2P/processor apps small
/// businesses actually get paid through, then Other. Popular-only by design — additions should clear the
/// "would a US contractor see this weekly?" bar, not enumerate every fintech.
nonisolated enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case cash, check, card, transfer, zelle, venmo, cashApp, appleCash, paypal, googlePay, square, stripe, other

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .cash: mbLoc("Cash")
        case .check: mbLoc("Check")
        case .card: mbLoc("Card")
        case .transfer: mbLoc("Bank transfer")
        case .zelle: mbLoc("Zelle")
        case .venmo: mbLoc("Venmo")
        case .cashApp: mbLoc("Cash App")
        case .appleCash: mbLoc("Apple Cash")
        case .paypal: mbLoc("PayPal")
        case .googlePay: mbLoc("Google Pay")
        case .square: mbLoc("Square")
        case .stripe: mbLoc("Stripe")
        case .other: mbLoc("Other")
        }
    }

    /// The ENGLISH label, for surfaces whose surrounding template is English-only
    /// (customer text/email bodies, accountant CSVs): a half-translated sentence is
    /// wrong in every language, so these stay English until the whole surface is
    /// localized. Keys mirror `label` - keep the two switches in lockstep.
    var englishLabel: String {
        switch self {
        case .cash: "Cash"
        case .check: "Check"
        case .card: "Card"
        case .transfer: "Bank transfer"
        case .zelle: "Zelle"
        case .venmo: "Venmo"
        case .cashApp: "Cash App"
        case .appleCash: "Apple Cash"
        case .paypal: "PayPal"
        case .googlePay: "Google Pay"
        case .square: "Square"
        case .stripe: "Stripe"
        case .other: "Other"
        }
    }

    /// Methods a customer plausibly used to pay a Stripe Payment Link — the reconciliation matchers
    /// treat a hand-recorded payment under any of these as a candidate for the outstanding link.
    var couldSettleStripeLink: Bool { self == .card || self == .stripe }

    /// Mixed-version sync safety: an unknown raw value (a method added in a FUTURE build, synced
    /// down via CloudKit) decodes as `.other` instead of throwing and nuking the whole record.
    /// This protects every future case addition — the already-shipped binary lacks this fallback
    /// (unfixable from here), but no build from now on may ever crash on an unknown method.
    /// Encoding stays the synthesized rawValue, so known values round-trip unchanged.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaymentMethod(rawValue: raw) ?? .other
    }
}

// MARK: - Invoice

@Model
final class Invoice {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var number: String = ""
    var jobTitle: String = ""
    var createdAt: Date = Date.now
    var dueDate: Date = Date.now
    var paymentTerms: PaymentTerms = PaymentTerms.net30
    var status: InvoiceStatus = InvoiceStatus.draft

    // Customer snapshot — frozen at creation, like estimates.
    var customerFirstName: String = ""
    var customerLastName: String = ""
    var customerBusinessName: String?
    var customerEmail: String = ""
    var customerPhone: String = ""
    /// ⚠️ DORMANT-LEGACY, WRITE-FORBIDDEN (2026-09-01, the build-62 SIGTRAP — same class
    /// as UserProfile.address, build 48). A history UPDATE row naming a composite
    /// sub-attribute whose keypath crosses ANY Optional (`Address.street2: String?`)
    /// fatals uncatchably inside `fetchHistory`. Kept only so old stores keep opening;
    /// `AddressFlatsBackfill` forward-copies it once at mount. Swift-renamed so the
    /// public name stays on the flats façade; `originalName` pins the stored column.
    /// Nothing may ever assign it — reads are safe, writes poison history.
    @Attribute(originalName: "customerAddress") var legacyCustomerAddress: Address = Address()
    /// The flattened columns behind the `customerAddress` façade (the write path since
    /// 2026-09-01). Primitive strings, so their history rows always resolve.
    var customerAddressStreet1: String = ""
    var customerAddressStreet2: String = ""
    var customerAddressCity: String = ""
    var customerAddressState: String = ""
    var customerAddressPostalCode: String = ""

    /// The job site / lot this invoice is for. Independent of the customer's (billing) address;
    /// carried over from the originating estimate when converted.
    /// ⚠️ DORMANT-LEGACY, WRITE-FORBIDDEN (2026-09-01, the build-62 SIGTRAP — same class
    /// as UserProfile.address, build 48). A history UPDATE row naming a composite
    /// sub-attribute whose keypath crosses ANY Optional (`Address.street2: String?`)
    /// fatals uncatchably inside `fetchHistory`. Kept only so old stores keep opening;
    /// `AddressFlatsBackfill` forward-copies it once at mount. Swift-renamed so the
    /// public name stays on the flats façade; `originalName` pins the stored column.
    /// Nothing may ever assign it — reads are safe, writes poison history.
    @Attribute(originalName: "serviceAddress") var legacyServiceAddress: Address = Address()
    /// The flattened columns behind the `serviceAddress` façade (the write path since
    /// 2026-09-01). Primitive strings, so their history rows always resolve.
    var serviceAddressStreet1: String = ""
    var serviceAddressStreet2: String = ""
    var serviceAddressCity: String = ""
    var serviceAddressState: String = ""
    var serviceAddressPostalCode: String = ""

    var customer: Customer?

    /// The estimate this was converted from, for reference on the invoice (display only).
    var sourceEstimateNumber: String?

    // Financials (same model as estimates; deposit is handled via recorded payments instead).
    var taxRatePercent: Double = 0
    var discountType: AdjustmentType = AdjustmentType.none
    var discountValue: Double = 0

    // Content
    var customerNotes: String = ""
    var terms: String = ""

    /// Milestone billing: the amount being requested right now (e.g. a deposit) and what it's
    /// for. 0 means no specific request, so the full balance is due. Recording a payment reduces
    /// this toward 0; you then set the next milestone's amount and label and resend.
    var amountDueNow: Double = 0
    var amountDueDetail: String = ""

    // MARK: Stripe payment link
    // Populated only when a pay link is minted for this invoice (see the send flow). All additive/defaulted.

    /// App-owned, stable, install-unique correlation id for Stripe. Generated once — the first time a pay
    /// link is minted for this invoice; "" until then. This (NOT `number`, which is per-install and so
    /// collides across installs, and NOT `persistentModelID`) is `metadata[app_invoice_id]`, the backend
    /// status-store key, and the status-poll key. Set lazily via `ensureStripeAppInvoiceId()`.
    var stripeAppInvoiceId: String = ""
    /// Per-invoice opt-in, used only when the business's inclusion mode is `.customSelect`.
    var includePayLink: Bool = false
    /// Whether this invoice includes Zelle payment contact details and QR code.
    var includeZelle: Bool = false
    /// The last Stripe Payment Link minted for this invoice — reused on a same-amount resend.
    var stripePaymentLinkId: String = ""
    var stripePaymentLinkURL: String = ""
    /// The connected account the current link was minted UNDER. The backend keys pay status on
    /// (connected account, invoice), so once the business connects a different account — exactly what
    /// recovering from a dead binding does — the old link can never be reused, refreshed, or marked
    /// paid. Without this stamp every pre-existing invoice would keep embedding the old account's URL
    /// forever. "" = minted before this was recorded, which counts as a mismatch so the next send
    /// re-mints and stamps it. Additive/defaulted per the CloudKit rules.
    var stripePaymentLinkAccountId: String = ""
    /// The amount (in cents) the current link was minted for, so a changed amount (milestone/partial)
    /// retires the old link and mints a new one. 0 = none yet.
    var stripePaymentLinkAmountCents: Int = 0
    /// `StripePayLinkStatus.rawValue` cache of the backend-reported pay status. A display/reconciliation
    /// hint only — `InvoicePayment`s stay the money source of truth.
    var stripePayLinkStatusRaw: String = ""
    /// Monotonic mint counter, appended to the Stripe idempotency key so every newly-minted link gets a
    /// UNIQUE key. Without it, returning to a previously-minted amount (e.g. a milestone round-trip
    /// $100 → $50 → $100) would replay Stripe's cached response for a now-deactivated link.
    var stripePayLinkMintCount: Int = 0
    /// When the CURRENT link was minted. Reconciliation uses it to ignore unstamped hand-recorded
    /// payments that predate this link (they belong to an earlier milestone, not this one).
    /// nil for links minted before this field existed. Additive/optional per the CloudKit rules.
    var stripePaymentLinkMintedAt: Date?

    /// Highest change-order number ever minted for this invoice — the next CO is
    /// max(seed, highest existing) + 1, so deleting the top order can never reuse its number
    /// (see `ChangeOrder.nextNumber(for:)`; callers bump this after assigning a number).
    /// Additive/defaulted per the CloudKit rules; joins the pending prod-schema deploy.
    var changeOrderNumberSeed: Int = 0

    // MARK: Automated Reminders (Rulings 3 & 6)
    var autoRemindersEnabled: Bool = false
    var reminderStartTriggerRaw: String = ReminderStartTrigger.oneWeekBeforeDue.rawValue
    var reminderFrequencyRaw: String = ReminderFrequency.weekly.rawValue
    var lastReminderSentAt: Date?
    var isMarkedPastDue: Bool = false

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \InvoiceGroup.invoice)
    var groups: [InvoiceGroup]?

    @Relationship(deleteRule: .cascade, inverse: \InvoicePayment.invoice)
    var payments: [InvoicePayment]?

    @Relationship(deleteRule: .cascade, inverse: \ChangeOrder.invoice)
    var changeOrders: [ChangeOrder]?

    /// Calendar bookings made from this invoice. Nullify so deleting the invoice keeps the booking
    /// (with its title/customer snapshot) on the calendar.
    @Relationship(deleteRule: .nullify, inverse: \ScheduledJob.invoice)
    var scheduledJobs: [ScheduledJob]?

    /// The job this invoice BILLS (progress billing). Distinct from `scheduledJobs` (jobs scheduled
    /// FROM this invoice). Inverse of `ScheduledJob.billingInvoices`.
    var job: ScheduledJob?

    /// The contract this invoice BILLS (progress billing).
    var contract: Contract?

    /// Attachments (proof-of-work photos, docs, expense receipts) associated with this invoice.
    @Relationship(deleteRule: .cascade, inverse: \JobAttachment.invoice)
    var attachments: [JobAttachment]?

    /// Proof-of-work photos, newest first.
    var photos: [JobAttachment] {
        liveRows(attachments).filter { $0.kind == .photo }.sorted { $0.createdAt > $1.createdAt }
    }
    /// Additional documents, newest first.
    var documents: [JobAttachment] {
        liveRows(attachments).filter { $0.kind == .document }.sorted { $0.createdAt > $1.createdAt }
    }

    init(
        number: String = "",
        jobTitle: String = "",
        createdAt: Date = .now,
        paymentTerms: PaymentTerms = .net30,
        dueDate: Date? = nil,
        status: InvoiceStatus = .draft,
        customer: Customer? = nil
    ) {
        self.number = number
        self.jobTitle = jobTitle
        self.createdAt = createdAt
        self.paymentTerms = paymentTerms
        self.dueDate = dueDate ?? paymentTerms.dueDate(from: createdAt) ?? createdAt
        self.status = status
        self.customer = customer
        if let customer {
            self.customerFirstName = customer.firstName
            self.customerLastName = customer.lastName
            self.customerBusinessName = customer.businessName
            self.customerEmail = customer.email
            self.customerPhone = customer.phoneNumber
            self.customerAddress = customer.address
        }
    }
}

// MARK: - Invoice computed values

extension Invoice {
    var customerDisplayName: String {
        let full = [customerFirstName, customerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if let business = customerBusinessName?.trimmingCharacters(in: .whitespacesAndNewlines), !business.isEmpty {
            return business
        }
        return "Customer"
    }

    /// Recipient to pre-fill when emailing — the customer's CURRENT email, falling back to the
    /// snapshot taken at creation, so contact info added or changed later is still used.
    var recipientEmail: String {
        let live = (customer?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerEmail : live
    }
    /// Same, for texting — the customer's current mobile, falling back to the snapshot.
    var recipientPhone: String {
        let live = (customer?.phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerPhone : live
    }

    var sortedGroups: [InvoiceGroup] {
        liveRows(groups).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allLineItems: [InvoiceLineItem] {
        sortedGroups.flatMap { $0.sortedLineItems }
    }

    /// Money math, shared with estimates. Invoices don't carry a deposit (payments cover that).
    /// The overall discount applies only to the ORIGINAL work; change-order line items are added at
    /// full price (and full tax, at the rate each order was signed at — law 87, QA F82) on top, so
    /// the invoice matches each signed change order exactly.
    var totals: EstimateTotals {
        // One formula, shared with the form preview and the lock preview (MoneyLockPreview.swift).
        let (original, changeOrder) = billedLines()
        return InvoiceMath.totals(original: original, ratedChangeOrder: changeOrder,
                                  taxRatePercent: taxRatePercent, discountType: discountType,
                                  discountValue: discountValue)
    }

    /// The live lines as the money formula reads them: the original work, and the change-order
    /// lines each with the tax rate it bills at (its group's signed order rate, else this invoice's
    /// rate). Change-order items carry their sign (a credit reduces the invoice), so they use
    /// signedLineTotal — NOT the floored lineTotal, which would clamp a credit to 0. `excluding`
    /// leaves one group out (the lock previews measure an order's group off the invoice).
    func billedLines(excluding skipped: InvoiceGroup? = nil)
        -> (original: [(lineTotal: Decimal, isTaxable: Bool)],
            changeOrder: [(signedLineTotal: Decimal, isTaxable: Bool, taxRatePercent: Double)]) {
        let skippedID = skipped?.persistentModelID
        var original: [(lineTotal: Decimal, isTaxable: Bool)] = []
        var changeOrder: [(signedLineTotal: Decimal, isTaxable: Bool, taxRatePercent: Double)] = []
        for group in sortedGroups where skippedID == nil || group.persistentModelID != skippedID {
            let rate = group.changeOrderTaxRate(invoiceRate: taxRatePercent)
            for item in group.sortedLineItems {
                if item.fromChangeOrder {
                    changeOrder.append((item.exactSignedLineTotal, item.isTaxable, rate))
                } else {
                    original.append((item.exactLineTotal, item.isTaxable))
                }
            }
        }
        return (original, changeOrder)
    }

    var subtotal: Double { totals.subtotal }
    var discountAmount: Double { totals.discount }
    var taxAmount: Double { totals.tax }
    var total: Double { totals.total }

    // Payments
    var sortedPayments: [InvoicePayment] {
        liveRows(payments).sorted { $0.date < $1.date }
    }

    /// Every payment added up exactly, rounded once (law 60) — the sync Worker's paid-lock rule, and
    /// the same figure the paid-to-date on each receipt and Statistics' collected total use.
    var amountPaid: Double {
        DomainMoney.roundedSum(liveRows(payments).map(\.amount))
    }

    /// Cumulative amount paid up to and including `payment`, in payment order — the figure a payment
    /// receipt reflects (the state of the invoice at the time of that payment).
    func paidThrough(_ payment: InvoicePayment) -> Double {
        var amounts: [Double] = []
        for entry in sortedPayments {
            amounts.append(entry.amount)
            if entry.id == payment.id { break }
        }
        return DomainMoney.roundedSum(amounts)
    }

    /// Balance left after `payment` was applied. Shown on a receipt as "remaining balance".
    func remainingAfter(_ payment: InvoicePayment) -> Double {
        InvoiceMath.owed(total: total, paid: paidThrough(payment))
    }

    // Change orders
    var sortedChangeOrders: [ChangeOrder] {
        liveRows(changeOrders).sorted { $0.createdAt < $1.createdAt }
    }

    /// Net price change from approved change orders that have NOT yet been pushed onto the invoice.
    /// Once a change order is "added to invoice" its items live in `groups`, so `total` already
    /// reflects it — counting it here too would double it.
    var approvedChangeOrderTotal: Double { DomainMoney.roundedToCents(exactApprovedChangeOrderTotal) }

    /// The same, exact — added to the exact invoice total before the revised total's one rounding.
    private var exactApprovedChangeOrderTotal: Decimal {
        sortedChangeOrders
            .filter { $0.status == .approved && !$0.appliedToInvoice }
            .reduce(Decimal(0)) { $0 + $1.totals.exactTotal }
    }

    /// Invoice total plus approved-but-not-yet-applied change orders — the figure the job is now worth.
    /// Worked out exactly and rounded once, so it is the total the invoice bills once they are added.
    var revisedTotal: Double { DomainMoney.roundedToCents(totals.exactTotal + exactApprovedChangeOrderTotal) }

    var balanceDue: Double {
        // Based on the itemized total only — a change order is not billed (and not owed on this invoice)
        // until its items are added to the invoice. The invoice screen prompts you to add approved change
        // orders so signed work isn't forgotten; `revisedTotal` is the informational "what it'll be worth
        // once added" figure, not the billed balance.
        InvoiceMath.owed(total: total, paid: amountPaid)
    }

    /// What is owed BACK to the customer: the payments less the total, never below zero. Non-zero
    /// only when a credit change order or an edit cut the invoice below what was already paid; then
    /// the balance reads $0.00 and Paid − Credit due == Total to the cent (law 60; QA F85).
    var creditDue: Double { GLInvoiceMath.creditDue(total: total, paid: amountPaid) }

    /// The rate printed beside "Tax": this invoice's rate, or nil when a billed change order is
    /// taxed at a different rate (the one it was signed at, QA F82) — one percent would then
    /// misstate the tax line, so it reads plain "Tax".
    var shownTaxRatePercent: Double? {
        let rates = billedLines().changeOrder.filter(\.isTaxable).map(\.taxRatePercent)
        return rates.allSatisfy { $0 == taxRatePercent } ? taxRatePercent : nil
    }

    /// Whether a specific milestone amount (rather than the whole balance) is being requested now.
    var hasAmountDueRequest: Bool { amountDueNow > 0.005 }

    /// What the customer is asked to pay now: the milestone request if one is set (rounded to the cent,
    /// capped at the remaining balance), otherwise the full balance. The pay link charges exactly this.
    var currentAmountDue: Double {
        hasAmountDueRequest ? min(DomainMoney.roundedToCents(amountDueNow), balanceDue) : balanceDue
    }

    /// Reduce the open milestone request by a payment that just came in, clearing its label once
    /// nothing is left to ask for. No-op when no request is set — the full balance is being asked
    /// for, and there is nothing to draw down.
    ///
    /// This runs on the payment that SETTLES the invoice too, deliberately. `amountDueNow` is a
    /// REQUEST for money, not a record of money collected: the sync manifest lists it as
    /// `paid_lock_exempt`, so the Worker accepts this write on a paid invoice while still refusing
    /// every price, tax, discount and pay-link-amount edit (gl-business-api README §3.6). Skipping
    /// it here instead would leave a settled invoice permanently asking for money it already got —
    /// visible again the moment a change order re-opens the balance.
    ///
    /// Worked exactly (law 60): the payment is whole cents (`InvoiceService.recordPayment` stores it
    /// that way), so the request as it reads less the payment is the exact difference rounded once —
    /// never a binary one (29,926.295 − 24,807.80 used to leave 5,118.4949… and ask for $5,118.49
    /// instead of $5,118.50).
    func drawDownAmountDueRequest(by payment: Double) {
        guard amountDueNow > 0 else { return }
        amountDueNow = DomainMoney.remaining(amountDueNow, less: payment)
        if !hasAmountDueRequest { amountDueDetail = "" }
    }

    // MARK: - Stripe payment link

    /// Backend-reported pay-link status, read from `stripePayLinkStatusRaw`.
    var stripePayLinkStatus: StripePayLinkStatus {
        get { StripePayLinkStatus(rawValue: stripePayLinkStatusRaw) ?? .none }
        set { stripePayLinkStatusRaw = newValue.rawValue }
    }

    /// Whether this invoice should carry a pay link when sent. Requires a connected, charge-ready Stripe
    /// account; then honors this invoice's own `includePayLink` (seeded from the business default at
    /// creation, overridable per invoice).
    func shouldIncludePayLink(_ business: BusinessProfile?) -> Bool {
        guard let business, business.stripeIsConnected, business.stripeChargesEnabled else { return false }
        return includePayLink
    }

    /// Forget the stored pay link. One call so a caller can't clear three of the four fields and leave
    /// the invoice pointing at a link the backend has already deactivated. `stripePayLinkMintCount` is
    /// deliberately NOT reset — it keeps the Stripe idempotency key unique across re-mints.
    func clearStripePayLink() {
        stripePaymentLinkId = ""
        stripePaymentLinkURL = ""
        stripePaymentLinkAccountId = ""
        stripePaymentLinkAmountCents = 0
        stripePaymentLinkMintedAt = nil
        stripePayLinkStatus = .none
    }

    /// Lazily assigns and returns the stable Stripe correlation id, generating it on first use.
    func ensureStripeAppInvoiceId() -> String {
        if stripeAppInvoiceId.isEmpty { stripeAppInvoiceId = UUID().uuidString }
        return stripeAppInvoiceId
    }

    // Settled when nothing is owed. The extra clause lets a $0 (fully-comped) invoice that's been sent
    // read "Paid" instead of being stuck "Overdue" forever, without making a brand-new $0 draft do so.
    var isPaid: Bool { InvoiceMath.isPaid(total: total, amountPaid: amountPaid, status: status) }
    var isPartiallyPaid: Bool { amountPaid > 0 && !isPaid }
    var isOverdue: Bool { !isPaid && (isMarkedPastDue || (status == .sent && dueDate < .now)) }

    var reminderStartTrigger: ReminderStartTrigger {
        get { ReminderStartTrigger(rawValue: reminderStartTriggerRaw) ?? .oneWeekBeforeDue }
        set { reminderStartTriggerRaw = newValue.rawValue }
    }

    var reminderFrequency: ReminderFrequency {
        get { ReminderFrequency(rawValue: reminderFrequencyRaw) ?? .weekly }
        set { reminderFrequencyRaw = newValue.rawValue }
    }

    /// Status as shown to the user — surfaces Paid / Partially Paid / Overdue automatically.
    @MainActor
    var displayStatus: String {
        if isPaid { return mbLoc("Paid") }
        if isOverdue { return mbLoc("Overdue") }
        if isPartiallyPaid { return mbLoc("Partially Paid") }
        return status.label
    }

    /// The next invoice number. Seeded from the larger of the highest existing number and the profile's
    /// monotonic counter, then bumps the counter — so deleting the highest invoice doesn't reuse its
    /// number. Pass the business profile to enable the counter (nil = plain max+1, used in tests).
    static func nextNumber(after existing: [Invoice], profile: BusinessProfile? = nil) -> String {
        let computed = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "INV-", with: "")) }
            .max() ?? 0
        let next = max(profile?.lastInvoiceNumber ?? 0, computed) + 1
        profile?.lastInvoiceNumber = next
        return String(format: "INV-%04d", next)
    }

    /// Builds an invoice from an estimate: copies the frozen snapshot, line items, and
    /// tax/discount, requests the estimate's deposit as the invoice's "amount due now" (it is
    /// collected and logged as a payment later, not paid here), and links the originating estimate
    /// number. The new invoice and its children are inserted into `context`.
    @MainActor
    /// `chosenGroups` — nil converts everything (the classic estimate). An OPTIONS
    /// estimate (combineTotals off) passes the group(s) the customer picked; only
    /// those become invoice groups, keeping their original order.
    static func make(from estimate: Estimate, number: String,
                     chosenGroups: [EstimateGroup]? = nil, in context: ModelContext) -> Invoice {
        let invoice = Invoice(number: number, jobTitle: estimate.jobTitle, customer: estimate.customer)
        // Use the estimate's frozen snapshot (the agreed details), not the live customer.
        invoice.customerFirstName = estimate.customerFirstName
        invoice.customerLastName = estimate.customerLastName
        invoice.customerBusinessName = estimate.customerBusinessName
        invoice.customerEmail = estimate.customerEmail
        invoice.customerPhone = estimate.customerPhone
        invoice.customerAddress = estimate.customerAddress
        invoice.serviceAddress = estimate.serviceAddress
        invoice.taxRatePercent = estimate.taxRatePercent
        // Options conversion (chosenGroups != nil): the estimate-level discount was
        // IGNORED on every options surface, so copying it minted an invoice whose
        // total differed from the "Option total" the customer was quoted (QA
        // 2026-09-01). A fixed discount sized against the sum of ALL options is
        // especially wrong against one chosen option.
        if chosenGroups == nil {
            invoice.discountType = estimate.discountType
            invoice.discountValue = estimate.discountValue
        }
        invoice.customerNotes = estimate.customerNotes
        invoice.terms = estimate.terms
        invoice.sourceEstimateNumber = estimate.number
        // Seed the per-invoice Pay-button choice from the business default (overridable per invoice).
        if let profile = try? context.fetch(FetchDescriptor<BusinessProfile>()).first {
            invoice.includePayLink = profile.payLinkDefaultOn
        }
        context.insert(invoice)

        let sourceGroups = chosenGroups.map { chosen in
            estimate.sortedGroups.filter { group in chosen.contains { $0 === group } }
        } ?? estimate.sortedGroups
        for group in sourceGroups {
            let invoiceGroup = InvoiceGroup(name: group.name, note: group.note, sortIndex: group.sortIndex)
            invoiceGroup.invoice = invoice
            context.insert(invoiceGroup)
            for item in group.sortedLineItems {
                let invoiceItem = InvoiceLineItem(
                    name: item.name,
                    details: item.details,
                    quantity: item.quantity,
                    unit: item.unit,
                    unitPrice: item.unitPrice,
                    kind: item.kind,
                    isTaxable: item.isTaxable,
                    sortIndex: item.sortIndex,
                    discountType: item.discountType,
                    discountValue: item.discountValue
                )
                invoiceItem.group = invoiceGroup
                context.insert(invoiceItem)
            }
        }

        // If the estimate had a deposit, request it as the amount due now (not yet paid) — it's
        // collected later and logged as a payment. NOT for an options conversion:
        // depositAmount is computed on the COMBINED total of every option, so a 30%
        // deposit on $1k/$2k/$3k options billed $1,800 "due now" on a $1,000 job
        // (QA 2026-09-01). Options mode ignores the estimate-level deposit.
        if chosenGroups == nil, estimate.depositAmount > 0 {
            invoice.amountDueNow = estimate.depositAmount
            invoice.amountDueDetail = "Deposit to start"
        }

        return invoice
    }
}

// MARK: - Group

@Model
final class InvoiceGroup {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var name: String = ""
    var note: String = ""
    var sortIndex: Int = 0

    var invoice: Invoice?

    /// Set when this group was pushed from a change order, so deleting/editing/declining that order can
    /// find and remove exactly its own items (additive/optional; nil for groups made by hand or pushed
    /// before this link existed). The declared side lives on ChangeOrder.
    var changeOrder: ChangeOrder?

    @Relationship(deleteRule: .cascade, inverse: \InvoiceLineItem.group)
    var lineItems: [InvoiceLineItem]?

    init(name: String = "", note: String = "", sortIndex: Int = 0) {
        self.name = name
        self.note = note
        self.sortIndex = sortIndex
    }

    var sortedLineItems: [InvoiceLineItem] {
        liveRows(lineItems).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The rate this group's change-order lines are taxed at (law 87: a signed document never
    /// changes; QA F82): the snapshot of the live order the group was pushed from, else the
    /// invoice's rate (a group pushed before the link existed, or one made by hand). The same rule
    /// as the server's money.ts `invoiceDerived`.
    func changeOrderTaxRate(invoiceRate: Double) -> Double {
        Self.changeOrderTaxRate(changeOrder, invoiceRate: invoiceRate)
    }

    /// The same, for a group's linked order as a form draft holds it. A deleted order (saved or
    /// pending) is no order: its rate is never read.
    static func changeOrderTaxRate(_ order: ChangeOrder?, invoiceRate: Double) -> Double {
        guard let order, !order.isSavedDelete, !order.isDeleted else { return invoiceRate }
        return order.taxRatePercent
    }

    /// The group's lines added up exactly, rounded once (law 60).
    var subtotal: Double {
        DomainMoney.roundedToCents(liveRows(lineItems).reduce(Decimal(0)) { $0 + $1.exactLineTotal })
    }

    /// The group as its rows show it on the invoice screen and PDF (change-order credits signed), added
    /// up exactly and rounded once.
    var shownSubtotal: Double {
        DomainMoney.roundedToCents(sortedLineItems.reduce(Decimal(0)) { $0 + $1.exactShownTotal })
    }
}

// MARK: - Line item

@Model
final class InvoiceLineItem {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.squareFoot
    var unitPrice: Double = 0
    var kind: LineItemKind = LineItemKind.labor
    var isTaxable: Bool = false
    var sortIndex: Int = 0
    /// True for line items pushed in from a change order. They're charged at full price — the invoice's
    /// overall discount does NOT apply to them — so the invoice matches the signed change order exactly.
    var fromChangeOrder: Bool = false
    /// Optional per-line discount, applied on top of any whole-invoice discount. Additive + defaulted.
    var discountType: AdjustmentType = AdjustmentType.none
    var discountValue: Double = 0

    var group: InvoiceGroup?

    init(
        name: String = "",
        details: String = "",
        quantity: Double = 1,
        unit: UnitOfMeasure = .squareFoot,
        unitPrice: Double = 0,
        kind: LineItemKind = .labor,
        isTaxable: Bool = false,
        sortIndex: Int = 0,
        discountType: AdjustmentType = .none,
        discountValue: Double = 0
    ) {
        self.name = name
        self.details = details
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.kind = kind
        self.isTaxable = isTaxable
        self.sortIndex = sortIndex
        self.discountType = discountType
        self.discountValue = discountValue
    }

    /// This line's money, exact (law 60).
    var money: LineMoney {
        LineMoney(quantity: quantity, unitPrice: unitPrice, discountType: discountType, discountValue: discountValue)
    }
    /// Price before the per-line discount (quantity × unit price), rounded once.
    var grossLineTotal: Double { DomainMoney.roundedToCents(money.gross) }
    /// The per-line discount in dollars (0 when none), never more than the gross, rounded once.
    var lineDiscount: Double { DomainMoney.roundedToCents(money.discount) }
    /// Price after the per-line discount, PRESERVING sign — a change-order credit (negative unit price)
    /// must be able to reduce the invoice, so change-order items use this instead of the floored total.
    var signedLineTotal: Double { DomainMoney.roundedToCents(money.signed) }
    /// Price after the per-line discount, floored at 0 so a single over-discounted line can't go
    /// negative — what an ORIGINAL-work line shows.
    var lineTotal: Double { DomainMoney.roundedToCents(money.floored) }
    /// The floored total, exact — what flows into the document subtotal and tax for original work.
    var exactLineTotal: Decimal { money.floored }
    /// The signed total, exact — what a change-order line adds to the invoice.
    var exactSignedLineTotal: Decimal { money.signed }
    /// What the line shows on the invoice screen and PDF, exact: a change-order line keeps its sign (a
    /// credit reads negative, as `Invoice.totals` bills it); original work floors at 0.
    var exactShownTotal: Decimal { fromChangeOrder ? exactSignedLineTotal : exactLineTotal }
}

// MARK: - Payment

@Model
final class InvoicePayment {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var amount: Double = 0
    var date: Date = Date.now
    var method: PaymentMethod = PaymentMethod.other
    var note: String = ""

    /// RETIRED INPUT — the processing-fee tracker was removed from the UI, so new payments never set these
    /// three fields (they stay ""/0). Kept in the schema (live app) and still read by `processingFee` +
    /// Statistics, so EXISTING payments' historical fee deductions remain accurate.
    ///
    /// The payment processor used, snapshotted BY NAME so the record stays stable if the processor is
    /// later renamed or deleted. Empty = none / no processing fee.
    var processorName: String = ""
    /// The processor's fee percentage, snapshotted at record time (so editing the processor's rate
    /// later never rewrites this payment's fee). Mirrors the rate-snapshot pattern on TimeEntry.
    var processorFeePercentSnapshot: Double = 0
    /// The processor's flat per-transaction fee, snapshotted at record time.
    var processorFlatFeeSnapshot: Double = 0

    /// The Stripe Payment Link this payment reconciles (empty for manually-entered payments). Set when a
    /// payment is recorded from the "Stripe reports this invoice was paid" prompt, so the poll knows the
    /// card payment is already reconciled and never re-prompts or double-counts it.
    var stripePaymentLinkId: String = ""

    var invoice: Invoice?

    init(amount: Double = 0, date: Date = .now, method: PaymentMethod = .other, note: String = "") {
        self.amount = amount
        self.date = date
        self.method = method
        self.note = note
    }

    /// The processing fee on this payment — percentage of the amount plus the flat fee, using the
    /// snapshotted rates, worked out exactly and rounded once. Zero when no processor was selected.
    /// A deductible business expense.
    var processingFee: Double {
        processorName.isEmpty ? 0 : PaymentProcessor.fee(on: amount, percent: processorFeePercentSnapshot,
                                                         flat: processorFlatFeeSnapshot)
    }
}

extension Invoice {
    /// THE one door to `customerAddress`. Reads see the flat columns only; writes go to flats
    /// only — the legacy composite is write-forbidden (see its doc). Empty street2
    /// normalizes to nil, which renders identically.
    var customerAddress: Address {
        get {
            Address(street1: customerAddressStreet1,
                    street2: customerAddressStreet2.isEmpty ? nil : customerAddressStreet2,
                    city: customerAddressCity,
                    state: customerAddressState,
                    postalCode: customerAddressPostalCode)
        }
        set {
            customerAddressStreet1 = newValue.street1
            customerAddressStreet2 = newValue.street2 ?? ""
            customerAddressCity = newValue.city
            customerAddressState = newValue.state
            customerAddressPostalCode = newValue.postalCode
        }
    }
}

extension Invoice {
    /// THE one door to `serviceAddress`. Reads see the flat columns only; writes go to flats
    /// only — the legacy composite is write-forbidden (see its doc). Empty street2
    /// normalizes to nil, which renders identically.
    var serviceAddress: Address {
        get {
            Address(street1: serviceAddressStreet1,
                    street2: serviceAddressStreet2.isEmpty ? nil : serviceAddressStreet2,
                    city: serviceAddressCity,
                    state: serviceAddressState,
                    postalCode: serviceAddressPostalCode)
        }
        set {
            serviceAddressStreet1 = newValue.street1
            serviceAddressStreet2 = newValue.street2 ?? ""
            serviceAddressCity = newValue.city
            serviceAddressState = newValue.state
            serviceAddressPostalCode = newValue.postalCode
        }
    }
}
