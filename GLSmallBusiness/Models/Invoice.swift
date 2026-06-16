//
//  Invoice.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData

// MARK: - Enums
// `nonisolated` so their Codable conformances aren't main-actor isolated (SwiftData requirement).

nonisolated enum InvoiceStatus: String, Codable, CaseIterable, Identifiable {
    /// The lifecycle the user controls. Paid / Partially Paid / Overdue are derived from
    /// payments and the due date — see `Invoice.displayStatus`.
    case draft, sent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: String(localized: "Draft")
        case .sent: String(localized: "Sent")
        }
    }
}

nonisolated enum PaymentTerms: String, Codable, CaseIterable, Identifiable {
    case dueOnReceipt, net15, net30, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dueOnReceipt: String(localized: "Due on receipt")
        case .net15: String(localized: "Net 15")
        case .net30: String(localized: "Net 30")
        case .custom: String(localized: "Custom date")
        }
    }

    /// Days from the invoice date until due, or nil when the user picks a custom date.
    var days: Int? {
        switch self {
        case .dueOnReceipt: 0
        case .net15: 15
        case .net30: 30
        case .custom: nil
        }
    }

    func dueDate(from start: Date) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: days, to: start)
    }
}

nonisolated enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case cash, check, card, transfer, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cash: String(localized: "Cash")
        case .check: String(localized: "Check")
        case .card: String(localized: "Card")
        case .transfer: String(localized: "Bank transfer")
        case .other: String(localized: "Other")
        }
    }
}

// MARK: - Invoice

@Model
final class Invoice {
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
    var customerAddress: Address = Address()

    /// The job site / lot this invoice is for. Independent of the customer's (billing) address;
    /// carried over from the originating estimate when converted.
    var serviceAddress: Address = Address()

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

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \InvoiceGroup.invoice)
    var groups: [InvoiceGroup]?

    @Relationship(deleteRule: .cascade, inverse: \InvoicePayment.invoice)
    var payments: [InvoicePayment]?

    @Relationship(deleteRule: .cascade, inverse: \ChangeOrder.invoice)
    var changeOrders: [ChangeOrder]?

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

    var sortedGroups: [InvoiceGroup] {
        (groups ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allLineItems: [InvoiceLineItem] {
        sortedGroups.flatMap { $0.sortedLineItems }
    }

    /// Money math, shared with estimates. Invoices don't carry a deposit (payments cover that).
    var totals: EstimateTotals {
        EstimateTotals(
            lines: allLineItems.map { ($0.lineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: discountType,
            discountValue: discountValue,
            depositType: .none,
            depositValue: 0
        )
    }

    var subtotal: Double { totals.subtotal }
    var discountAmount: Double { totals.discount }
    var taxAmount: Double { totals.tax }
    var total: Double { totals.total }

    // Payments
    var sortedPayments: [InvoicePayment] {
        (payments ?? []).sorted { $0.date < $1.date }
    }

    var amountPaid: Double {
        (payments ?? []).reduce(0) { $0 + $1.amount }
    }

    /// Cumulative amount paid up to and including `payment`, in payment order — the figure a payment
    /// receipt reflects (the state of the invoice at the time of that payment).
    func paidThrough(_ payment: InvoicePayment) -> Double {
        var sum = 0.0
        for entry in sortedPayments {
            sum += entry.amount
            if entry.id == payment.id { break }
        }
        return sum
    }

    /// Balance left after `payment` was applied. Shown on a receipt as "remaining balance".
    func remainingAfter(_ payment: InvoicePayment) -> Double {
        max(0, total - paidThrough(payment))
    }

    // Change orders
    var sortedChangeOrders: [ChangeOrder] {
        (changeOrders ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Net price change from all approved change orders.
    var approvedChangeOrderTotal: Double {
        sortedChangeOrders.filter { $0.status == .approved }.reduce(0) { $0 + $1.total }
    }

    /// Invoice total plus approved change orders — the figure the job is now worth.
    var revisedTotal: Double { total + approvedChangeOrderTotal }

    var balanceDue: Double {
        max(0, total - amountPaid)
    }

    /// Whether a specific milestone amount (rather than the whole balance) is being requested now.
    var hasAmountDueRequest: Bool { amountDueNow > 0.005 }

    /// What the customer is asked to pay now: the milestone request if one is set (capped at the
    /// remaining balance), otherwise the full balance.
    var currentAmountDue: Double {
        hasAmountDueRequest ? min(amountDueNow, balanceDue) : balanceDue
    }

    var isPaid: Bool { total > 0 && balanceDue <= 0.005 }
    var isPartiallyPaid: Bool { amountPaid > 0 && !isPaid }
    var isOverdue: Bool { !isPaid && status == .sent && dueDate < .now }

    /// Status as shown to the user — surfaces Paid / Partially Paid / Overdue automatically.
    var displayStatus: String {
        if isPaid { return String(localized: "Paid") }
        if isOverdue { return String(localized: "Overdue") }
        if isPartiallyPaid { return String(localized: "Partially Paid") }
        return status.label
    }

    static func nextNumber(after existing: [Invoice]) -> String {
        let highest = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "INV-", with: "")) }
            .max() ?? 0
        return String(format: "INV-%04d", highest + 1)
    }

    /// Builds an invoice from an estimate: copies the frozen snapshot, line items, and
    /// tax/discount, records the estimate's deposit as an initial payment, and links the
    /// originating estimate number. The new invoice and its children are inserted into `context`.
    @MainActor
    static func make(from estimate: Estimate, number: String, in context: ModelContext) -> Invoice {
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
        invoice.discountType = estimate.discountType
        invoice.discountValue = estimate.discountValue
        invoice.customerNotes = estimate.customerNotes
        invoice.terms = estimate.terms
        invoice.sourceEstimateNumber = estimate.number
        context.insert(invoice)

        for group in estimate.sortedGroups {
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
                    sortIndex: item.sortIndex
                )
                invoiceItem.group = invoiceGroup
                context.insert(invoiceItem)
            }
        }

        // If the estimate had a deposit, request it as the amount due now (not yet paid) — it's
        // collected later and logged as a payment.
        if estimate.depositAmount > 0 {
            invoice.amountDueNow = estimate.depositAmount
            invoice.amountDueDetail = "Deposit to start"
        }

        return invoice
    }
}

// MARK: - Group

@Model
final class InvoiceGroup {
    var name: String = ""
    var note: String = ""
    var sortIndex: Int = 0

    var invoice: Invoice?

    @Relationship(deleteRule: .cascade, inverse: \InvoiceLineItem.group)
    var lineItems: [InvoiceLineItem]?

    init(name: String = "", note: String = "", sortIndex: Int = 0) {
        self.name = name
        self.note = note
        self.sortIndex = sortIndex
    }

    var sortedLineItems: [InvoiceLineItem] {
        (lineItems ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var subtotal: Double {
        (lineItems ?? []).reduce(0) { $0 + $1.lineTotal }
    }
}

// MARK: - Line item

@Model
final class InvoiceLineItem {
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.squareFoot
    var unitPrice: Double = 0
    var kind: LineItemKind = LineItemKind.labor
    var isTaxable: Bool = false
    var sortIndex: Int = 0

    var group: InvoiceGroup?

    init(
        name: String = "",
        details: String = "",
        quantity: Double = 1,
        unit: UnitOfMeasure = .squareFoot,
        unitPrice: Double = 0,
        kind: LineItemKind = .labor,
        isTaxable: Bool = false,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.details = details
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.kind = kind
        self.isTaxable = isTaxable
        self.sortIndex = sortIndex
    }

    var lineTotal: Double {
        quantity * unitPrice
    }
}

// MARK: - Payment

@Model
final class InvoicePayment {
    var amount: Double = 0
    var date: Date = Date.now
    var method: PaymentMethod = PaymentMethod.other
    var note: String = ""

    var invoice: Invoice?

    init(amount: Double = 0, date: Date = .now, method: PaymentMethod = .other, note: String = "") {
        self.amount = amount
        self.date = date
        self.method = method
        self.note = note
    }
}
