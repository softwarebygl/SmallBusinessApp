//
//  StatsExport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import Foundation

/// Builds the year-end files an accountant needs: a receipts CSV (no images) plus a readable
/// tax summary (income collected, sales tax, expenses by category, net). Both are scoped to the
/// selected period and written to temp files for sharing/emailing.
enum StatsExport {
    static func files(
        period: StatsPeriod,
        invoices: [Invoice],
        estimates: [Estimate],
        receipts: [Receipt],
        business: BusinessProfile?
    ) -> [URL] {
        let periodReceipts = receipts
            .filter { period.contains($0.date) }
            .sorted { $0.date < $1.date }
        let summary = StatsEngine.summary(period: period, invoices: invoices, estimates: estimates, receipts: receipts)

        var urls: [URL] = []
        if let receiptsURL = writeReceiptsCSV(periodReceipts, period: period) { urls.append(receiptsURL) }
        if let summaryURL = writeSummary(summary, period: period, business: business) { urls.append(summaryURL) }
        return urls
    }

    // MARK: - Receipts CSV

    private static func writeReceiptsCSV(_ receipts: [Receipt], period: StatsPeriod) -> URL? {
        var rows = ["Date,Vendor,Category,Amount,Customer,Notes"]
        for receipt in receipts {
            let columns = [
                csvDate(receipt.date),
                receipt.vendor,
                receipt.category,
                DomainMoney.plain(receipt.total),
                receipt.customer?.listDisplayName ?? "Business",
                receipt.notes,
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        return write(rows.joined(separator: "\n"), name: "GL-Receipts-\(slug(period)).csv")
    }

    // MARK: - Tax summary

    private static func writeSummary(_ summary: StatsSummary, period: StatsPeriod, business: BusinessProfile?) -> URL? {
        func money(_ value: Double) -> String { value.formatted(.money) }

        var lines: [String] = []
        if let business, !business.businessName.isEmpty { lines.append(business.businessName) }
        lines.append("Tax summary — \(period.label)")
        lines.append("")
        lines.append("INCOME")
        lines.append("  Collected (cash received): \(money(summary.collected))")
        lines.append("  Invoiced (billed): \(money(summary.invoiced))")
        lines.append("  Sales tax (on invoices): \(money(summary.salesTax))")
        lines.append("  Outstanding (unpaid): \(money(summary.outstanding))")
        lines.append("")
        lines.append("EXPENSES (from receipts)")
        if summary.expensesByCategory.isEmpty {
            lines.append("  (none)")
        } else {
            for category in summary.expensesByCategory {
                lines.append("  \(category.category): \(money(category.amount))")
            }
        }
        lines.append("  Total expenses: \(money(summary.expenses))")
        lines.append("")
        if summary.processingFees > 0 {
            lines.append("PAYMENT PROCESSING FEES (deductible)")
            lines.append("  Total: \(money(summary.processingFees))")
            lines.append("")
            lines.append("NET (collected − expenses − fees): \(money(summary.net))")
        } else {
            lines.append("NET (collected − expenses): \(money(summary.net))")
        }
        return write(lines.joined(separator: "\n"), name: "GL-Summary-\(slug(period)).txt")
    }

    // MARK: - Helpers

    /// A date in an accountant CSV: 2026-10-03, always — the Gregorian year with POSIX digits, in
    /// the phone's time zone, whatever the phone's language, region or calendar. A spreadsheet
    /// reads it as a date; the phone's settings used to leak in (a Buddhist-calendar phone wrote
    /// 2569-10-03, QA 2026-10-03 F139). Every accountant export uses this one rule
    /// (EmployeePayExport, SubPayExport).
    nonisolated static func csvDate(_ date: Date) -> String {
        date.formatted(csvDateStyle)
    }

    private nonisolated static let csvDateStyle = Date.VerbatimFormatStyle(
        format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .autoupdatingCurrent,
        calendar: Calendar(identifier: .gregorian))

    private static func slug(_ period: StatsPeriod) -> String {
        switch period {
        case .all: return "all-time"
        case .year(let year): return String(year)
        case .month(let year, let month): return String(format: "%04d-%02d", year, month)
        case .days(let from, let to):
            let format = Date.ISO8601FormatStyle().year().month().day()
            return "\(min(from, to).formatted(format))_\(max(from, to).formatted(format))"
        }
    }

    private static func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            let content = name.hasSuffix(".csv") ? "\u{FEFF}" + text : text   // UTF-8 BOM for Excel-on-Windows
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func csvField(_ field: String) -> String { CSV.field(field) }
}
