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
    var firstName: String = ""
    var middleName: String = ""
    var lastName: String = ""
    var email: String = ""
    /// Primary phone (mobile) — used as the text-message recipient.
    var phoneNumber: String = ""
    /// Optional office / landline number — informational; not used for texting.
    var officePhone: String = ""
    var businessName: String?
    var address: Address = Address()
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var profileImageData: Data?

    /// This customer's own Certificate of Liability Insurance (the General Liability certificate),
    /// issued by the insurer with the customer named as the certificate holder. A COI is specific to
    /// its holder, so it can't be reused across customers — each customer gets their own, uploaded
    /// here and sent as-is (never modified) in that customer's Contractor Package. PDF or image.
    @Attribute(.externalStorage) var coiData: Data?
    var coiName: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Estimate.customer)
    var estimates: [Estimate]?

    @Relationship(deleteRule: .cascade, inverse: \Invoice.customer)
    var invoices: [Invoice]?

    @Relationship(deleteRule: .cascade, inverse: \Receipt.customer)
    var receipts: [Receipt]?

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

    init(
        firstName: String = "",
        middleName: String = "",
        lastName: String = "",
        email: String = "",
        phoneNumber: String = "",
        officePhone: String = "",
        businessName: String? = nil,
        address: Address = Address(),
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
        self.createdAt = createdAt
    }
}

nonisolated extension Customer {
    /// True once a Certificate of Insurance has been uploaded for this customer — the one document
    /// the Contractor Package can't be assembled without.
    var hasCOI: Bool { coiData != nil }

    /// The person's full name, "First Middle Last", trimmed; empty parts dropped.
    var fullName: String {
        [firstName, middleName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = (businessName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return String(localized: "No name")
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
}
