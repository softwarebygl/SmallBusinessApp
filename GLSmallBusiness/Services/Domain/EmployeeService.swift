//
//  EmployeeService.swift
//  GLSmallBusiness
//
//  Every employee and payroll write: the Employee form, the detail screen's photo, the Log Hours /
//  Log Bonus / Pay Now sheets, and (later) the assistant's tools. The payroll rules below moved
//  here from EmployeeDetailScreen unchanged — FIFO settlement, entry splitting, the bonus line in
//  the note, and the pay-period start — so a paycheck recorded by a tap and one recorded by asking
//  are the same paycheck.
//

import Foundation
import SwiftData

/// An employee's editable fields, as a form or a tool supplies them (untrimmed is fine).
nonisolated struct EmployeeDraft: Equatable, Sendable {
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var payType = PayType.hourly
    var hourlyRate: Double = 0
    var annualSalary: Double = 0
    var payFrequency = PayFrequency.weekly
    var anchorPayday = Date.now
    var hireDate = Date.now
    var isActive = true
    var notes = ""

    init(firstName: String = "", lastName: String = "", email: String = "", phone: String = "",
         payType: PayType = .hourly, hourlyRate: Double = 0, annualSalary: Double = 0,
         payFrequency: PayFrequency = .weekly, anchorPayday: Date = .now, hireDate: Date = .now,
         isActive: Bool = true, notes: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.payType = payType
        self.hourlyRate = hourlyRate
        self.annualSalary = annualSalary
        self.payFrequency = payFrequency
        self.anchorPayday = anchorPayday
        self.hireDate = hireDate
        self.isActive = isActive
        self.notes = notes
    }

    /// The employee's current values — the starting point for a partial edit.
    @MainActor
    init(_ employee: Employee) {
        self.init(firstName: employee.firstName, lastName: employee.lastName, email: employee.email,
                  phone: employee.phone, payType: employee.payType, hourlyRate: employee.hourlyRate,
                  annualSalary: employee.annualSalary, payFrequency: employee.payFrequency,
                  anchorPayday: employee.anchorPayday, hireDate: employee.hireDate,
                  isActive: employee.isActive, notes: employee.notes)
    }

    /// Text fields trimmed; everything else as given.
    var trimmed: EmployeeDraft {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var d = self
        d.firstName = t(firstName)
        d.lastName = t(lastName)
        d.email = t(email)
        d.phone = t(phone)
        d.notes = t(notes)
        return d
    }
}

@MainActor
enum EmployeeService {

    // MARK: - The employee

    /// Adds an employee. `photo` (e.g. carried in from Contacts) is stored when given.
    @discardableResult
    static func create(_ draft: EmployeeDraft, photo: Data? = nil, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> Employee {
        try DomainGate.requireCanCreate(Employee.self, cap: FreeTier.employees,
                                        operation: .saveEmployee, in: context, subscription)
        let d = try validated(draft)
        let employee = Employee(
            firstName: d.firstName, lastName: d.lastName, email: d.email, phone: d.phone,
            payType: d.payType, hourlyRate: d.hourlyRate, annualSalary: d.annualSalary,
            payFrequency: d.payFrequency, anchorPayday: d.anchorPayday,
            hireDate: d.hireDate, isActive: d.isActive, notes: d.notes)
        if let photo { employee.profileImageData = photo }
        context.insert(employee)
        context.saveChanges()
        return employee
    }

    /// Edits an employee in place. Both rates are written whatever the pay type (the form always
    /// has). `photo` replaces the current one only when given.
    static func update(_ employee: Employee, with draft: EmployeeDraft, photo: Data? = nil,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveEmployee, subscription)
        try DomainGate.requireLive(employee, .saveEmployee)
        let d = try validated(draft)
        setIfChanged(employee, \.firstName, d.firstName)
        setIfChanged(employee, \.lastName, d.lastName)
        setIfChanged(employee, \.email, d.email)
        setIfChanged(employee, \.phone, d.phone)
        setIfChanged(employee, \.payType, d.payType)
        setIfChanged(employee, \.hourlyRate, d.hourlyRate)
        setIfChanged(employee, \.annualSalary, d.annualSalary)
        setIfChanged(employee, \.payFrequency, d.payFrequency)
        setIfChanged(employee, \.anchorPayday, d.anchorPayday)
        setIfChanged(employee, \.hireDate, d.hireDate)
        setIfChanged(employee, \.isActive, d.isActive)
        setIfChanged(employee, \.notes, d.notes)
        if let photo { setIfChanged(employee, \.profileImageData, photo) }
        context.saveChanges()
    }

    /// Sets the profile photo, or removes it with `nil`.
    static func setPhoto(_ data: Data?, for employee: Employee, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveEmployee, subscription)
        try DomainGate.requireLive(employee, .saveEmployee)
        setIfChanged(employee, \.profileImageData, data)
        context.saveChanges()
    }

    // MARK: - Hours and bonuses

    /// Logs work (range, hours, or a flat amount) — or edits `entry` when given. Hours-based work
    /// snapshots `rate` and stores no flat amount; a flat amount (rounded to the cent, law 60) stores
    /// no hours and no rate. A range is filed under its start and stores its length. `customer` nil
    /// clears the tag.
    @discardableResult
    static func logTime(_ work: LoggedWork, customer: Customer?, note: String,
                        for employee: Employee, editing entry: TimeEntry? = nil,
                        in context: ModelContext, subscription: SubscriptionManager? = nil) throws -> TimeEntry {
        try DomainGate.requireWritable(.logHours, subscription)
        try requireEntry(entry, of: employee, .logHours)
        if customer != nil { try DomainGate.requireLive(customer, .logHours) }
        try work.validate(for: .logHours)

        let target = entry ?? newEntry(for: employee, in: context)
        setIfChanged(target, \.hours, work.hours)
        setIfChanged(target, \.date, work.date)
        setIfChanged(target, \.amount, work.flatAmount)
        setIfChanged(target, \.rateSnapshot, work.rate)
        setIfChanged(target, \.customer, customer)
        setIfChanged(target, \.note, note.trimmingCharacters(in: .whitespacesAndNewlines))
        context.saveChanges()
        return target
    }

    /// Logs a one-time bonus (a flat entry with no hours, rounded to the cent — law 60) — or edits
    /// `entry` when given. The entry's customer tag is left as it is, as the Log Bonus sheet always has.
    @discardableResult
    static func logBonus(_ amount: Double, on date: Date, note: String, for employee: Employee,
                         editing entry: TimeEntry? = nil, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws -> TimeEntry {
        try DomainGate.requireWritable(.logHours, subscription)
        try requireEntry(entry, of: employee, .logHours)
        let work = LoggedWork.dollars(amount, on: date)
        try work.validate(for: .logHours)

        let target = entry ?? newEntry(for: employee, in: context)
        setIfChanged(target, \.date, date)
        setIfChanged(target, \.amount, work.flatAmount)
        setIfChanged(target, \.hours, 0)
        setIfChanged(target, \.rateSnapshot, 0)
        setIfChanged(target, \.note, note.trimmingCharacters(in: .whitespacesAndNewlines))
        context.saveChanges()
        return target
    }

    // MARK: - Paychecks

    /// Records a paycheck ("Pay now"). `amount` is applied to what's owed, oldest first; `bonus` is
    /// paid on top and named in the note. Returns the new paycheck.
    ///
    /// Settlement (moved verbatim from RecordPaycheckSheet): the oldest unpaid live entries are
    /// linked to the paycheck until `amount` runs out. If it lands mid-entry, that entry is split —
    /// a paid slice worth the remainder is peeled off and linked, the rest stays owed — so owed
    /// drops by exactly what was paid; anything beyond total owed just rides on the gross. Salary
    /// settles only flat bonuses (the standing salary has no entry to link); hourly settles every
    /// entry. The period starts at the earliest settled entry, else the day after the last covered
    /// period, else the hire date — never after the pay date.
    ///
    /// Worked exactly (law 60) by `DomainMoney.settle`, the rule a subcontractor's "Pay now" uses
    /// too: the amount and the bonus are rounded to the cent as they are stored, and an entry is
    /// settled while what is owed through it — added exactly and rounded once, the way the accrued
    /// total on screen is — fits the amount, so paying the accrued total shown settles every entry it
    /// counts. What is left over is whole cents, and a split flat entry keeps exactly what was not
    /// paid — never a binary remainder.
    @discardableResult
    static func recordPaycheck(for employee: Employee, amount typedAmount: Double, bonus typedBonus: Double = 0,
                               payDate: Date, method: PaymentMethod, note: String,
                               in context: ModelContext,
                               subscription: SubscriptionManager? = nil) throws -> Paycheck {
        try DomainGate.requireWritable(.recordPaycheck, subscription)
        try DomainGate.requireLive(employee, .recordPaycheck)
        try DomainGate.requireNonNegative(typedAmount, typedBonus, for: .recordPaycheck)
        let amount = DomainMoney.decimal(DomainMoney.roundedToCents(typedAmount))
        let bonus = DomainMoney.decimal(DomainMoney.roundedToCents(typedBonus))
        guard amount + bonus > 0 else {
            throw DomainGate.refusal(.amountRequired, .recordPaycheck)
        }

        let unpaid = employee.liveRows(employee.timeEntries)
            .filter { entry in
                guard entry.paycheck == nil else { return false }
                return employee.payType == .salary ? entry.amount > 0.005 : true
            }
            .sorted { $0.date < $1.date }
        let values = unpaid.map(\.exactGrossValue)
        let (count, left) = DomainMoney.settle(values, with: amount)
        var settled = Array(unpaid.prefix(count))
        if left > 0, count < unpaid.count {
            // Partial: peel off a paid slice worth what is left and shrink the original entry.
            let entry = unpaid[count]
            let slice = TimeEntry(employee: employee)
            if entry.amount > 0.005 {                       // flat/dollars entry — split by amount
                slice.amount = DomainMoney.double(left)
                entry.amount = DomainMoney.double(values[count] - left)
            } else {                                        // hours entry — split proportionally at its rate
                let rate = entry.rateSnapshot > 0 ? entry.rateSnapshot : employee.hourlyRate
                let paidHours = rate > 0 ? DomainMoney.double(left) / rate : 0
                slice.hours = paidHours
                slice.rateSnapshot = entry.rateSnapshot
                entry.hours -= paidHours
            }
            slice.date = entry.date
            slice.customer = entry.customer
            slice.note = entry.note
            context.insert(slice)
            settled.append(slice)
        }

        var finalNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if bonus > 0 {
            // Stored text, English as it always has been (the note is the owner's own record).
            let bonusText = "Includes \(DomainMoney.double(bonus).formatted(.money)) bonus."
            finalNote = finalNote.isEmpty ? bonusText : "\(finalNote)\n\(bonusText)"
        }

        let cal = Calendar.current
        let coveredThrough = employee.liveRows(employee.paychecks).map(\.payPeriodEnd).max()
        let periodStart = settled.map(\.date).min()
            ?? coveredThrough.map { cal.date(byAdding: .day, value: 1, to: $0) ?? $0 }
            ?? employee.hireDate

        let check = Paycheck(
            payPeriodStart: min(periodStart, payDate), payPeriodEnd: payDate, payDate: payDate,
            grossAmount: DomainMoney.double(amount + bonus), hoursPaid: settled.reduce(0) { $0 + $1.hours },
            method: method, note: finalNote, employee: employee
        )
        context.insert(check)
        for entry in settled { entry.paycheck = check }
        context.saveChanges()
        return check
    }

    /// Corrects a recorded paycheck's date, gross, method and note. Nothing is re-settled — which
    /// entries it covered was decided when it was recorded. The gross is stored rounded to the cent.
    static func editPaycheck(_ check: Paycheck, payDate: Date, gross typed: Double, method: PaymentMethod,
                             note: String, in context: ModelContext,
                             subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.recordPaycheck, subscription)
        try DomainGate.requireLive(check, .recordPaycheck)
        try DomainGate.requireNonNegative(typed, for: .recordPaycheck)
        let gross = DomainMoney.roundedToCents(typed)
        guard gross > 0 else { throw DomainGate.refusal(.amountRequired, .recordPaycheck) }
        setIfChanged(check, \.payDate, payDate)
        setIfChanged(check, \.grossAmount, gross)
        setIfChanged(check, \.method, method)
        setIfChanged(check, \.note, note.trimmingCharacters(in: .whitespacesAndNewlines))
        context.saveChanges()
    }

    // MARK: - Helpers

    private static func validated(_ draft: EmployeeDraft) throws -> EmployeeDraft {
        let d = draft.trimmed
        guard !d.firstName.isEmpty || !d.lastName.isEmpty else {
            throw DomainGate.refusal(.personNameRequired, .saveEmployee)
        }
        try DomainGate.requireNonNegative(d.hourlyRate, d.annualSalary, for: .saveEmployee)
        return d
    }

    /// The employee is live, and so is `entry` when editing — and it is THIS employee's entry.
    private static func requireEntry(_ entry: TimeEntry?, of employee: Employee,
                                     _ operation: MBWriteOperation) throws {
        try DomainGate.requireLive(employee, operation)
        guard let entry else { return }
        try DomainGate.requireLive(entry, operation)
        guard entry.employee?.persistentModelID == employee.persistentModelID else {
            throw DomainGate.refusal(.recordNotFound, operation)
        }
    }

    private static func newEntry(for employee: Employee, in context: ModelContext) -> TimeEntry {
        let created = TimeEntry(employee: employee)
        context.insert(created)
        return created
    }
}
