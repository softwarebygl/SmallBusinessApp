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
        let prefix = (business?.businessName).map { $0.isEmpty ? "" : "# \($0) — 1099 summary \(year)\n" } ?? ""
        return write(prefix + rows.joined(separator: "\n"), name: "GL-Subcontractor-1099-\(year).csv")
    }

    // MARK: - Payment ledger (one row per payment)

    private static func writeLedger(_ subs: [Subcontractor], year: Int) -> URL? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var rows = ["Subcontractor,Date,Amount,Method,For"]
        let payments = subs.flatMap { sub in
            (sub.payments ?? [])
                .filter { Calendar.current.component(.year, from: $0.date) == year }
                .map { (sub, $0) }
        }
        .sorted { $0.1.date < $1.1.date }

        for (sub, payment) in payments {
            let columns = [
                sub.payeeName,
                dateFormatter.string(from: payment.date),
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
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func csvField(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@\t".contains(first) {
            value = "'" + value
        }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
