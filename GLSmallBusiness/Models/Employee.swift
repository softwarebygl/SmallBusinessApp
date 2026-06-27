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

    var label: String {
        switch self {
        case .hourly: String(localized: "Hourly")
        case .salary: String(localized: "Salary")
        }
    }
}

nonisolated enum PayFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, semimonthly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: String(localized: "Weekly")
        case .biweekly: String(localized: "Every 2 weeks")
        case .semimonthly: String(localized: "Twice a month")
        case .monthly: String(localized: "Monthly")
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
    var date: Date = Date.now
    var hours: Double = 0
    var note: String = ""

    /// What the hour cost when logged — snapshotted so labor-cost history stays stable if the
    /// employee's rate later changes. 0 for salaried staff (no per-hour cost).
    var rateSnapshot: Double = 0

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
         employee: Employee? = nil, customer: Customer? = nil) {
        self.date = date
        self.hours = hours
        self.note = note
        self.rateSnapshot = rateSnapshot
        self.employee = employee
        self.customer = customer
    }

    /// Labor cost of this entry (hours × the rate captured when logged).
    var cost: Double { hours * rateSnapshot }
}

// MARK: - Paycheck (a recorded, paid pay period)

@Model
final class Paycheck {
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
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        return String(localized: "No name")
    }

    var initials: String {
        let parts = [firstName, lastName].compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).first
        }
        let combined = parts.map(String.init).joined().uppercased()
        return combined.isEmpty ? "?" : combined
    }

    /// The amount of one full paycheck for a salaried employee (0 for hourly).
    var salaryPerPeriod: Double {
        payType == .salary ? annualSalary / Double(payFrequency.periodsPerYear) : 0
    }
}

// MARK: - Pay math (next payday, accrued gross, YTD, weekly hours)

nonisolated extension Employee {
    private var calendar: Calendar { Calendar.current }

    var sortedTimeEntries: [TimeEntry] {
        (timeEntries ?? []).sorted { $0.date > $1.date }
    }

    var sortedPaychecks: [Paycheck] {
        (paychecks ?? []).sorted { $0.payDate > $1.payDate }
    }

    /// Hours logged that no recorded paycheck has covered yet. Tracked by the TimeEntry↔Paycheck link
    /// (set when a paycheck is recorded), NOT by date — so a backdated or forgotten entry still counts
    /// as owed instead of being silently assumed paid.
    var unpaidHours: Double {
        (timeEntries ?? []).filter { $0.paycheck == nil }.reduce(0) { $0 + $1.hours }
    }

    /// What's owed for the work not yet paid: unpaid hours × rate (hourly), or one period's salary.
    var accruedGross: Double {
        switch payType {
        case .hourly: return unpaidHours * hourlyRate
        case .salary: return salaryPerPeriod
        }
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
        (paychecks ?? [])
            .filter { calendar.component(.year, from: $0.payDate) == year }
            .reduce(0) { $0 + $1.grossAmount }
    }

    func ytdHours(year: Int = Calendar.current.component(.year, from: .now)) -> Double {
        (timeEntries ?? [])
            .filter { calendar.component(.year, from: $0.date) == year }
            .reduce(0) { $0 + $1.hours }
    }

    /// Hours logged in the calendar week containing `date` (used for the 40-hour flag).
    func hoursInWeek(of date: Date = .now) -> Double {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return (timeEntries ?? [])
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
        return NextPayday(date: soonest, total: due.reduce(0) { $0 + $1.accruedGross }, count: due.count)
    }
}
