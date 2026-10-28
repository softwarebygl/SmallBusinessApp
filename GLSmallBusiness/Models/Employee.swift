//
//  Employee.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Employees feature — W-2 staff you pay directly. Phase A (this file) covers the record,
//  daily hours, paychecks (paid history), and the pay math (next payday + accrued gross, YTD,
//  weekly-hours flag). Onboarding docs (W-4 / I-9 / SSN) and per-job labor-cost rollups land in
//  Phase B — but the per-entry customer tag + rate snapshot are captured here from day one so that
//  history is never lost and the rollup can be added later without a migration.
//

import Foundation
import SwiftData

// MARK: - Enums
// `nonisolated` so their Codable conformances aren't main-actor isolated (SwiftData requirement),
// matching InvoiceStatus / PaymentTerms / PaymentMethod.

nonisolated enum PayType: String, Codable, CaseIterable, Identifiable {
    case hourly, salary

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .hourly: mbLoc("Hourly")
        case .salary: mbLoc("Salary")
        }
    }

    /// English-only surfaces (accountant CSVs) - see PaymentMethod.englishLabel.
    var englishLabel: String {
        switch self {
        case .hourly: "Hourly"
        case .salary: "Salary"
        }
    }
}

nonisolated enum PayFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, semimonthly, monthly

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .weekly: mbLoc("Weekly")
        case .biweekly: mbLoc("Every 2 weeks")
        case .semimonthly: mbLoc("Twice a month")
        case .monthly: mbLoc("Monthly")
        }
    }

    /// How many paychecks a year — used to split a salary into a per-period amount.
    var periodsPerYear: Int {
        switch self {
        case .weekly: 52
        case .biweekly: 26
        case .semimonthly: 24
        case .monthly: 12
        }
    }
}

// MARK: - Employee

@Model
final class Employee {

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
    var email: String = ""
    var phone: String = ""

    var payType: PayType = PayType.hourly
    /// Used when `payType == .hourly`. Straight time only (no overtime multiplier), per the owner's choice.
    var hourlyRate: Double = 0
    /// Used when `payType == .salary` — the gross annual figure, divided by `payFrequency.periodsPerYear`.
    var annualSalary: Double = 0

    var payFrequency: PayFrequency = PayFrequency.weekly
    /// A known payday to roll forward from (the next payday after today is computed from this).
    var anchorPayday: Date = Date.now
    var hireDate: Date = Date.now
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date.now
    /// Optional profile photo (stored outside the row, like Customer). Additive, V1.
    @Attribute(.externalStorage) var profileImageData: Data?

    // CloudKit requires every relationship (incl. to-many) to be optional.
    @Relationship(deleteRule: .cascade, inverse: \TimeEntry.employee)
    var timeEntries: [TimeEntry]?

    @Relationship(deleteRule: .cascade, inverse: \Paycheck.employee)
    var paychecks: [Paycheck]?

    init(
        firstName: String = "",
        lastName: String = "",
        email: String = "",
        phone: String = "",
        payType: PayType = .hourly,
        hourlyRate: Double = 0,
        annualSalary: Double = 0,
        payFrequency: PayFrequency = .weekly,
        anchorPayday: Date = .now,
        hireDate: Date = .now,
        isActive: Bool = true,
        notes: String = ""
    ) {
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
}

// MARK: - Time entry (one day's logged hours)

@Model
final class TimeEntry {

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
    var date: Date = Date.now
    var hours: Double = 0
    var note: String = ""

    /// What the hour cost when logged — snapshotted so labor-cost history stays stable if the
    /// employee's rate later changes. 0 for salaried staff (no per-hour cost).
    var rateSnapshot: Double = 0

    /// A flat dollar amount — a "Dollars"-mode hourly entry or a salary bonus, independent of hours.
    /// 0 means this is an hours-based entry valued at `hours × rateSnapshot`.
    var amount: Double = 0

    var employee: Employee?
    /// Optional job tag: the customer/job these hours were worked on, enabling labor-cost-per-job.
    /// Nullified (not deleted) if the customer is removed, so the hours survive.
    var customer: Customer?
    /// The paycheck that covered these hours (nil = still unpaid). Set when a paycheck is recorded;
    /// nullified if that paycheck is deleted, so the hours correctly become owed again. This is how
    /// "what's still owed" is tracked — NOT by date — so a backdated/forgotten entry isn't silently
    /// treated as already paid.
    var paycheck: Paycheck?

    init(date: Date = .now, hours: Double = 0, note: String = "", rateSnapshot: Double = 0,
         amount: Double = 0, employee: Employee? = nil, customer: Customer? = nil) {
        self.date = date
        self.hours = hours
        self.note = note
        self.rateSnapshot = rateSnapshot
        self.amount = amount
        self.employee = employee
        self.customer = customer
    }

    /// Labor cost of this entry (hours × the rate captured when logged), rounded once to the cent
    /// (law 60). Flat-amount entries carry no per-hour labor cost.
    var cost: Double { DomainMoney.roundedToCents(DomainMoney.product(hours, rateSnapshot)) }

    /// What this entry adds to gross pay: a flat amount when set, otherwise hours valued at the
    /// snapshotted rate — falling back to the employee's current rate for pre-snapshot or demo entries.
    /// Rounded once to the cent.
    nonisolated var grossValue: Double { DomainMoney.roundedToCents(exactGrossValue) }

    /// The same, exact — what an accrual adds up before its own one rounding.
    nonisolated var exactGrossValue: Decimal {
        if amount > 0.005 { return DomainMoney.decimal(amount) }
        let rate = rateSnapshot > 0 ? rateSnapshot : (employee?.hourlyRate ?? 0)
        return DomainMoney.product(hours, rate)
    }
}

// MARK: - Paycheck (a recorded, paid pay period)

@Model
final class Paycheck {

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
    var payPeriodStart: Date = Date.now
    var payPeriodEnd: Date = Date.now
    var payDate: Date = Date.now
    var grossAmount: Double = 0
    /// Hours this paycheck covered (hourly staff); 0 for salary.
    var hoursPaid: Double = 0
    var method: PaymentMethod = PaymentMethod.check
    var note: String = ""

    var employee: Employee?
    /// The time entries this paycheck paid for. Nullified (entries survive, become unpaid) if the
    /// paycheck is deleted.
    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.paycheck)
    var coveredEntries: [TimeEntry]?

    init(payPeriodStart: Date = .now, payPeriodEnd: Date = .now, payDate: Date = .now,
         grossAmount: Double = 0, hoursPaid: Double = 0, method: PaymentMethod = .check,
         note: String = "", employee: Employee? = nil) {
        self.payPeriodStart = payPeriodStart
        self.payPeriodEnd = payPeriodEnd
        self.payDate = payDate
        self.grossAmount = grossAmount
        self.hoursPaid = hoursPaid
        self.method = method
        self.note = note
        self.employee = employee
    }
}

// MARK: - Employee display helpers

nonisolated extension Employee {
    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Last, First" for the sorted list, falling back gracefully.
    @MainActor
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        return mbLoc("No name")
    }

    var initials: String {
        let parts = [firstName, lastName].compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).first
        }
        let combined = parts.map(String.init).joined().uppercased()
        return combined.isEmpty ? "?" : combined
    }

    /// The amount of one full paycheck for a salaried employee (0 for hourly), rounded once.
    var salaryPerPeriod: Double { DomainMoney.roundedToCents(exactSalaryPerPeriod) }

    /// The same, exact — the salaried accrual adds its bonuses to this before its own one rounding.
    var exactSalaryPerPeriod: Decimal {
        guard payType == .salary, payFrequency.periodsPerYear > 0 else { return 0 }
        return DomainMoney.decimal(annualSalary) / Decimal(payFrequency.periodsPerYear)
    }
}

// MARK: - Pay math (next payday, accrued gross, YTD, weekly hours)

nonisolated extension Employee {
    private var calendar: Calendar { Calendar.current }

    var sortedTimeEntries: [TimeEntry] {
        liveRows(timeEntries).sorted { $0.date > $1.date }
    }

    var sortedPaychecks: [Paycheck] {
        liveRows(paychecks).sorted { $0.payDate > $1.payDate }
    }

    /// Hours logged that no recorded paycheck has covered yet. Tracked by the TimeEntry↔Paycheck link
    /// (set when a paycheck is recorded), NOT by date — so a backdated or forgotten entry still counts
    /// as owed instead of being silently assumed paid.
    var unpaidHours: Double {
        liveRows(timeEntries).filter { $0.paycheck == nil }.reduce(0) { $0 + $1.hours }
    }

    /// Gross still owed across unpaid entries — each hours-entry valued at its snapshotted rate (so a
    /// later raise never rewrites old/pending records), plus any flat Dollars/bonus amounts.
    var unpaidGross: Double { DomainMoney.roundedToCents(exactUnpaidGross) }

    private var exactUnpaidGross: Decimal {
        liveRows(timeEntries).filter { $0.paycheck == nil }.reduce(Decimal(0)) { $0 + $1.exactGrossValue }
    }

    /// Unpaid flat amounts only (bonuses). A salaried accrual adds these but ignores logged hours —
    /// salary pay doesn't depend on hours worked, so stray hours entries never inflate what's owed.
    var unpaidBonuses: Double { DomainMoney.roundedToCents(exactUnpaidBonuses) }

    private var exactUnpaidBonuses: Decimal {
        liveRows(timeEntries).filter { $0.paycheck == nil }
            .reduce(Decimal(0)) { $0 + ($1.amount > 0.005 ? DomainMoney.decimal($1.amount) : 0) }
    }

    /// What's owed for work not yet paid: snapshot-valued unpaid entries (hourly), or one period's
    /// salary plus any unpaid bonuses (salary — hours are ignored).
    var accruedGross: Double {
        switch payType {
        case .hourly: return unpaidGross
        case .salary: return DomainMoney.roundedToCents(exactSalaryPerPeriod + exactUnpaidBonuses)
        }
    }

    /// How accrued (unpaid) pay reads in a list row — mirrors the subcontractor "owed" states: nothing
    /// accrued, building toward the upcoming payday (gold, including on payday itself), or past due
    /// (red) once a payday has actually come and gone with unpaid work still on the books. An unpaid
    /// entry is late once *its* payday is strictly in the past; a salaried employee's standing period
    /// amount is always the upcoming check, never past due.
    var owedStatus: OwedStatus {
        guard accruedGross > 0.005 else { return .none }
        let startOfToday = calendar.startOfDay(for: .now)
        let anyPastDue = liveRows(timeEntries).contains { entry in
            guard entry.paycheck == nil else { return false }
            // Only entries that actually count toward what's owed can make it past due — hours for
            // hourly, flat bonuses for salary — mirroring accruedGross, so a salaried standing amount
            // stays the upcoming check even if stray hours entries linger.
            let counted = payType == .salary ? entry.amount : entry.grossValue
            return counted > 0.005 && nextPayday(onOrAfter: entry.date) < startOfToday
        }
        return anyPastDue ? .pastDue : .upcoming
    }

    /// The next payday on or after `date`, computed from `anchorPayday` and the frequency.
    func nextPayday(onOrAfter date: Date = .now) -> Date {
        let day = calendar.startOfDay(for: date)
        switch payFrequency {
        case .weekly, .biweekly:
            let step = payFrequency == .weekly ? 7 : 14
            var payday = calendar.startOfDay(for: anchorPayday)
            // Walk in whole steps toward `day` without an unbounded loop.
            if payday < day {
                let days = calendar.dateComponents([.day], from: payday, to: day).day ?? 0
                let jumps = days / step
                payday = calendar.date(byAdding: .day, value: jumps * step, to: payday) ?? payday
            } else if payday > day {
                let days = calendar.dateComponents([.day], from: day, to: payday).day ?? 0
                let jumps = days / step
                payday = calendar.date(byAdding: .day, value: -jumps * step, to: payday) ?? payday
            }
            while payday < day { payday = calendar.date(byAdding: .day, value: step, to: payday) ?? payday }
            return payday
        case .semimonthly:
            // Paid on the 15th and the last day of the month.
            let mid = dateInMonth(of: day, day: 15)
            if day <= mid { return mid }
            return endOfMonth(of: day)
        case .monthly:
            // Same day-of-month as the anchor, clamped to the month length.
            let anchorDay = calendar.component(.day, from: anchorPayday)
            let thisMonth = dateInMonth(of: day, day: anchorDay)
            if day <= thisMonth { return thisMonth }
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: day) ?? day
            return dateInMonth(of: nextMonth, day: anchorDay)
        }
    }

    /// The first day of the pay period containing `date` — the day AFTER the previous payday.
    /// The previous payday itself is NOT inside the current period: a check paid ON payday
    /// belongs to the period that ENDED that day. Used to spot a salary paycheck that was
    /// already recorded this period.
    func currentPeriodStart(onOrBefore date: Date = .now) -> Date {
        let next = nextPayday(onOrAfter: date)
        switch payFrequency {
        case .weekly: return calendar.date(byAdding: .day, value: -6, to: next) ?? next
        case .biweekly: return calendar.date(byAdding: .day, value: -13, to: next) ?? next
        case .semimonthly:
            // Paydays are the 15th and month-end: the 15th covers the 1st–15th, month-end the 16th on
            // (already the day after the previous payday).
            return calendar.component(.day, from: next) == 15
                ? dateInMonth(of: next, day: 1)
                : dateInMonth(of: next, day: 16)
        case .monthly:
            let prior = calendar.date(byAdding: .month, value: -1, to: next) ?? next
            return calendar.date(byAdding: .day, value: 1, to: prior) ?? prior
        }
    }

    private func dateInMonth(of reference: Date, day target: Int) -> Date {
        var comps = calendar.dateComponents([.year, .month], from: reference)
        let range = calendar.range(of: .day, in: .month, for: reference) ?? 1..<29
        comps.day = min(target, range.upperBound - 1)
        return calendar.date(from: comps) ?? reference
    }

    private func endOfMonth(of reference: Date) -> Date {
        let range = calendar.range(of: .day, in: .month, for: reference) ?? 1..<29
        return dateInMonth(of: reference, day: range.upperBound - 1)
    }

    // Year-to-date (current calendar year).

    func ytdGross(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        DomainMoney.roundedSum(liveRows(paychecks)
            .filter { calendar.component(.year, from: $0.payDate) == year }
            .map(\.grossAmount))
    }

    func ytdHours(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        liveRows(timeEntries)
            .filter { calendar.component(.year, from: $0.date) == year }
            .reduce(0) { $0 + $1.hours }
    }

    /// Hours logged in the calendar week containing `date` (used for the 40-hour flag).
    func hoursInWeek(of date: Date = .now) -> Double {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return liveRows(timeEntries)
            .filter { week.contains($0.date) }
            .reduce(0) { $0 + $1.hours }
    }

    /// True when this week's logged hours pass 40 — an informational heads-up only (pay is straight time).
    var isOverFortyThisWeek: Bool { hoursInWeek() > 40 }
}

// MARK: - Payroll roll-up (across employees)

/// The soonest upcoming payday across a set of employees, used by the payday-summary header on
/// both the iPhone tab and the iPad list column.
nonisolated enum PayrollSummary {
    struct NextPayday {
        let date: Date
        let total: Double
        let count: Int
    }

    static func nextPayday(for employees: [Employee], on reference: Date = .now) -> NextPayday? {
        let active = employees.filter(\.isActive)
        guard let soonest = active.map({ $0.nextPayday(onOrAfter: reference) }).min() else { return nil }
        let calendar = Calendar.current
        let due = active.filter { calendar.isDate($0.nextPayday(onOrAfter: reference), inSameDayAs: soonest) }
        return NextPayday(date: soonest, total: DomainMoney.roundedSum(due.map(\.accruedGross)), count: due.count)
    }
}
