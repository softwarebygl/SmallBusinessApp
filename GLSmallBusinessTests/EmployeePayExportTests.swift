//
//  EmployeePayExportTests.swift
//  GLSmallBusinessTests
//
//  The year-end accountant handoff: a wage-summary CSV + a paycheck-ledger CSV. Mirrors
//  StatsExportTests — verifies headers, content, year filtering, the active/paid inclusion rule,
//  and the same CSV safety (formula-injection guard, comma quoting).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct EmployeePayExportTests {
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func wages(_ files: [URL]) -> String { files.first { $0.lastPathComponent.contains("Wages") }.map(read) ?? "" }
    private func ledger(_ files: [URL]) -> String { files.first { $0.lastPathComponent.contains("Paychecks") }.map(read) ?? "" }

    @Test func producesWageSummaryAndLedger() {
        let employee = TS.employee(first: "Jason", last: "Garcia", payType: .hourly, hourlyRate: 28)
        TS.paycheck(employee, gross: 1_120, hours: 40, periodStart: TS.day(2026, 6, 1),
                    periodEnd: TS.day(2026, 6, 7), payDate: TS.day(2026, 6, 8))
        let files = EmployeePayExport.files(employees: [employee], year: 2026, business: nil)
        #expect(files.count == 2)

        let w = wages(files)
        #expect(w.contains("Employee,Pay type,Rate,Gross paid 2026,Hours 2026,Paychecks 2026"))
        #expect(w.contains("Jason Garcia"))
        #expect(w.contains("Hourly"))
        #expect(w.contains("28.00/hr"))
        #expect(w.contains("1120.00"))

        let l = ledger(files)
        #expect(l.contains("Employee,Paid on,Period start,Period end,Gross,Hours,Method,Note"))
        #expect(l.contains("2026-06-08"))
        #expect(l.contains("Check"))
    }

    @Test func salaryRateFormat() {
        let employee = TS.employee(first: "Devin", last: "Odom", payType: .salary,
                                   annualSalary: 62_400, payFrequency: .monthly)
        let w = wages(EmployeePayExport.files(employees: [employee], year: 2026, business: nil))
        #expect(w.contains("Salary"))
        #expect(w.contains("62400.00/yr"))
    }

    @Test func includesActiveAndPaidButExcludesInactiveUnpaid() {
        let active = TS.employee(first: "A", last: "Active")
        let inactiveUnpaid = TS.employee(first: "B", last: "Idle", isActive: false)
        let inactivePaid = TS.employee(first: "C", last: "Paid", isActive: false)
        TS.paycheck(inactivePaid, gross: 900, periodStart: TS.day(2026, 2, 1),
                    periodEnd: TS.day(2026, 2, 7), payDate: TS.day(2026, 2, 8))

        let w = wages(EmployeePayExport.files(employees: [active, inactiveUnpaid, inactivePaid],
                                              year: 2026, business: nil))
        #expect(w.contains("A Active"))    // active → included
        #expect(w.contains("C Paid"))      // inactive but paid this year → included (needs a W-2)
        #expect(!w.contains("B Idle"))     // inactive + unpaid → excluded
    }

    @Test func ledgerFiltersByYear() {
        let employee = TS.employee(first: "Year", last: "Filter")
        TS.paycheck(employee, gross: 100, periodStart: TS.day(2025, 12, 20),
                    periodEnd: TS.day(2025, 12, 26), payDate: TS.day(2025, 12, 27))
        TS.paycheck(employee, gross: 200, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        let l = ledger(EmployeePayExport.files(employees: [employee], year: 2026, business: nil))
        #expect(l.contains("2026-01-08"))
        #expect(!l.contains("2025-12-27"))
    }

    @Test func ledgerSortsByPayDate() {
        // Two paychecks in one year exercises the ledger's sort comparator.
        let employee = TS.employee(first: "Multi", last: "Pay")
        TS.paycheck(employee, gross: 200, periodStart: TS.day(2026, 1, 8),
                    periodEnd: TS.day(2026, 1, 14), payDate: TS.day(2026, 1, 15))
        TS.paycheck(employee, gross: 100, periodStart: TS.day(2026, 1, 1),
                    periodEnd: TS.day(2026, 1, 7), payDate: TS.day(2026, 1, 8))
        let lines = ledger(EmployeePayExport.files(employees: [employee], year: 2026, business: nil))
            .split(separator: "\n")
        let earlier = lines.firstIndex { $0.contains("2026-01-08") }
        let later = lines.firstIndex { $0.contains("2026-01-15") }
        #expect(earlier != nil && later != nil && earlier! < later!)   // sorted ascending by pay date
    }

    @Test func neutralizesFormulaInjection() {
        // A name starting with "=" would execute as a formula in Excel/Numbers.
        let employee = TS.employee(first: "=cmd", last: "")
        let w = wages(EmployeePayExport.files(employees: [employee], year: 2026, business: nil))
        #expect(w.contains("'=cmd"))
    }

    @Test func emptyBusinessNameAddsNoHeaderLine() {
        let profile = BusinessProfile()   // businessName defaults to ""
        let employee = TS.employee(first: "Pat", last: "Lee")
        let w = wages(EmployeePayExport.files(employees: [employee], year: 2026, business: profile))
        #expect(!w.hasPrefix("#"))        // no "# <business> — employee wages" comment line
        #expect(w.contains("Pat Lee"))
    }

    @Test func quotesCommasAndIncludesBusinessName() {
        let profile = BusinessProfile()
        profile.businessName = "Gold Life, LLC"
        let employee = TS.employee(first: "Sam", last: "O'Neil, Jr")
        let w = wages(EmployeePayExport.files(employees: [employee], year: 2026, business: profile))
        #expect(w.contains("# Gold Life, LLC"))           // business name header (raw, comment line)
        #expect(w.contains("\"Sam O'Neil, Jr\""))         // CSV field quoted because it has a comma
    }
}
