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
    /// Optional default pay rate, so an amount can be logged as "hours × rate". 0 = no rate set.
    var hourlyRate: Double = 0
    var address: Address = Address()
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date.now

    // W-9 / tax details (for issuing a 1099-NEC). The TIN itself is NOT stored here — it lives in
    // the Keychain (SecureTINStore), keyed by `tinKey`, exactly like the business TIN. `w9TINTypeRaw`
    // backs the `w9TINType` enum (raw String keeps CloudKit happy). `w9Data` is their uploaded W-9 PDF.
    var tinKey: String = ""
    var w9TINTypeRaw: String?
    @Attribute(.externalStorage) var w9Data: Data?
    var w9Name: String = ""

    @Relationship(deleteRule: .cascade, inverse: \SubPayment.subcontractor)
    var payments: [SubPayment]?

    init(
        firstName: String = "",
        lastName: String = "",
        businessName: String = "",
        email: String = "",
        phone: String = "",
        hourlyRate: Double = 0,
        address: Address = Address(),
        isActive: Bool = true,
        notes: String = ""
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.businessName = businessName
        self.email = email
        self.phone = phone
        self.hourlyRate = hourlyRate
        self.address = address
        self.isActive = isActive
        self.notes = notes
    }
}

// MARK: - Subcontractor ledger entry (what you owe a sub, and what you've paid)

/// One line in a subcontractor's ledger. `paidDate == nil` means it's **owed** (unpaid); once you
/// pay it, `paidDate` is set and it counts toward the 1099 (which is cash-basis — money actually paid).
@Model
final class SubPayment {
    var amount: Double = 0
    /// Hours behind the amount when logged as "hours × rate"; 0 for a flat amount.
    var hours: Double = 0
    /// When the work was done / the obligation was incurred.
    var date: Date = Date.now
    /// When it was actually paid. nil = still owed.
    var paidDate: Date?
    var method: PaymentMethod = PaymentMethod.check
    /// What it was for (e.g. "Backsplash install — Reed job").
    var detail: String = ""

    var subcontractor: Subcontractor?
    /// Optional job tag: the customer/job this work was for (enables cost-per-job including subs).
    /// Nullified if the customer is removed, so the record survives.
    var customer: Customer?

    init(amount: Double = 0, hours: Double = 0, date: Date = .now, paidDate: Date? = nil,
         method: PaymentMethod = .check, detail: String = "",
         subcontractor: Subcontractor? = nil, customer: Customer? = nil) {
        self.amount = amount
        self.hours = hours
        self.date = date
        self.paidDate = paidDate
        self.method = method
        self.detail = detail
        self.subcontractor = subcontractor
        self.customer = customer
    }

    /// Paid once a payment date is recorded; otherwise it's still owed.
    var isPaid: Bool { paidDate != nil }
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

    /// Amount owed but not yet paid (the sum of unpaid ledger entries).
    var outstanding: Double {
        (payments ?? []).filter { !$0.isPaid }.reduce(0) { $0 + $1.amount }
    }
    var hasOutstanding: Bool { outstanding > 0.005 }

    /// Amount actually PAID in `year` (by payment date) — the 1099-NEC figure (cash basis). Unpaid
    /// "owed" entries do not count until they're paid.
    func totalPaid(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        (payments ?? [])
            .filter { $0.isPaid && Calendar.current.component(.year, from: $0.paidDate ?? $0.date) == year }
            .reduce(0) { $0 + $1.amount }
    }

    /// All-time total actually paid (across every year).
    var lifetimePaid: Double {
        (payments ?? []).filter(\.isPaid).reduce(0) { $0 + $1.amount }
    }

    /// True once year-to-date pay reaches the $600 1099-NEC threshold.
    func requires1099(year: Int = Calendar.current.component(.year, from: .now)) -> Bool {
        totalPaid(year: year) >= Subcontractor.form1099Threshold
    }
}

// MARK: - W-9 / TIN (Keychain-backed, like the business TIN)

nonisolated extension Subcontractor {
    /// SSN/EIN type for the TIN, backed by the raw string so CloudKit stays happy.
    var w9TINType: W9TINType? {
        get { w9TINTypeRaw.flatMap(W9TINType.init(rawValue:)) }
        set { w9TINTypeRaw = newValue?.rawValue }
    }

    private var tinAccount: String { SecureTINStore.subcontractorAccount(tinKey) }

    /// The sub's taxpayer ID read from the Keychain (never the synced store), or "" if none.
    var secureTIN: String { tinKey.isEmpty ? "" : SecureTINStore.read(account: tinAccount) }

    var hasTIN: Bool { !secureTIN.isEmpty }
    var hasW9OnFile: Bool { w9Data != nil }

    /// Last four of the TIN for display, e.g. "•••• 1234"; empty when none on file.
    var maskedTIN: String {
        let digits = secureTIN.filter(\.isNumber)
        return digits.count >= 4 ? "•••• " + String(digits.suffix(4)) : ""
    }

    /// Stores (or clears) the sub's TIN in the Keychain, assigning a stable `tinKey` on first write.
    /// Returns false if the secure write failed, so the caller can tell the user it wasn't saved.
    @discardableResult
    func updateTIN(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if tinKey.isEmpty {
            guard !trimmed.isEmpty else { return true }   // nothing to store yet — don't allocate a key
            tinKey = UUID().uuidString
        }
        return SecureTINStore.write(trimmed, account: tinAccount)
    }

    /// Removes the Keychain TIN — call before deleting a sub so its TIN doesn't linger in the Keychain.
    func clearSecureTIN() {
        guard !tinKey.isEmpty else { return }
        SecureTINStore.write("", account: tinAccount)
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
