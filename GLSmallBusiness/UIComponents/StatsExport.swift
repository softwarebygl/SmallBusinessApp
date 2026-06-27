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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var rows = ["Date,Vendor,Category,Amount,Job,Notes"]
        for receipt in receipts {
            let columns = [
                dateFormatter.string(from: receipt.date),
                receipt.vendor,
                receipt.category,
                String(format: "%.2f", receipt.total),
                receipt.customer?.listDisplayName ?? "Business",
                receipt.notes,
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        return write(rows.joined(separator: "\n"), name: "GL-Receipts-\(slug(period)).csv")
    }

    // MARK: - Tax summary

    private static func writeSummary(_ summary: StatsSummary, period: StatsPeriod, business: BusinessProfile?) -> URL? {
        func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

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
        lines.append("NET (collected − expenses): \(money(summary.net))")
        return write(lines.joined(separator: "\n"), name: "GL-Summary-\(slug(period)).txt")
    }

    // MARK: - Helpers

    private static func slug(_ period: StatsPeriod) -> String {
        switch period {
        case .all: return "all-time"
        case .year(let year): return String(year)
        case .month(let year, let month): return String(format: "%04d-%02d", year, month)
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
