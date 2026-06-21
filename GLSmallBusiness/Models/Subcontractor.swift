//
//  Subcontractor.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Subcontractors are 1099 trades you pay per job (no hours, no payday schedule — that's what sets
//  them apart from W-2 Employees). This file is the tracking foundation: the sub record, the payments
//  you make them, year-to-date totals, and the $600 1099-NEC threshold flag.
//
//  NEXT ROUND (the tax-document layer): each sub's W-9 details + TIN (Keychain, like the business
//  TIN — SecureTINStore generalized per-sub), an uploaded W-9 PDF, and generating the real IRS
//  1099-NEC (Copy B for the sub, Copy C for records) the same way the W-9 is filled. The accountant
//  CSV handoff below already covers the actual filing.
//

import Foundation
import SwiftData

// MARK: - Subcontractor

@Model
final class Subcontractor {
    var firstName: String = ""
    var lastName: String = ""
    /// Subs are often businesses; this is the name that appears as the 1099 payee when set.
    var businessName: String = ""
    var email: String = ""
    var phone: String = ""
    var address: Address = Address()
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \SubPayment.subcontractor)
    var payments: [SubPayment]?

    init(
        firstName: String = "",
        lastName: String = "",
        businessName: String = "",
        email: String = "",
        phone: String = "",
        address: Address = Address(),
        isActive: Bool = true,
        notes: String = ""
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.businessName = businessName
        self.email = email
        self.phone = phone
        self.address = address
        self.isActive = isActive
        self.notes = notes
    }
}

// MARK: - Payment to a subcontractor

@Model
final class SubPayment {
    var amount: Double = 0
    var date: Date = Date.now
    var method: PaymentMethod = PaymentMethod.check
    /// What the payment was for (e.g. "Backsplash install — Reed job").
    var detail: String = ""

    var subcontractor: Subcontractor?
    /// Optional job tag: the customer/job this work was for (enables cost-per-job including subs).
    /// Nullified if the customer is removed, so the payment record survives.
    var customer: Customer?

    init(amount: Double = 0, date: Date = .now, method: PaymentMethod = .check,
         detail: String = "", subcontractor: Subcontractor? = nil, customer: Customer? = nil) {
        self.amount = amount
        self.date = date
        self.method = method
        self.detail = detail
        self.subcontractor = subcontractor
        self.customer = customer
    }
}

// MARK: - Display + 1099 math

nonisolated extension Subcontractor {
    /// IRS reporting threshold: a 1099-NEC is required once you pay a sub $600+ in a calendar year.
    static let form1099Threshold: Double = 600

    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Last, First", falling back to the business name, then a placeholder — like Customer.
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return String(localized: "No name")
    }

    /// The name that appears as the 1099 payee: the business name when set, otherwise the person.
    var payeeName: String {
        let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        return business.isEmpty ? fullName : business
    }

    var initials: String {
        let parts = [firstName, lastName].compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).first
        }
        let combined = parts.map(String.init).joined().uppercased()
        if !combined.isEmpty { return combined }
        if let b = businessName.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(b).uppercased()
        }
        return "?"
    }

    var sortedPayments: [SubPayment] {
        (payments ?? []).sorted { $0.date > $1.date }
    }

    func totalPaid(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        (payments ?? [])
            .filter { Calendar.current.component(.year, from: $0.date) == year }
            .reduce(0) { $0 + $1.amount }
    }

    /// All-time total paid (across every year).
    var lifetimePaid: Double {
        (payments ?? []).reduce(0) { $0 + $1.amount }
    }

    /// True once year-to-date pay reaches the $600 1099-NEC threshold.
    func requires1099(year: Int = Calendar.current.component(.year, from: .now)) -> Bool {
        totalPaid(year: year) >= Subcontractor.form1099Threshold
    }
}

// MARK: - Year roll-up (across subcontractors)

/// Totals shown in the Subcontractors tab header: how much went out this year and how many subs
/// have crossed the $600 1099 threshold. Used on both iPhone and iPad.
nonisolated enum Subcontractor1099Summary {
    struct YearTotals {
        let totalPaid: Double
        let count1099: Int
    }

    static func forYear(_ subs: [Subcontractor],
                        year: Int = Calendar.current.component(.year, from: .now)) -> YearTotals {
        let totalPaid = subs.reduce(0) { $0 + $1.totalPaid(year: year) }
        let count1099 = subs.filter { $0.requires1099(year: year) }.count
        return YearTotals(totalPaid: totalPaid, count1099: count1099)
    }
}
