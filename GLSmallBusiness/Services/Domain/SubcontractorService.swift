//
//  SubcontractorService.swift
//  GLSmallBusiness
//
//  Every subcontractor write: the Subcontractor form (all but the tax fields), the detail screen's
//  photo, the Record Amount / Pay Now sheets, and (later) the assistant's tools.
//
//  TAX FIELDS ARE NOT HERE, deliberately. The TIN type and the Keychain TIN stay in the form, behind
//  Face ID, written after this service returns — no service (and so no tool) can read or write a
//  Tax ID or a W-9 (law 58(7) quarantine).
//
//  The Pay Now rules moved here from PaySubcontractorSheet unchanged: oldest owed entries first,
//  a mid-entry payment splits the entry (hours prorated), and anything beyond what's owed is booked
//  as its own paid entry so the 1099 total matches what went out.
//

import Foundation
import SwiftData

/// A subcontractor's editable fields other than tax details (untrimmed is fine).
nonisolated struct SubcontractorDraft: Equatable, Sendable {
    var firstName = ""
    var lastName = ""
    var businessName = ""
    var email = ""
    var phone = ""
    var address = Address()
    /// Optional default rate (0 = none), which enables logging hours.
    var hourlyRate: Double = 0
    var isActive = true
    var notes = ""

    init(firstName: String = "", lastName: String = "", businessName: String = "",
         email: String = "", phone: String = "", address: Address = Address(),
         hourlyRate: Double = 0, isActive: Bool = true, notes: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.businessName = businessName
        self.email = email
        self.phone = phone
        self.address = address
        self.hourlyRate = hourlyRate
        self.isActive = isActive
        self.notes = notes
    }

    /// The subcontractor's current values — the starting point for a partial edit.
    @MainActor
    init(_ sub: Subcontractor) {
        self.init(firstName: sub.firstName, lastName: sub.lastName, businessName: sub.businessName,
                  email: sub.email, phone: sub.phone, address: sub.address,
                  hourlyRate: sub.hourlyRate, isActive: sub.isActive, notes: sub.notes)
    }

    /// Text fields trimmed; an empty Apt/Suite becomes nil (the form's rule).
    var trimmed: SubcontractorDraft {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let street2 = t(address.street2 ?? "")
        var d = self
        d.firstName = t(firstName)
        d.lastName = t(lastName)
        d.businessName = t(businessName)
        d.email = t(email)
        d.phone = t(phone)
        d.notes = t(notes)
        d.address = Address(street1: t(address.street1), street2: street2.isEmpty ? nil : street2,
                            city: t(address.city), state: t(address.state),
                            postalCode: t(address.postalCode))
        return d
    }
}

@MainActor
enum SubcontractorService {

    // MARK: - The subcontractor

    /// Adds a subcontractor (no tax fields — see the header). `photo` is stored when given.
    @discardableResult
    static func create(_ draft: SubcontractorDraft, photo: Data? = nil, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> Subcontractor {
        try DomainGate.requireCanCreate(Subcontractor.self, cap: FreeTier.subcontractors,
                                        operation: .saveSubcontractor, in: context, subscription)
        let d = try validated(draft)
        let sub = Subcontractor(
            firstName: d.firstName, lastName: d.lastName, businessName: d.businessName,
            email: d.email, phone: d.phone, hourlyRate: d.hourlyRate, address: d.address,
            isActive: d.isActive, notes: d.notes)
        if let photo { sub.profileImageData = photo }
        context.insert(sub)
        context.saveChanges()
        return sub
    }

    /// Edits a subcontractor in place (never the tax fields). `photo` replaces the current one
    /// only when given.
    static func update(_ sub: Subcontractor, with draft: SubcontractorDraft, photo: Data? = nil,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveSubcontractor, subscription)
        try DomainGate.requireLive(sub, .saveSubcontractor)
        let d = try validated(draft)
        setIfChanged(sub, \.firstName, d.firstName)
        setIfChanged(sub, \.lastName, d.lastName)
        setIfChanged(sub, \.businessName, d.businessName)
        setIfChanged(sub, \.email, d.email)
        setIfChanged(sub, \.phone, d.phone)
        setIfChanged(sub, \.hourlyRate, d.hourlyRate)
        setIfChanged(sub, \.addressStreet1, d.address.street1)
        setIfChanged(sub, \.addressStreet2, d.address.street2 ?? "")
        setIfChanged(sub, \.addressCity, d.address.city)
        setIfChanged(sub, \.addressState, d.address.state)
        setIfChanged(sub, \.addressPostalCode, d.address.postalCode)
        setIfChanged(sub, \.isActive, d.isActive)
        setIfChanged(sub, \.notes, d.notes)
        if let photo { setIfChanged(sub, \.profileImageData, photo) }
        context.saveChanges()
    }

    /// Sets the profile photo, or removes it with `nil`.
    static func setPhoto(_ data: Data?, for sub: Subcontractor, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveSubcontractor, subscription)
        try DomainGate.requireLive(sub, .saveSubcontractor)
        setIfChanged(sub, \.profileImageData, data)
        context.saveChanges()
    }

    // MARK: - Ledger entries

    /// Records what's owed or paid — or edits `entry` when given. Hours-based work stores its hours
    /// and `hours × rate` as the amount (a SubPayment keeps no rate), worked out exactly and rounded
    /// once to the cent (law 60); a flat dollar amount is stored rounded to the cent too. A range is
    /// filed under its start. `paidOn` nil means still owed; `method` is written either way, as the
    /// sheet does.
    @discardableResult
    static func recordEntry(_ work: LoggedWork, detail: String, customer: Customer?,
                            paidOn: Date?, method: PaymentMethod, for sub: Subcontractor,
                            editing entry: SubPayment? = nil, in context: ModelContext,
                            subscription: SubscriptionManager? = nil) throws -> SubPayment {
        let operation = MBWriteOperation.recordSubcontractorPayment
        try DomainGate.requireWritable(operation, subscription)
        try DomainGate.requireLive(sub, operation)
        if let entry {
            try DomainGate.requireLive(entry, operation)
            guard entry.subcontractor?.persistentModelID == sub.persistentModelID else {
                throw DomainGate.refusal(.recordNotFound, operation)
            }
        }
        if customer != nil { try DomainGate.requireLive(customer, operation) }
        try work.validate(for: operation)

        let target = entry ?? {
            let created = SubPayment(subcontractor: sub)
            context.insert(created)
            return created
        }()
        switch work {
        case .range, .hours:
            setIfChanged(target, \.hours, work.hours)
            setIfChanged(target, \.amount, DomainMoney.roundedToCents(DomainMoney.product(work.hours, work.rate)))
        case .dollars:
            setIfChanged(target, \.hours, 0)
            setIfChanged(target, \.amount, work.flatAmount)
        }
        setIfChanged(target, \.date, work.date)
        setIfChanged(target, \.detail, detail.trimmingCharacters(in: .whitespacesAndNewlines))
        setIfChanged(target, \.customer, customer)
        setIfChanged(target, \.paidDate, paidOn)
        setIfChanged(target, \.method, method)
        context.saveChanges()
        return target
    }

    /// Pays `amount` toward what's owed ("Pay now"). Oldest owed entries are marked paid first
    /// (paid date + method); a payment that lands mid-entry peels off a paid slice worth the
    /// remainder (hours prorated) and leaves the rest owed; anything left after everything owed is
    /// paid — or with nothing owed — becomes its own paid entry. Returns every paid row it wrote.
    /// Worked exactly (Decimal, law 60) by `DomainMoney.settle`, the rule an employee's paycheck
    /// uses too: the payment is rounded to the cent as it is stored, and an entry is settled while
    /// what is owed through it — added exactly and rounded once, the way `outstanding` is — fits the
    /// payment, so paying the outstanding amount shown settles every entry. A slice and the extra
    /// are whole cents, and a split entry keeps exactly what was not paid — never a binary remainder
    /// like 0.009999999999990905.
    @discardableResult
    static func payNow(_ amount: Double, paidDate: Date, method: PaymentMethod, for sub: Subcontractor,
                       in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> [SubPayment] {
        let operation = MBWriteOperation.recordSubcontractorPayment
        try DomainGate.requireWritable(operation, subscription)
        try DomainGate.requireLive(sub, operation)
        try DomainGate.requireNonNegative(amount, for: operation)
        // At least a cent as it will be stored.
        guard DomainMoney.roundedToCents(amount) > 0 else { throw DomainGate.refusal(.amountRequired, operation) }

        let unpaid = sub.liveRows(sub.payments)
            .filter { !$0.isPaid }
            .sorted { $0.date < $1.date }
        var paid: [SubPayment] = []
        let owed = unpaid.map { DomainMoney.decimal($0.amount) }
        let (settled, left) = DomainMoney.settle(owed, with: DomainMoney.cents(DomainMoney.decimal(amount)))
        for entry in unpaid.prefix(settled) {
            entry.paidDate = paidDate
            entry.method = method
            paid.append(entry)
        }
        if left > 0, settled < unpaid.count {
            // The payment lands mid-entry: peel off a paid slice worth what is left.
            let entry = unpaid[settled]
            let fraction = DomainMoney.double(left) / DomainMoney.double(owed[settled])
            let slice = SubPayment(amount: DomainMoney.double(left), hours: entry.hours * fraction,
                                   date: entry.date, paidDate: paidDate, method: method,
                                   detail: entry.detail, subcontractor: sub,
                                   customer: entry.customer)
            context.insert(slice)
            entry.amount = DomainMoney.double(owed[settled] - left)
            entry.hours -= entry.hours * fraction
            paid.append(slice)
        } else if left > 0 {
            let extra = SubPayment(amount: DomainMoney.double(left), date: paidDate, paidDate: paidDate,
                                   method: method, subcontractor: sub)
            context.insert(extra)
            paid.append(extra)
        }
        context.saveChanges()
        return paid
    }

    // MARK: - Helpers

    private static func validated(_ draft: SubcontractorDraft) throws -> SubcontractorDraft {
        let d = draft.trimmed
        guard !d.firstName.isEmpty || !d.lastName.isEmpty || !d.businessName.isEmpty else {
            throw DomainGate.refusal(.nameRequired, .saveSubcontractor)
        }
        try DomainGate.requireNonNegative(d.hourlyRate, for: .saveSubcontractor)
        return d
    }
}
