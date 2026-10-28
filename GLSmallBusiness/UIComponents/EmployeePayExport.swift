//
//  EmployeePayExport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The year-end employee handoff for your accountant/payroll service: a per-employee wage summary
//  and a line-by-line paycheck ledger, both as CSVs scoped to a year. This is the data they need to
//  file the W-2s — the app intentionally does NOT file or generate W-2s itself (it tracks gross pay,
//  not tax withholding). Mirrors StatsExport: temp files returned as URLs for one bundled share/email.
//  The screen generates them only at export time and deletes them when the share sheet closes; on
//  device they're written with complete protection so they're encrypted at rest while locked.
//

import Foundation

enum EmployeePayExport {
    /// Wage-summary CSV + paycheck-ledger CSV for `year`. Inactive employees are included if they
    /// were paid during the year (they still need a W-2).
    static func files(employees: [Employee], year: Int, business: BusinessProfile?) -> [URL] {
        let relevant = employees.filter { $0.isActive || $0.ytdGross(year: year) > 0 || $0.ytdHours(year: year) > 0 }
            .sorted { $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending }

        var urls: [URL] = []
        if let summary = writeWageSummary(relevant, year: year, business: business) { urls.append(summary) }
        if let ledger = writePaycheckLedger(relevant, year: year) { urls.append(ledger) }
        return urls
    }

    // MARK: - Per-employee wage summary

    private static func writeWageSummary(_ employees: [Employee], year: Int, business: BusinessProfile?) -> URL? {
        var rows = ["Employee,Pay type,Rate,Gross paid \(year),Hours \(year),Paychecks \(year)"]
        for employee in employees {
            let rate = employee.payType == .hourly
                ? DomainMoney.plain(employee.hourlyRate) + "/hr"
                : DomainMoney.plain(employee.annualSalary) + "/yr"
            let payChecks = employee.liveRows(employee.paychecks).filter { Calendar.current.component(.year, from: $0.payDate) == year }
            let columns = [
                employee.fullName.isEmpty ? employee.listDisplayName : employee.fullName,
                employee.payType.englishLabel,
                rate,
                DomainMoney.plain(employee.ytdGross(year: year)),
                String(format: "%.2f", employee.ytdHours(year: year)),
                String(payChecks.count),
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        // No in-band "# business — year" banner (CSV has no portable comment row; it shifts/splits the
        // header). Business + year are in the filename.
        return write(rows.joined(separator: "\n"), name: "GL-Employee-Wages-\(year).csv")
    }

    // MARK: - Paycheck ledger

    private static func writePaycheckLedger(_ employees: [Employee], year: Int) -> URL? {
        var rows = ["Employee,Paid on,Period start,Period end,Gross,Hours,Method,Note"]
        let checks = employees.flatMap { employee in
            employee.liveRows(employee.paychecks)
                .filter { Calendar.current.component(.year, from: $0.payDate) == year }
                .map { (employee, $0) }
        }
        .sorted { $0.1.payDate < $1.1.payDate }

        for (employee, check) in checks {
            let columns = [
                employee.fullName.isEmpty ? employee.listDisplayName : employee.fullName,
                StatsExport.csvDate(check.payDate),
                StatsExport.csvDate(check.payPeriodStart),
                StatsExport.csvDate(check.payPeriodEnd),
                DomainMoney.plain(check.grossAmount),
                String(format: "%.2f", check.hoursPaid),
                check.method.englishLabel,
                check.note,
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        return write(rows.joined(separator: "\n"), name: "GL-Employee-Paychecks-\(year).csv")
    }

    // MARK: - Helpers (same conventions as StatsExport)

    private static func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            let content = name.hasSuffix(".csv") ? "\u{FEFF}" + text : text   // UTF-8 BOM for Excel-on-Windows
            #if os(macOS)
            try content.write(to: url, atomically: true, encoding: .utf8)
            #else
            // Wage data (names + amounts): complete protection keeps the CSV encrypted at rest
            // whenever the device is locked, for the short window before the screen deletes it.
            try Data(content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            #endif
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func csvField(_ field: String) -> String { CSV.field(field) }
}
