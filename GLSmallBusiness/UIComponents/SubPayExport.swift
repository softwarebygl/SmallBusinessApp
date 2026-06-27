//
//  SubPayExport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Year-end subcontractor handoff for the accountant: a 1099 summary (each sub paid this year, the
//  total, and whether they cross the $600 1099-NEC threshold) plus a payment ledger. The real
//  1099-NEC forms (Copy B/C) come from the tax-document round; this CSV covers the actual filing.
//  Mirrors EmployeePayExport / StatsExport — temp files returned as URLs for one bundled share.
//

import Foundation

enum SubPayExport {
    /// 1099 summary CSV + payment-ledger CSV for `year`. Only subs paid during the year appear.
    static func files(subcontractors: [Subcontractor], year: Int, business: BusinessProfile?) -> [URL] {
        let paid = subcontractors
            .filter { $0.totalPaid(year: year) > 0 }
            .sorted { $0.payeeName.localizedCaseInsensitiveCompare($1.payeeName) == .orderedAscending }

        var urls: [URL] = []
        if let summary = writeSummary(paid, year: year, business: business) { urls.append(summary) }
        if let ledger = writeLedger(paid, year: year) { urls.append(ledger) }
        return urls
    }

    // MARK: - 1099 summary (one row per paid sub)

    private static func writeSummary(_ subs: [Subcontractor], year: Int, business: BusinessProfile?) -> URL? {
        var rows = ["Subcontractor,Business,TIN type,TIN,Address,Total paid \(year),1099-NEC required"]
        for sub in subs {
            let columns = [
                sub.payeeName,
                sub.businessName,
                sub.w9TINType?.label ?? "",
                sub.secureTIN,
                sub.address.formattedMultiline.replacingOccurrences(of: "\n", with: ", "),
                String(format: "%.2f", sub.totalPaid(year: year)),
                sub.requires1099(year: year) ? "Yes" : "No",
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        // No in-band "# business — year" banner: CSV has no portable comment row, so Excel/Sheets treat
        // it as a header/data row (and a comma in the business name splits it into two cells). The
        // business + year are already in the filename.
        return write(rows.joined(separator: "\n"), name: "GL-Subcontractor-1099-\(year).csv")
    }

    // MARK: - Payment ledger (one row per payment)

    private static func writeLedger(_ subs: [Subcontractor], year: Int) -> URL? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var rows = ["Subcontractor,Paid on,Amount,Method,For"]
        // The 1099 ledger is money actually paid in the year (cash basis) — owed-but-unpaid is excluded.
        let payments = subs.flatMap { sub in
            (sub.payments ?? [])
                .filter { $0.isPaid && Calendar.current.component(.year, from: $0.paidDate ?? $0.date) == year }
                .map { (sub, $0) }
        }
        .sorted { ($0.1.paidDate ?? $0.1.date) < ($1.1.paidDate ?? $1.1.date) }

        for (sub, payment) in payments {
            let columns = [
                sub.payeeName,
                dateFormatter.string(from: payment.paidDate ?? payment.date),
                String(format: "%.2f", payment.amount),
                payment.method.label,
                payment.detail,
            ].map(csvField)
            rows.append(columns.joined(separator: ","))
        }
        return write(rows.joined(separator: "\n"), name: "GL-Subcontractor-Payments-\(year).csv")
    }

    // MARK: - Helpers (same conventions as StatsExport / EmployeePayExport)

    private static func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            // Prepend a UTF-8 BOM to CSVs so Excel-on-Windows renders accented names (José, Nguyễn)
            // correctly instead of falling back to Windows-1252. Invisible in Numbers/Sheets.
            let content = name.hasSuffix(".csv") ? "\u{FEFF}" + text : text
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func csvField(_ field: String) -> String { CSV.field(field) }
}
