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
    var lastName: String = ""
    /// Subs are often businesses; this is the name that appears as the 1099 payee when set.
    var businessName: String = ""
    var email: String = ""
    var phone: String = ""
    /// Optional default pay rate, so an amount can be logged as "hours × rate". 0 = no rate set.
    var hourlyRate: Double = 0
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
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date.now
    /// Optional profile photo (stored outside the row, like Customer). Additive, V1.
    @Attribute(.externalStorage) var profileImageData: Data?

    // W-9 / tax details (for issuing a 1099-NEC). The TIN itself is NOT stored here — it lives in
    // the Keychain (SecureTINStore), keyed by `tinKey`, exactly like the business TIN. `w9TINTypeRaw`
    // backs the `w9TINType` enum (raw String keeps CloudKit happy). `w9Data` is their uploaded W-9 PDF.
    var tinKey: String = ""
    var w9TINTypeRaw: String?
    @Attribute(.externalStorage) var w9Data: Data?
    var w9Name: String = ""

    /// This subcontractor's own Certificate of Liability Insurance, uploaded here the same way a
    /// customer's is (`Customer.coiData`). Added 2026-09-01: subs carried tax fields ONLY, so the
    /// screen showed a W-9 card and nothing about insurance — while the customer screen right next
    /// to it has both, which had already taught the owner where to look. An uninsured sub is the
    /// liability a GC asks about, so this is the paperwork he most needs on file.
    ///
    /// FLAT scalars, defaulted/optional, no composite — GLSchema rules 1, 2 and 2c.
    @Attribute(.externalStorage) var coiData: Data?
    var coiName: String = ""
    /// When that certificate lapses. Optional because it is unknown for every row that predates
    /// this and for any certificate whose date the owner has not typed in.
    var coiExpiresOn: Date?

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
    /// IRS reporting threshold: a 1099-NEC is required once you pay a sub this much in a calendar year.
    /// $600 through tax year 2025; the One Big Beautiful Bill Act raises it to $2,000 for payments made
    /// in 2026 onward (indexed for inflation after — revisit when the IRS publishes adjusted figures).
    static func form1099Threshold(for year: Int) -> Double { year >= 2026 ? 2000 : 600 }

    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Last, First", falling back to the business name, then a placeholder — like Customer.
    @MainActor
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return mbLoc("No name")
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
        liveRows(payments).sorted { $0.date > $1.date }
    }

    /// Amount owed but not yet paid (the unpaid ledger entries added exactly, rounded once — law 60).
    var outstanding: Double {
        DomainMoney.roundedSum(liveRows(payments).filter { !$0.isPaid }.map(\.amount))
    }
    var hasOutstanding: Bool { outstanding > 0.005 }

    /// How the outstanding balance reads in a list row: nothing owed, owed only for future-dated
    /// (upcoming) work, or owed for work already incurred and not yet paid (past due).
    var owedStatus: OwedStatus {
        guard hasOutstanding else { return .none }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let anyPastDue = liveRows(payments).contains { !$0.isPaid && $0.amount > 0.005 && $0.date < startOfToday }
        return anyPastDue ? .pastDue : .upcoming
    }

    /// Amount actually PAID in `year` (by payment date, cash basis), every method. Unpaid "owed"
    /// entries do not count until they're paid. Box 1 of the 1099-NEC is `form1099NECAmount(year:)`.
    func totalPaid(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        DomainMoney.roundedSum(paidRows(year: year).map(\.amount))
    }

    /// All-time total actually paid (across every year).
    var lifetimePaid: Double {
        DomainMoney.roundedSum(liveRows(payments).filter(\.isPaid).map(\.amount))
    }

    /// Card and payment-app payments go on Form 1099-K, filed by the card processor or app, never on
    /// the 1099-NEC. IRS Instructions for Forms 1099-MISC and 1099-NEC (irs.gov/instructions/i1099mec,
    /// Reminders): payments made with a credit card or payment card, and third-party network
    /// transactions, "are not subject to reporting on Form 1099-MISC or Form 1099-NEC". Cash, check,
    /// bank transfer and Zelle (bank to bank, no payment app in between) and Other stay on the NEC.
    /// The switch is exhaustive on purpose: a new method has to be classified before it builds.
    static func isReportedOn1099K(_ method: PaymentMethod) -> Bool {
        switch method {
        case .card, .venmo, .cashApp, .appleCash, .paypal, .googlePay, .square, .stripe: true
        case .cash, .check, .transfer, .zelle, .other: false
        }
    }

    /// Paid entries whose payment date falls in `year`.
    private func paidRows(year: Int) -> [SubPayment] {
        liveRows(payments).filter { $0.isPaid && Calendar.current.component(.year, from: $0.paidDate ?? $0.date) == year }
    }

    /// Box 1 of the 1099-NEC for `year`: money actually paid (cash basis), less card and payment-app
    /// payments, which the 1099-K reports instead.
    func form1099NECAmount(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        DomainMoney.roundedSum(paidRows(year: year).filter { !Subcontractor.isReportedOn1099K($0.method) }.map(\.amount))
    }

    /// What was paid in `year` by card or payment app: in `totalPaid`, left out of box 1.
    func paidOn1099K(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        DomainMoney.roundedSum(paidRows(year: year).filter { Subcontractor.isReportedOn1099K($0.method) }.map(\.amount))
    }

    /// True once year-to-date 1099-NEC pay (box 1) reaches that year's threshold. Half-cent
    /// tolerance so an exact-threshold sum of payments can't float a hair under and hide the flag.
    func requires1099(year: Int = Calendar.current.component(.year, from: .now)) -> Bool {
        form1099NECAmount(year: year) >= Subcontractor.form1099Threshold(for: year) - 0.005
    }
}

/// How an outstanding balance reads in a people-list row — a subcontractor's owed amount or an
/// employee's accrued pay: nothing owed, building toward an upcoming payday, or past due.
enum OwedStatus { case none, upcoming, pastDue }

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
        let digits = secureTIN.filter { $0.isASCII && $0.isNumber }
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
/// have crossed the 1099-NEC threshold (card and payment-app payments left out, like box 1). Used on both iPhone and iPad.
nonisolated enum Subcontractor1099Summary {
    struct YearTotals {
        let totalPaid: Double
        let count1099: Int
    }

    static func forYear(_ subs: [Subcontractor],
                        year: Int = Calendar.current.component(.year, from: .now)) -> YearTotals {
        let totalPaid = DomainMoney.roundedSum(subs.map { $0.totalPaid(year: year) })
        let count1099 = subs.filter { $0.requires1099(year: year) }.count
        return YearTotals(totalPaid: totalPaid, count1099: count1099)
    }
}

extension Subcontractor {
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
}
