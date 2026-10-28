//
//  Contract.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  A Contract is the core hub for contract signing, change orders, invoicing,
//  and schedule dates. It links back to an originating estimate or can be created
//  from scratch, holds its own line-item groups and change orders, and acts as
//  the source for progress/draw invoicing.
//

import Foundation
import SwiftData
@_exported import GoldLifeDocuments

// MARK: - Contract Status

nonisolated enum ContractStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft
    case signed
    case inProgress
    case completed

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .draft: mbLoc("Draft")
        case .signed: mbLoc("Signed")
        case .inProgress: mbLoc("In Progress")
        case .completed: mbLoc("Completed")
        }
    }
}

// MARK: - Contract

@Model
final class Contract {

    // MARK: Sync identity
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    var updatedAt: Date?

    var number: String = ""
    var title: String = ""
    var customerName: String = ""
    var customerEmail: String = ""
    var customerPhone: String = ""

    // Scheduling
    var startDate: Date = Date.now
    var durationDays: Int = 1
    var isAllDay: Bool = true
    var startTime: Date?
    var durationMinutes: Int?

    var notes: String = ""
    var terms: String = ""
    var createdAt: Date = Date.now
    var statusRaw: String = ContractStatus.draft.rawValue
    var completedAt: Date?

    // Signature
    var signedAt: Date?
    var signerName: String = ""
    @Attribute(.externalStorage) var signatureData: Data?

    // Service Address
    var serviceAddressStreet1: String = ""
    var serviceAddressStreet2: String = ""
    var serviceAddressCity: String = ""
    var serviceAddressState: String = ""
    var serviceAddressPostalCode: String = ""

    // Billing / Agreed Price
    var agreedPrice: Double?
    var taxRatePercent: Double = 0
    var changeOrderNumberSeed: Int = 0

    // Relationships
    var customer: Customer?
    var estimate: Estimate?
    var scheduledJob: ScheduledJob?

    @Relationship(deleteRule: .cascade, inverse: \ContractGroup.contract)
    var groups: [ContractGroup]?

    @Relationship(deleteRule: .cascade, inverse: \ChangeOrder.contract)
    var changeOrders: [ChangeOrder]?

    @Relationship(deleteRule: .nullify, inverse: \Invoice.contract)
    var billingInvoices: [Invoice]?

    @Relationship(deleteRule: .nullify, inverse: \Receipt.contract)
    var receipts: [Receipt]?

    @Relationship(deleteRule: .cascade, inverse: \JobAttachment.contract)
    var attachments: [JobAttachment]?

    init(
        number: String = "",
        title: String = "",
        customerName: String = "",
        customerEmail: String = "",
        customerPhone: String = "",
        startDate: Date = .now,
        durationDays: Int = 1,
        isAllDay: Bool = true,
        startTime: Date? = nil,
        durationMinutes: Int? = nil,
        notes: String = "",
        terms: String = "",
        serviceAddress: Address = Address(),
        agreedPrice: Double? = nil,
        status: ContractStatus = .draft,
        customer: Customer? = nil,
        estimate: Estimate? = nil
    ) {
        self.number = number
        self.title = title
        self.customerName = customerName
        self.customerEmail = customerEmail
        self.customerPhone = customerPhone
        self.startDate = startDate
        self.durationDays = max(1, durationDays)
        self.isAllDay = isAllDay
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.notes = notes
        self.terms = terms
        self.serviceAddress = serviceAddress
        self.agreedPrice = agreedPrice
        self.statusRaw = status.rawValue
        self.customer = customer
        self.estimate = estimate
        self.createdAt = .now

        if let customer {
            if self.customerName.isEmpty {
                let name = customer.fullName
                self.customerName = name.isEmpty ? (customer.businessName ?? "") : name
            }
            if self.customerEmail.isEmpty {
                self.customerEmail = customer.email
            }
            if self.customerPhone.isEmpty {
                self.customerPhone = customer.phoneNumber
            }
        }

        if self.serviceAddress.isEmpty {
            if let est = estimate, !est.serviceAddress.isEmpty {
                self.serviceAddress = est.serviceAddress
            } else if let customer {
                self.serviceAddress = customer.serviceAddress
            }
        }
    }
}

// MARK: - Contract Computed Values

extension Contract {
    var status: ContractStatus {
        get { ContractStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var hasPhysicalSignature: Bool {
        signatureData != nil && signedAt != nil
    }

    var isSigned: Bool {
        hasPhysicalSignature || status == .signed || status == .inProgress || status == .completed
    }

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

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Contract" : t
    }

    var displayCustomerName: String {
        if let live = customer {
            let name = live.fullName
            if !name.isEmpty { return name }
            if let b = live.businessName, !b.isEmpty { return b }
        }
        let snapshot = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.isEmpty ? "Customer" : snapshot
    }

    var recipientEmail: String {
        let live = (customer?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerEmail : live
    }

    var recipientPhone: String {
        let live = (customer?.phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? customerPhone : live
    }

    var sortedGroups: [ContractGroup] {
        liveRows(groups).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allLineItems: [ContractLineItem] {
        sortedGroups.flatMap { $0.sortedLineItems }
    }

    var sortedAttachments: [JobAttachment] {
        liveRows(attachments).sorted { $0.createdAt > $1.createdAt }
    }

    var sortedChangeOrders: [ChangeOrder] {
        liveRows(changeOrders).sorted { $0.createdAt < $1.createdAt }
    }

    var approvedChangeOrders: [ChangeOrder] {
        sortedChangeOrders.filter { $0.status == .approved }
    }

    var activeBillingInvoices: [Invoice] {
        liveRows(billingInvoices).filter { $0.status != .draft }
    }

    var invoicedTotal: Double {
        DomainMoney.roundedSum(activeBillingInvoices.map(\.total))
    }

    var amountPaid: Double {
        DomainMoney.roundedSum(activeBillingInvoices.map(\.amountPaid))
    }

    var balanceDue: Double {
        DomainMoney.roundedSum(activeBillingInvoices.map(\.balanceDue))
    }

    var contractedValue: Double {
        if let price = agreedPrice, price >= 0 {
            let coTotal = DomainMoney.roundedSum(approvedChangeOrders.map(\.total))
            return DomainMoney.roundedToCents(price + coTotal)
        }
        let linesTotal = allLineItems.reduce(0.0) { $0 + $1.total }
        let coTotal = DomainMoney.roundedSum(approvedChangeOrders.map(\.total))
        let base = linesTotal > 0 ? linesTotal : (estimate?.total ?? invoicedTotal)
        return DomainMoney.roundedToCents(base + coTotal)
    }

    var remainingToInvoice: Double {
        DomainMoney.remaining(contractedValue, less: invoicedTotal)
    }

    static func nextNumber(after existing: [Contract], profile: BusinessProfile? = nil) -> String {
        let computed = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "CON-", with: "")) }
            .max() ?? 0
        let next = computed + 1
        return String(format: "CON-%04d", next)
    }
}

// MARK: - Contract Group

@Model
final class ContractGroup {
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    var updatedAt: Date?
    var name: String = ""
    var note: String = ""
    var sortIndex: Int = 0

    var contract: Contract?

    @Relationship(deleteRule: .cascade, inverse: \ContractLineItem.group)
    var lineItems: [ContractLineItem]?

    init(name: String = "", note: String = "", sortIndex: Int = 0) {
        self.name = name
        self.note = note
        self.sortIndex = sortIndex
    }

    var sortedLineItems: [ContractLineItem] {
        liveRows(lineItems).sorted { $0.sortIndex < $1.sortIndex }
    }

    var subtotal: Double {
        DomainMoney.roundedToCents(liveRows(lineItems).reduce(Decimal(0)) { $0 + $1.exactLineTotal })
    }
}

// MARK: - Contract Line Item

@Model
final class ContractLineItem {
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    var updatedAt: Date?
    var name: String = ""
    var details: String = ""
    var quantity: Double = 1
    var unit: UnitOfMeasure = UnitOfMeasure.squareFoot
    var unitPrice: Double = 0
    var kind: LineItemKind = LineItemKind.labor
    var isTaxable: Bool = false
    var sortIndex: Int = 0
    var fromChangeOrder: Bool = false

    var group: ContractGroup?

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

    var exactLineTotal: Decimal {
        Decimal(quantity) * Decimal(unitPrice)
    }

    var total: Double {
        DomainMoney.roundedToCents(exactLineTotal)
    }
}
