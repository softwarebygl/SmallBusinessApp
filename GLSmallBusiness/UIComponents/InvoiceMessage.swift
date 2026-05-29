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
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"150\" style=\"display:block;margin:0 0 18px;max-width:150px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        let job = esc(trimmed(invoice.jobTitle))
        var summary = ""
        if !job.isEmpty { summary += "<strong>Project:</strong> \(job)<br>" }
        if !number.isEmpty { summary += "<strong>Invoice:</strong> \(number)<br>" }
        summary += "<strong>Total:</strong> \(total)<br>"
        if invoice.amountPaid > 0 {
            summary += "<strong>Paid:</strong> \(esc(invoice.amountPaid.formatted(.currency(code: "USD"))))<br>"
        }
        summary += "<strong>Balance:</strong> \(balance)<br>"
        if invoice.hasAmountDueRequest {
            let dueNow = esc(invoice.currentAmountDue.formatted(.currency(code: "USD")))
            let detail = trimmed(invoice.amountDueDetail)
            summary += "<strong style=\"color:#9C7A2E;\">Amount due now: \(dueNow)</strong>"
            if !detail.isEmpty { summary += " — \(esc(detail))" }
            summary += "<br>"
        }
        summary += "<strong>Due by:</strong> \(due)"

        var signature = "<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if !email.isEmpty { signature += "<br>\(esc(email))" }
        if !license.isEmpty { signature += "<br>License #\(esc(license))" }

        return """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;color:#1c1c1e;font-size:15px;line-height:1.5;max-width:560px;">
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 14px;">\(htmlText(intro(invoice: invoice, business: business)))</p>
        <p style="margin:0 0 14px;">\(summary)</p>
        <p style="margin:0 0 14px;">\(htmlText(closing(invoice: invoice, business: business)))</p>
        <p style="margin:18px 0 0;">\(signature)</p>
        </div>
        """
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
