//
//  EmployeeTests.swift
//  GLSmallBusinessTests
//
//  The Employees logic added this session: display helpers, the pay math (unpaid hours, accrued
//  gross, next payday for every frequency), YTD totals, the weekly-hours flag, TimeEntry cost, and
//  the cross-employee payroll roll-up. Built in memory via the `TS` builders — no container needed.
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

    @Test func salaryPerPeriod() {
        #expect(close(TS.employee(payType: .salary, annualSalary: 62_400, payFrequency: .monthly).salaryPerPeriod, 5_200))
        #expect(close(TS.employee(payType: .salary, annualSalary: 52_000, payFrequency: .weekly).salaryPerPeriod, 1_000))
        #expect(close(TS.employee(payType: .salary, annualSalary: 48_000, payFrequency: .semimonthly).salaryPerPeriod, 2_000))
        // Hourly employees have no per-period salary.
        #expect(close(TS.employee(payType: .hourly, hourlyRate: 25, annualSalary: 99_000).salaryPerPeriod, 0))
    }
}

@MainActor
struct TimeEntryTests {
    @Test func costFromSnapshot() {
        let employee = TS.employee(hourlyRate: 25)
        let entry = TS.logHours(employee, 8)            // snapshots 25
        #expect(close(entry.cost, 200))
    }

    @Test func costUsesSnapshotNotLaterRate() {
        let employee = TS.employee(hourlyRate: 25)
        let entry = TS.logHours(employee, 10, rate: 20) // snapshot taken at 20
        employee.hourlyRate = 40                         // raise afterward
        #expect(close(entry.cost, 200))                  // still 10 × 20
    }
}

@MainActor
struct EmployeePayMathTests {
    @Test func sortedTimeEntriesNewestFirst() {
        let employee = TS.employee()
        TS.logHours(employee, 1, date: TS.day(2026, 6, 1))
        TS.logHours(employee, 2, date: TS.day(2026, 6, 3))
        TS.logHours(employee, 3, date: TS.day(2026, 6, 2))
        #expect(employee.sortedTimeEntries.map(\.hours) == [2, 3, 1])   // 6/3, 6/2, 6/1
    }

    @Test func sortedPaychecksNewestFirst() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 100, periodStart: TS.day(2026, 5, 1),
                    periodEnd: TS.day(2026, 5, 7), payDate: TS.day(2026, 5, 8))
        TS.paycheck(employee, gross: 200, periodStart: TS.day(2026, 5, 8),
                    periodEnd: TS.day(2026, 5, 14), payDate: TS.day(2026, 5, 15))
        #expect(employee.sortedPaychecks.map(\.grossAmount) == [200, 100])
    }

    @Test func unpaidHoursCountsAllWithoutPaychecks() {
        let employee = TS.employee(hourlyRate: 20)
        TS.logHours(employee, 8, date: TS.day(2026, 6, 1))
        TS.logHours(employee, 7, date: TS.day(2026, 6, 2))
        #expect(close(employee.unpaidHours, 15))
    }

    @Test func unpaidHoursExcludesCoveredEntries() {
        let employee = TS.employee(hourlyRate: 20)
        let covered = TS.logHours(employee, 8, date: TS.day(2026, 6, 1))   // paid by the check below
        TS.logHours(employee, 5, date: TS.day(2026, 6, 10))                // not yet covered
        let check = TS.paycheck(employee, gross: 160, hours: 8, periodStart: TS.day(2026, 6, 1),
                                periodEnd: TS.day(2026, 6, 7), payDate: TS.day(2026, 6, 8))
        covered.paycheck = check                                           // the link is what marks it paid
        #expect(close(employee.unpaidHours, 5))
    }

    /// A time entry no paycheck covers stays owed — even if its date falls inside an already-paid
    /// period. The old date-based logic silently dropped such backdated/forgotten entries.
    @Test func unpaidHoursCountsBackdatedUncoveredEntries() {
        let employee = TS.employee(hourlyRate: 20)
        let covered = TS.logHours(employee, 8, date: TS.day(2026, 6, 3))
        let check = TS.paycheck(employee, gross: 160, hours: 8, periodStart: TS.day(2026, 6, 1),
                                periodEnd: TS.day(2026, 6, 7), payDate: TS.day(2026, 6, 8))
        covered.paycheck = check
        TS.logHours(employee, 3, date: TS.day(2026, 6, 4))   // backdated, NOT covered by the check
        #expect(close(employee.unpaidHours, 3))              // still owed
    }

    @Test func accruedGrossHourly() {
        let employee = TS.employee(payType: .hourly, hourlyRate: 30)
        TS.logHours(employee, 10)
        TS.logHours(employee, 5)
        #expect(close(employee.accruedGross, 450))   // 15 × 30
    }

    @Test func accruedGrossSalaryIgnoresHours() {
        let employee = TS.employee(payType: .salary, annualSalary: 52_000, payFrequency: .weekly)
        TS.logHours(employee, 40)                     // hours don't change a salaried accrual
        #expect(close(employee.accruedGross, 1_000))  // one weekly period
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

    @Test func monthlyClampsToShortMonth() {
        let e = TS.employee(payFrequency: .monthly, anchorPayday: TS.day(2026, 1, 31))
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 2, 1)) == TS.day(2026, 2, 28))   // Feb 2026 has 28 days
        #expect(e.nextPayday(onOrAfter: TS.day(2026, 3, 1)) == TS.day(2026, 3, 31))
    }
}

@MainActor
struct EmployeeYTDTests {
    @Test func ytdGrossFiltersByYear() {
        let employee = TS.employee()
        TS.paycheck(employee, gross: 1_000, periodStart: TS.day(2025, 12, 20),
                    periodEnd: TS.day(2025, 12, 26), payDate: TS.day(2025, 12, 27))
        TS.paycheck(employee, gross: 1_500, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        TS.paycheck(employee, gross: 500, periodStart: TS.day(2026, 1, 8),
                    periodEnd: TS.day(2026, 1, 14), payDate: TS.day(2026, 1, 15))
        #expect(close(employee.ytdGross(year: 2026), 2_000))
        #expect(close(employee.ytdGross(year: 2025), 1_000))
    }

    @Test func ytdHoursFiltersByYear() {
        let employee = TS.employee()
        TS.logHours(employee, 8, date: TS.day(2025, 12, 31))
        TS.logHours(employee, 6, date: TS.day(2026, 1, 2))
        TS.logHours(employee, 4, date: TS.day(2026, 3, 5))
        #expect(close(employee.ytdHours(year: 2026), 10))
        #expect(close(employee.ytdHours(year: 2025), 8))
    }

    @Test func hoursInWeekScopesToTheWeek() {
        let employee = TS.employee()
        TS.logHours(employee, 8, date: TS.day(2026, 6, 15))   // Mon — same week as 6/17
        TS.logHours(employee, 8, date: TS.day(2026, 6, 17))   // Wed
        TS.logHours(employee, 9, date: TS.day(2026, 6, 22))   // following week
        #expect(close(employee.hoursInWeek(of: TS.day(2026, 6, 17)), 16))
    }

    @Test func overFortyFlag() {
        let over = TS.employee()
        for _ in 0..<5 { TS.logHours(over, 9, date: .now) }    // 45 hrs this week
        #expect(over.isOverFortyThisWeek)

        let under = TS.employee()
        TS.logHours(under, 30, date: .now)
        #expect(!under.isOverFortyThisWeek)
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

    @Test func computedsHandleNilRelationships() {
        // A fresh Employee has nil timeEntries/paychecks — exercises the `?? []` fallbacks.
        let e = Employee()
        #expect(e.sortedTimeEntries.isEmpty)
        #expect(e.sortedPaychecks.isEmpty)
        #expect(close(e.unpaidHours, 0))
        #expect(close(e.accruedGross, 0))
        #expect(close(e.ytdGross(year: 2026), 0))
        #expect(close(e.ytdHours(year: 2026), 0))
        #expect(close(e.hoursInWeek(of: TS.day(2026, 6, 17)), 0))
        #expect(!e.isOverFortyThisWeek)
    }

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

    @Test func excludesInactiveFromTheRollup() {
        let reference = TS.day(2026, 6, 1)
        let active = TS.employee(first: "On", payType: .salary, annualSalary: 26_000,
                                 payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5))   // 500/period
        let inactive = TS.employee(first: "Off",
                                   payFrequency: .weekly, anchorPayday: TS.day(2026, 6, 5), isActive: false)
        TS.logHours(inactive, 40, date: reference)
        let summary = PayrollSummary.nextPayday(for: [active, inactive], on: reference)
        #expect(summary?.count == 1)
        #expect(summary != nil && close(summary!.total, 500))
    }
}
