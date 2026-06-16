//
//  InvoiceMessage.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import UIKit

/// Builds the branded subject, greeting, and sign-off used when an invoice is emailed or texted.
/// Mirrors `EstimateMessage` and reuses its brand-logo helpers. Invoice wording uses prepared
/// defaults (not the editable estimate wording, since the phrasing differs).
enum InvoiceMessage {

    static let defaultIntro = "Thank you for your business. Your invoice is attached for your review."
    static let defaultClosing = "Please remit payment by the due date. If you have any questions, just reply to this message. Thank you,"

    /// The custom intro if set, otherwise a default that names the job when there is one.
    static func intro(invoice: Invoice, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.invoiceMessageIntro)
        if !custom.isEmpty { return custom }
        let job = trimmed(invoice.jobTitle)
        if job.isEmpty { return defaultIntro }
        return "Thank you for your business. Here's your invoice for \(job)."
    }

    static func closing(invoice: Invoice, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.invoiceMessageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    // MARK: - Subject

    static func subject(invoice: Invoice, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.invoiceMessageSubject)
        if !custom.isEmpty { return custom }
        let company = trimmed(business?.businessName)
        let number = trimmed(invoice.number)
        switch (company.isEmpty, number.isEmpty) {
        case (false, false): return "Invoice \(number) from \(company)"
        case (false, true):  return "Your invoice from \(company)"
        case (true, false):  return "Your invoice \(number)"
        case (true, true):   return "Your invoice"
        }
    }

    // MARK: - Plain-text body (SMS / iMessage)

    static func plainBody(invoice: Invoice, business: BusinessProfile?) -> String {
        let name = greetingName(invoice)
        let company = trimmed(business?.businessName)
        let number = trimmed(invoice.number)
        let job = trimmed(invoice.jobTitle)
        let due = invoice.dueDate.formatted(date: .abbreviated, time: .omitted)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        var lines: [String] = []
        if !job.isEmpty { lines.append("Project: \(job)") }
        if !number.isEmpty { lines.append(number) }
        lines.append("Total: \(invoice.total.formatted(.currency(code: "USD")))")
        if invoice.amountPaid > 0 {
            lines.append("Paid: \(invoice.amountPaid.formatted(.currency(code: "USD")))")
        }
        lines.append("Balance: \(invoice.balanceDue.formatted(.currency(code: "USD")))")
        if invoice.hasAmountDueRequest {
            let dueNow = invoice.currentAmountDue.formatted(.currency(code: "USD"))
            let detail = trimmed(invoice.amountDueDetail)
            lines.append(detail.isEmpty ? "Amount due now: \(dueNow)" : "Amount due now: \(dueNow) — \(detail)")
        }
        lines.append("Due by: \(due)")
        let summary = lines.joined(separator: "\n")

        return """
        Hi \(name),

        \(intro(invoice: invoice, business: business))

        \(summary)

        \(closing(invoice: invoice, business: business))\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(invoice: Invoice, business: BusinessProfile?) -> String {
        let name = greetingName(invoice)
        let company = trimmed(business?.businessName)
        let number = esc(trimmed(invoice.number))
        let total = esc(invoice.total.formatted(.currency(code: "USD")))
        let balance = esc(invoice.balanceDue.formatted(.currency(code: "USD")))
        let due = esc(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))
        let phone = trimmed(business?.phone)
        let email = trimmed(business?.email)
        let license = trimmed(business?.licenseNumber)

        var logoTag = ""
        if let data = EstimateMessage.logoPNGData(business: business) {
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"140\" style=\"display:block;margin:0 0 20px;max-width:140px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        let job = esc(trimmed(invoice.jobTitle))
        var rows: [(label: String, value: String, strong: Bool)] = []
        if !job.isEmpty { rows.append(("Project", job, false)) }
        if !number.isEmpty { rows.append(("Invoice", number, false)) }
        rows.append(("Total", total, true))
        if invoice.amountPaid > 0 {
            rows.append(("Paid", esc(invoice.amountPaid.formatted(.currency(code: "USD"))), false))
        }
        rows.append(("Balance", balance, true))
        if invoice.hasAmountDueRequest {
            let detail = trimmed(invoice.amountDueDetail)
            let label = detail.isEmpty ? "Amount due now" : "Amount due now (\(esc(detail)))"
            rows.append((label, esc(invoice.currentAmountDue.formatted(.currency(code: "USD"))), true))
        }
        rows.append(("Due by", due, false))

        var signature = "<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if !email.isEmpty { signature += "<br>\(esc(email))" }
        if !license.isEmpty { signature += "<br>License #\(esc(license))" }

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(invoice: invoice, business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">\(htmlText(closing(invoice: invoice, business: business)))</p>
        <p style="margin:20px 0 0;">\(signature)</p>
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Helpers

    private static func greetingName(_ invoice: Invoice) -> String {
        let first = trimmed(invoice.customerFirstName)
        return first.isEmpty ? "there" : first
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func esc(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escapes user-entered prose for HTML and preserves their line breaks as `<br>`.
    private static func htmlText(_ string: String) -> String {
        esc(string).replacingOccurrences(of: "\n", with: "<br>")
    }
}
