//
//  EmployeeTests.swift
//  GLSmallBusinessTests
//
//  The BASE CASES of the Employees logic: display helpers, salary per period, the next payday for
//  every frequency, the period start, the model defaults, and the cross-employee payroll roll-up.
//  Every EDGE of the same math (thresholds, clamped and leap months, DST, negative and huge inputs,
//  the owed-status rule, YTD boundaries, the wage export) lives in EmployeePayrollCoverageTests —
//  nothing is asserted in both. Built in memory via the `TS` builders — no container needed.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct EmployeeDisplayTests {
    @Test func fullName() {
        #expect(TS.employee(first: "Jason", last: "Garcia").fullName == "Jason Garcia")
        #expect(TS.employee(first: "", last: "Garcia").fullName == "Garcia")
        #expect(TS.employee(first: "Jason", last: "").fullName == "Jason")
        #expect(TS.employee(first: "  ", last: "  ").fullName == "")
    }

    @Test func listDisplayName() {
        #expect(TS.employee(first: "Jason", last: "Garcia").listDisplayName == "Garcia, Jason")
        #expect(TS.employee(first: "", last: "Garcia").listDisplayName == "Garcia")
        #expect(TS.employee(first: "Jason", last: "").listDisplayName == "Jason")
        #expect(TS.employee(first: "", last: "").listDisplayName == "No name")
    }

    @Test func initials() {
        #expect(TS.employee(first: "Jason", last: "Garcia").initials == "JG")
        #expect(TS.employee(first: "Jason", last: "").initials == "J")
        #expect(TS.employee(first: "", last: "").initials == "?")
    }
}

@MainActor
struct EmployeePayMathTests {
    /// One LITERAL per frequency — never the divisor the model itself uses, or the test would
    /// only prove that Swift can divide.
    @Test func salaryPerPeriod() {
        #expect(close(TS.employee(payType: .salary, annualSalary: 52_000, payFrequency: .weekly).salaryPerPeriod, 1_000))
        #expect(close(TS.employee(payType: .salary, annualSalary: 52_000, payFrequency: .biweekly).salaryPerPeriod, 2_000))
        #expect(close(TS.employee(payType: .salary, annualSalary: 48_000, payFrequency: .semimonthly).salaryPerPeriod, 2_000))
        #expect(close(TS.employee(payType: .salary, annualSalary: 62_400, payFrequency: .monthly).salaryPerPeriod, 5_200))
        #expect(PayFrequency.allCases.allSatisfy { $0.periodsPerYear > 0 })   // never a divide-by-zero
        // Hourly employees have no per-period salary.
        #expect(close(TS.employee(payType: .hourly, hourlyRate: 25, annualSalary: 99_000).salaryPerPeriod, 0))
        // Zero, negative (nonsense input, but it must divide through rather than crash) and huge.
        #expect(close(TS.employee(payType: .salary, annualSalary: 0, payFrequency: .weekly).salaryPerPeriod, 0))
        let negative = TS.employee(payType: .salary, annualSalary: -52_000, payFrequency: .weekly)
        #expect(close(negative.salaryPerPeriod, -1_000))
        #expect(negative.owedStatus == .none)                                  // negative accrual → nothing owed
        let huge = TS.employee(payType: .salary, annualSalary: 1_000_000_000, payFrequency: .monthly)
        #expect(close(huge.salaryPerPeriod, 83_333_333.33, eps: 0.01))
        #expect(huge.salaryPerPeriod.isFinite)
    }

    @Test func sortedTimeEntriesNewestFirst() {
        let employee = TS.employee()
        TS.logHours(employee, 1, date: TS.day(2026, 6, 1))
        TS.logHours(employee, 2, date: TS.day(2026, 6, 3))
        TS.logHours(employee, 3, date: TS.day(2026, 6, 2))
        #expect(employee.sortedTimeEntries.map(\.hours) == [2, 3, 1])   // 6/3, 6/2, 6/1
    }

    /// A time entry no paycheck covers stays owed — even if its date falls inside an already-paid
    /// period. The old date-based logic silently dropped such backdated/forgotten entries.
    @Test func unpaidHoursCountsBackdatedUncoveredEntries() {
        let employee = TS.employee(hourlyRate: 20)
        let covered = TS.logHours(employee, 8, date: TS.day(2026, 6, 3))
        let check = TS.paycheck(employee, gross: 160, hours: 8, periodStart: TS.day(2026, 6, 1),
                                periodEnd: TS.day(2026, 6, 7), payDate: TS.day(2026, 6, 8))
        covered.paycheck = check                             // the link is what marks it paid
        TS.logHours(employee, 3, date: TS.day(2026, 6, 4))   // backdated, NOT covered by the check
        #expect(close(employee.unpaidHours, 3))              // still owed
    }
}

@MainActor
struct NextPaydayTests {
    @Test func weekly() {
        let e = TS.employee(payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 5)) == TS.day(2026, 6, 5))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 6)) == TS.day(2026, 6, 12))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 12)) == TS.day(2026, 6, 12))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 1)) == TS.day(2026, 6, 5))   // before the anchor
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 20)) == TS.day(2026, 6, 26))
    }

    @Test func biweekly() {
        let e = TS.employee(payFrequency: .biweekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 5)) == TS.day(2026, 6, 5))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 6)) == TS.day(2026, 6, 19))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 19)) == TS.day(2026, 6, 19))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 5, 20)) == TS.day(2026, 5, 22))  // before the anchor
    }

    @Test func semimonthlyIs15thAndLastDay() {
        let e = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2026, 1, 1))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 1)) == TS.day(2026, 6, 15))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 15)) == TS.day(2026, 6, 15))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 16)) == TS.day(2026, 6, 30))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 30)) == TS.day(2026, 6, 30))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 2, 16)) == TS.day(2026, 2, 28))  // last day of Feb
    }

    @Test func monthlyUsesAnchorDayOfMonth() {
        let e = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 6, 10))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 5)) == TS.day(2026, 6, 10))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 10)) == TS.day(2026, 6, 10))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 6, 11)) == TS.day(2026, 7, 10))
    }

    @Test func currentPeriodStartIsDayAfterPreviousPayday() {
        // The previous payday is NOT inside the current period — a check paid ON payday
        // belongs to the period that ended that day, so the period starts the day after.
        let weekly = TS.employee(payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(weekly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 10)) == TS.day(2026, 6, 6))

        let biweekly = TS.employee(payFrequency: .biweekly, anchorPayday: TS.day(2026, 6, 5))
        #expect(biweekly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 10)) == TS.day(2026, 6, 6))

        let semimonthly = TS.employee(payFrequency: .semimonthly, anchorPayday: TS.day(2026, 1, 1))
        #expect(semimonthly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 20)) == TS.day(2026, 6, 16))

        let monthly = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 6, 10))
        #expect(monthly.currentPeriodStart(onOrBefore: TS.day(2026, 6, 20)) == TS.day(2026, 6, 11))
    }
}

@MainActor
struct EmployeeDefaultsTests {
    @Test func modelDefaultInitializers() {
        let employee = Employee()
        #expect(employee.firstName == "" && employee.lastName == "")
        #expect(employee.email == "" && employee.phone == "" && employee.notes == "")
        #expect(employee.payType == .hourly)
        #expect(employee.payFrequency == .weekly)
        #expect(employee.isActive)
        #expect(close(employee.hourlyRate, 0) && close(employee.annualSalary, 0))
        #expect(employee.timeEntries == nil && employee.paychecks == nil)

        let entry = TimeEntry()
        #expect(close(entry.hours, 0) && close(entry.rateSnapshot, 0) && close(entry.cost, 0))
        #expect(entry.note == "" && entry.employee == nil && entry.customer == nil)

        let check = Paycheck()
        #expect(close(check.grossAmount, 0) && close(check.hoursPaid, 0))
        #expect(check.method == .check && check.note == "" && check.employee == nil)
    }

    /// The no-argument overloads read the DEVICE clock and calendar — `.now` and the current
    /// year — so this one test deliberately uses `Calendar.current` to build its expectations.
    @Test func computedDefaultsUseNowAndCurrentYear() {
        let employee = TS.employee(payFrequency: .weekly, anchorPayday: TS.day(2026, 1, 2))
        // nextPayday() with no argument uses .now → a real date on/after today.
        #expect(employee.nextPayday() >= Calendar.current.startOfDay(for: Date()))

        // ytdGross()/ytdHours() with no argument use the current calendar year.
        let thisYear = Calendar.current.component(.year, from: Date())
        TS.paycheck(employee, gross: 500, periodStart: TS.day(thisYear, 1, 1),
                    periodEnd: TS.day(thisYear, 1, 7), payDate: TS.day(thisYear, 1, 8))
        TS.logHours(employee, 6, date: TS.day(thisYear, 1, 8))
        #expect(close(employee.ytdGross(), 500))
        #expect(close(employee.ytdHours(), 6))
    }
}

@MainActor
struct PayrollSummaryTests {
    @Test func nilWhenNoEmployees() {
        #expect(PayrollSummary.nextPayday(for: []) == nil)
    }

    @Test func nilWhenAllInactive() {
        let inactive = TS.employee(anchorPayday: TS.day(2026, 6, 5), isActive: false)
        #expect(PayrollSummary.nextPayday(for: [inactive]) == nil)
    }

    @Test func picksSoonestPaydayAndSumsThatDay() {
        let reference = TS.day(2026, 6, 1)
        let a = TS.employee(first: "A", payType: .hourly, hourlyRate: 20,
                            payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))
        TS.logHours(a, 10, date: reference)                                  // accrued 200, due 6/5
        let b = TS.employee(first: "B", payType: .salary, annualSalary: 52_000,
                            payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))  // accrued 1000, due 6/5
        let c = TS.employee(first: "C", payType: .hourly, hourlyRate: 50,
                            payFrequency: .monthly, anchorPayday: TS.day(2026, 6, 20))
        TS.logHours(c, 10, date: reference)                                  // accrued 500, but due 6/20

        let summary = PayrollSummary.nextPayday(for: [a, b, c], on: reference)
        #expect(summary?.date == TS.day(2026, 6, 5))
        #expect(summary != nil && close(summary!.total, 1_200))             // a + b only (not c)
        #expect(summary?.count == 2)
    }
}
