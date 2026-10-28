//
//  Estimate.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData
@_exported import GoldLifeDocuments

// MARK: - Enums
// Marked `nonisolated` so their Codable conformances aren't main-actor isolated,
// which SwiftData requires to encode them from its nonisolated storage code.

nonisolated enum EstimateStatus: String, Codable, CaseIterable, Identifiable {
    case draft, sent, accepted, declined

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .draft: mbLoc("Draft")
        case .sent: mbLoc("Sent")
        case .accepted: mbLoc("Accepted")
        case .declined: mbLoc("Declined")
        }
    }

    var documentStatus: GLDocumentStatus {
        switch self {
        case .draft, .sent: return .pending
        case .accepted: return .approved
        case .declined: return .declined
        }
    }

    static func from(documentStatus: GLDocumentStatus, wasSent: Bool = false) -> EstimateStatus {
        switch documentStatus {
        case .pending: return wasSent ? .sent : .draft
        case .approved: return .accepted
        case .declined: return .declined
        case .awaitingSignature, .signed: return .accepted
        case .unpaid, .partiallyPaid, .paid: return .accepted
        }
    }

    init(_ documentStatus: GLDocumentStatus, wasSent: Bool = false) {
        self = Self.from(documentStatus: documentStatus, wasSent: wasSent)
    }
}

public typealias LineItemKind = GoldLifeDocuments.LineItemKind
public typealias UnitOfMeasure = GoldLifeDocuments.UnitOfMeasure
public typealias AdjustmentType = GoldLifeDocuments.AdjustmentType
public typealias LineDiscount = GoldLifeDocuments.LineDiscount
public typealias LineMoney = GoldLifeDocuments.LineMoney

extension LineItemKind {
    @MainActor
    var label: String {
        switch self {
        case .labor: mbLoc("Labor")
        case .material: mbLoc("Material")
        }
    }
}

extension UnitOfMeasure {
    @MainActor
    var abbreviation: String {
        switch self {
        case .squareFoot: mbLoc("sq ft")
        case .linearFoot: mbLoc("ln ft")
        case .squareYard: mbLoc("sq yd")
        case .hour: mbLoc("hr")
        case .day: mbLoc("day")
        case .each: mbLoc("ea")
        case .item: mbLoc("item")
        case .labor: mbLoc("labor")
        case .lumpSum: mbLoc("lump")
        case .job: mbLoc("job")
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .squareFoot: mbLoc("Square feet")
        case .linearFoot: mbLoc("Linear feet")
        case .squareYard: mbLoc("Square yards")
        case .hour: mbLoc("Hours")
        case .day: mbLoc("Days")
        case .each: mbLoc("Each")
        case .item: mbLoc("Item")
        case .labor: mbLoc("Labor")
        case .lumpSum: mbLoc("Lump sum")
        case .job: mbLoc("Job")
        }
    }
}

extension AdjustmentType {
    @MainActor
    var label: String {
        switch self {
        case .none: mbLoc("None")
        case .percentage: mbLoc("Percentage")
        case .fixed: mbLoc("Fixed amount")
        }
    }
}

// MARK: - Money math is shared via GLDocumentTotals from GoldLifeDocuments


// MARK: - Estimate

@Model
final class Estimate {

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
    var validUntil: Date = Date.now
    var status: EstimateStatus = EstimateStatus.draft

    // Customer snapshot — frozen at creation. Editing the Customer never changes this.
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

    /// The job site / lot this estimate is for. Independent of the customer's (billing) address,
    /// so a GC's office stays put while each estimate can point at a different property.
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

    // Link back to the originating customer (for grouping/filtering only).
    var customer: Customer?

    // Financials
    /// ON (default): the classic estimate — every group tallies into one grand
    /// total. OFF: an OPTIONS estimate — each group is a standalone choice with
    /// its own subtotal/tax/total, the combined tally disappears, and converting
    /// to an invoice asks which option(s) the customer chose (owner feature
    /// 2026-09-01, "send a ledger of options instead of multiple estimates").
    /// Estimate-level discount and deposit are ignored while OFF — they only
    /// make sense against one agreed scope, which options mode doesn't have yet.
    var combineTotals: Bool = true

    var taxRatePercent: Double = 0
    var discountType: AdjustmentType = AdjustmentType.none
    var discountValue: Double = 0
    var depositType: AdjustmentType = AdjustmentType.none
    var depositValue: Double = 0

    // Content
    var customerNotes: String = ""
    var terms: String = ""

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \EstimateGroup.estimate)
    var groups: [EstimateGroup]?

    /// Calendar bookings made from this estimate. Nullify so deleting the estimate keeps the booking
    /// (it still carries its title/customer snapshot) rather than wiping it off the calendar.
    @Relationship(deleteRule: .nullify, inverse: \ScheduledJob.estimate)
    var scheduledJobs: [ScheduledJob]?

    init(
        number: String = "",
        jobTitle: String = "",
        createdAt: Date = .now,
        validUntil: Date? = nil,
        status: EstimateStatus = .draft,
        customer: Customer? = nil
    ) {
        self.number = number
        self.jobTitle = jobTitle
        self.createdAt = createdAt
        self.validUntil = validUntil ?? createdAt.addingTimeInterval(30 * 24 * 60 * 60)
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

// MARK: - Estimate computed values

extension Estimate {
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

    var sortedGroups: [EstimateGroup] {
        liveRows(groups).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allLineItems: [EstimateLineItem] {
        sortedGroups.flatMap { $0.sortedLineItems }
    }

    var totals: EstimateTotals {
        EstimateTotals(
            lines: allLineItems.map { ($0.exactLineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: discountType,
            discountValue: discountValue,
            depositType: depositType,
            depositValue: depositValue
        )
    }

    var subtotal: Double { totals.subtotal }
    var discountAmount: Double { totals.discount }
    var taxAmount: Double { totals.tax }
    var total: Double { totals.total }
    var depositAmount: Double { totals.deposit }

    var isOptionsMode: Bool { !combineTotals && liveRows(groups).count >= 2 }

    var isExpired: Bool {
        guard status != .accepted, status != .declined else { return false }
        // Valid through the WHOLE "valid until" day — compare against the start of the next day, so the
        // badge doesn't flip to "Expired" partway through the day the estimate says it's valid until.
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1,
                                             to: Calendar.current.startOfDay(for: validUntil)) ?? validUntil
        return endOfDay <= .now
    }

    /// Status as shown to the user — surfaces "Expired" when past the valid-until date.
    @MainActor
    var displayStatus: String {
        isExpired ? mbLoc("Expired") : status.label
    }

    /// The next estimate number. Seeded from the larger of the highest existing number and the profile's
    /// monotonic counter, then bumps the counter (so deleting the highest estimate doesn't reuse its
    /// number). Pass the business profile to enable the counter (nil = plain max+1, used in tests).
    static func nextNumber(after existing: [Estimate], profile: BusinessProfile? = nil) -> String {
        let computed = existing
            .compactMap { Int($0.number.replacingOccurrences(of: "EST-", with: "")) }
            .max() ?? 0
        let next = max(profile?.lastEstimateNumber ?? 0, computed) + 1
        profile?.lastEstimateNumber = next
        return String(format: "EST-%04d", next)
    }
}

// MARK: - Group

@Model
final class EstimateGroup {

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

    var estimate: Estimate?

    // CloudKit requires every relationship (including to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \EstimateLineItem.group)
    var lineItems: [EstimateLineItem]?

    init(name: String = "", note: String = "", sortIndex: Int = 0) {
        self.name = name
        self.note = note
        self.sortIndex = sortIndex
    }

    var sortedLineItems: [EstimateLineItem] {
        liveRows(lineItems).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The group's lines added up exactly, rounded once (law 60).
    var subtotal: Double {
        DomainMoney.roundedToCents(liveRows(lineItems).reduce(Decimal(0)) { $0 + $1.exactLineTotal })
    }

    /// This group priced as a STANDALONE OPTION at the estimate's tax rate —
    /// no estimate-level discount or deposit (see `Estimate.combineTotals`).
    func optionTotals(taxRatePercent: Double) -> EstimateTotals {
        EstimateTotals(
            lines: sortedLineItems.map { ($0.exactLineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: .none, discountValue: 0,
            depositType: .none, depositValue: 0
        )
    }
}

// MARK: - Line item

@Model
final class EstimateLineItem {

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
    /// Optional per-line discount, applied on top of any whole-estimate discount. Additive + defaulted,
    /// so it folds into V1 CloudKit-safely.
    var discountType: AdjustmentType = AdjustmentType.none
    var discountValue: Double = 0

    var group: EstimateGroup?

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
    /// Price after the per-line discount, rounded once — what the line shows.
    var lineTotal: Double { DomainMoney.roundedToCents(money.floored) }
    /// The same, exact — the figure that flows into the document subtotal and tax.
    var exactLineTotal: Decimal { money.floored }
}

extension Estimate {
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

extension Estimate {
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

// MARK: - Row Mapping (C30 / Law 87)

extension Estimate: GLDocumentRowMapping {
    public var documentSyncID: String { syncID?.uuidString ?? "" }
}

extension EstimateGroup: GLDocumentRowMapping {
    public var documentSyncID: String { syncID?.uuidString ?? "" }
}

extension EstimateLineItem: GLDocumentRowMapping {
    public var documentSyncID: String { syncID?.uuidString ?? "" }
}
