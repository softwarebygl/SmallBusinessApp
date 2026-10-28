//
//  Customer.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import Foundation
import SwiftData

@Model
final class Customer {

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
    var firstName: String = ""
    var middleName: String = ""
    var lastName: String = ""
    var email: String = ""
    /// Primary phone (mobile) — used as the text-message recipient.
    var phoneNumber: String = ""
    /// Optional office / landline number — informational; not used for texting.
    var officePhone: String = ""
    var businessName: String?
    /// ⚠️ DORMANT-LEGACY, WRITE-FORBIDDEN (2026-09-01, the build-62 SIGTRAP — same class
    /// as UserProfile.address, build 48). A history UPDATE row naming a composite
    /// sub-attribute whose keypath crosses ANY Optional (`Address.street2: String?`)
    /// fatals uncatchably inside `fetchHistory`. Kept only so old stores keep opening;
    /// `AddressFlatsBackfill` forward-copies it once at mount. Swift-renamed so the
    /// public name stays on the flats façade; `originalName` pins the stored column.
    /// Nothing may ever assign it — reads are safe, writes poison history.
    @Attribute(originalName: "address") var legacyAddress: Address = Address()
    /// The flattened columns behind the `address` façade (the write path since
    /// 2026-09-01). Primitive strings, so their history rows always resolve.
    var addressStreet1: String = ""
    var addressStreet2: String = ""
    var addressCity: String = ""
    var addressState: String = ""
    var addressPostalCode: String = ""

    /// Dedicated Service Address for the customer (Ruling 4).
    /// When `sameAsBillingAddress` is true, reads fall back to `address` (billing).
    var sameAsBillingAddress: Bool = true
    var serviceAddressStreet1: String = ""
    var serviceAddressStreet2: String = ""
    var serviceAddressCity: String = ""
    var serviceAddressState: String = ""
    var serviceAddressPostalCode: String = ""

    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var profileImageData: Data?

    /// This customer's own Certificate of Liability Insurance (the General Liability certificate),
    /// issued by the insurer with the customer named as the certificate holder. A COI is specific to
    /// its holder, so it can't be reused across customers — each customer gets their own, uploaded
    /// here and sent as-is (never modified) in that customer's Contractor Package. PDF or image.
    @Attribute(.externalStorage) var coiData: Data?
    var coiName: String = ""

    /// This customer's Workers' Comp Certificate of Insurance. Like the General Liability COI above,
    /// insurers issue it with the certificate holder named, so it can't be reused across customers —
    /// uploaded here and sent as-is (never modified) in that customer's Contractor Package. PDF or
    /// image. Distinct from the state-issued workers' comp EXEMPTION, which is business-scoped and
    /// stays on `BusinessProfile.wcExemptionData`.
    @Attribute(.externalStorage) var wcCoiData: Data?
    var wcCoiName: String = ""

    /// When these certificates lapse. Added 2026-09-01. Before this, presence was the ONLY thing
    /// modelled — `hasCOI` is a bool — so a certificate that expired in March still showed a gold
    /// verified seal and still merged silently into an outgoing Contractor Package. The app was
    /// asserting "covered" about a document that gets a contractor thrown off a site. Optional:
    /// unknown for every existing row, and the owner may not have the date to hand.
    var coiExpiresOn: Date?
    var wcCoiExpiresOn: Date?

    /// Additional documents this customer (usually a GC) asked to have in their Contractor Package,
    /// beyond the standard COI + W-9 + workers'-comp + license — an OSHA card, a signed vendor
    /// agreement, a bonding letter, … Uploaded on the Contractor Package screen. Cascade: they were
    /// added for this customer's package and mean nothing without them.
    @Relationship(deleteRule: .cascade, inverse: \CustomerDocument.customer)
    var packageDocuments: [CustomerDocument]?

    @Relationship(deleteRule: .cascade, inverse: \Estimate.customer)
    var estimates: [Estimate]?

    @Relationship(deleteRule: .cascade, inverse: \Invoice.customer)
    var invoices: [Invoice]?

    @Relationship(deleteRule: .cascade, inverse: \Receipt.customer)
    var receipts: [Receipt]?

    /// Contracts for this customer (replaces jobs at root).
    @Relationship(deleteRule: .cascade, inverse: \Contract.customer)
    var contracts: [Contract]?

    /// Employee hours tagged to this customer/job (for labor-cost-per-job). Nullify, not cascade:
    /// removing a customer must not erase an employee's logged hours — it just drops the job tag.
    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.customer)
    var timeEntries: [TimeEntry]?

    /// Subcontractor payments tagged to this customer/job (cost-per-job including subs). Nullify so
    /// removing a customer drops the tag but keeps the payment record.
    @Relationship(deleteRule: .nullify, inverse: \SubPayment.customer)
    var subPayments: [SubPayment]?

    /// Jobs scheduled for this customer. Nullify so deleting a customer keeps the booking on the
    /// calendar via its `customerName` snapshot (matching the estimate/invoice frozen-snapshot convention).
    @Relationship(deleteRule: .nullify, inverse: \ScheduledJob.customer)
    var scheduledJobs: [ScheduledJob]?

    /// Projects grouping this customer's jobs. Nullify so deleting a customer keeps the project record.
    @Relationship(deleteRule: .nullify, inverse: \Project.customer)
    var projects: [Project]?

    init(
        firstName: String = "",
        middleName: String = "",
        lastName: String = "",
        email: String = "",
        phoneNumber: String = "",
        officePhone: String = "",
        businessName: String? = nil,
        address: Address = Address(),
        serviceAddress: Address? = nil,
        sameAsBillingAddress: Bool = true,
        createdAt: Date = .now
    ) {
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.email = email
        self.phoneNumber = phoneNumber
        self.officePhone = officePhone
        self.businessName = businessName
        self.address = address
        self.sameAsBillingAddress = sameAsBillingAddress
        if let serviceAddress {
            self.serviceAddress = serviceAddress
            self.sameAsBillingAddress = false
        }
        self.createdAt = createdAt
    }
}

extension Customer {
    /// Total unpaid balance across this customer's invoices — what they still owe you.
    var outstanding: Double { DomainMoney.roundedSum(liveRows(invoices).map(\.balanceDue)) }
    /// Total this customer has actually paid you across all their invoices.
    var totalPaidToUs: Double { DomainMoney.roundedSum(liveRows(invoices).map(\.amountPaid)) }
    /// True when deleting this customer would cascade a recorded payment away: one of their
    /// invoices holds a payment, paid in full or not. Payments are append-only (law 60), so such a
    /// customer can't be deleted (`DeletionService`, and the server's `has_payments`).
    var hasInvoiceWithPayments: Bool { liveRows(invoices).contains(where: \.hasRecordedPayments) }

    /// This customer's package extras, oldest first — the order they're merged into the
    /// Contractor Package.
    var sortedPackageDocuments: [CustomerDocument] {
        liveRows(packageDocuments).sorted { $0.createdAt < $1.createdAt }
    }
}

nonisolated extension Customer {
    /// True once a Certificate of Insurance has been uploaded for this customer — the one document
    /// the Contractor Package can't be assembled without.
    var hasCOI: Bool { coiData != nil }

    /// A certificate is only good until its expiry date. `nil` expiry = unknown, which is NOT the
    /// same as expired — the app must not accuse a document it was never told about.
    var coiIsExpired: Bool { GLCertificateStatus.isExpired(coiExpiresOn) }
    var wcCoiIsExpired: Bool { GLCertificateStatus.isExpired(wcCoiExpiresOn) }

    /// True once this customer's Workers' Comp certificate has been uploaded. Optional — unlike the
    /// General Liability COI it never gates the package.
    var hasWCCOI: Bool { wcCoiData != nil }

    /// The person's full name, "First Middle Last", trimmed; empty parts dropped.
    var fullName: String {
        [firstName, middleName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @MainActor
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = (businessName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return mbLoc("No name")
    }

    var initials: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines).first
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines).first
        let combined = [first, last].compactMap { $0 }.map(String.init).joined().uppercased()
        if !combined.isEmpty { return combined }
        if let business = businessName?.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(business).uppercased()
        }
        return "?"
    }
}

nonisolated struct Address: Codable, Hashable, Sendable {
    var street1: String
    var street2: String?
    var city: String
    var state: String
    var postalCode: String

    init(
        street1: String = "",
        street2: String? = nil,
        city: String = "",
        state: String = "",
        postalCode: String = ""
    ) {
        self.street1 = street1
        self.street2 = street2
        self.city = city
        self.state = state
        self.postalCode = postalCode
    }
}

extension Address {
    /// True when every field is blank, so callers can skip showing an empty address.
    var isEmpty: Bool {
        [street1, street2 ?? "", city, state, postalCode]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Multi-line "street / street2 / City, ST ZIP" with any empty parts omitted.
    var formattedMultiline: String {
        let cityLine = [city, state]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let cityZip = [cityLine, postalCode.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [street1, street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Single line "street, street2, City, ST ZIP" for mapping URLs.
    var singleLine: String {
        let cityLine = [city, state]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let cityZip = [cityLine, postalCode.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [street1, street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

extension Customer {
    /// THE one door to `address`. Reads see the flat columns only; writes go to flats
    /// only — the legacy composite is write-forbidden (see its doc). Empty street2
    /// normalizes to nil, which renders identically.
    var address: Address {
        get {
            Address(street1: addressStreet1,
                    street2: addressStreet2.isEmpty ? nil : addressStreet2,
                    city: addressCity,
                    state: addressState,
                    postalCode: addressPostalCode)
        }
        set {
            addressStreet1 = newValue.street1
            addressStreet2 = newValue.street2 ?? ""
            addressCity = newValue.city
            addressState = newValue.state
            addressPostalCode = newValue.postalCode
        }
    }

    /// Dedicated service address for customer. If `sameAsBillingAddress` is true, returns billing `address`.
    var serviceAddress: Address {
        get {
            if sameAsBillingAddress { return address }
            return Address(
                street1: serviceAddressStreet1,
                street2: serviceAddressStreet2.isEmpty ? nil : serviceAddressStreet2,
                city: serviceAddressCity,
                state: serviceAddressState,
                postalCode: serviceAddressPostalCode
            )
        }
        set {
            serviceAddressStreet1 = newValue.street1
            serviceAddressStreet2 = newValue.street2 ?? ""
            serviceAddressCity = newValue.city
            serviceAddressState = newValue.state
            serviceAddressPostalCode = newValue.postalCode
        }
    }

    /// The stored service address flats as an Address (independent of `sameAsBillingAddress`).
    var rawServiceAddress: Address {
        Address(
            street1: serviceAddressStreet1,
            street2: serviceAddressStreet2.isEmpty ? nil : serviceAddressStreet2,
            city: serviceAddressCity,
            state: serviceAddressState,
            postalCode: serviceAddressPostalCode
        )
    }
}

