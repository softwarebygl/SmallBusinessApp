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

    static func plainBody(invoice: Invoice, business: BusinessProfile?, payLinkURL: String? = nil) -> String {
        let name = greetingName(invoice)
        let company = trimmed(business?.businessName)
        let number = trimmed(invoice.number)
        let job = trimmed(invoice.jobTitle)
        let due = invoice.dueDate.formatted(.englishMessageDate)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        var lines: [String] = []
        if !job.isEmpty { lines.append("Project: \(job)") }
        if !number.isEmpty { lines.append(number) }
        lines.append("Total: \(invoice.total.formatted(.money))")
        if invoice.amountPaid > 0 {
            lines.append("Paid: \(invoice.amountPaid.formatted(.money))")
        }
        // Paid more than the total (QA F85): what is owed back, so Paid − Credit due == Total.
        if invoice.creditDue > 0 {
            lines.append("Credit due: \(invoice.creditDue.formatted(.money))")
        }
        lines.append("Balance: \(invoice.balanceDue.formatted(.money))")
        if invoice.hasAmountDueRequest {
            let dueNow = invoice.currentAmountDue.formatted(.money)
            let detail = trimmed(invoice.amountDueDetail)
            lines.append(detail.isEmpty ? "Amount due now: \(dueNow)" : "Amount due now: \(dueNow) — \(detail)")
        }
        lines.append("Due by: \(due)")
        let summary = lines.joined(separator: "\n")
        let payURL = trimmed(payLinkURL)
        let paySection = payURL.isEmpty ? "" : "\n\nPay online: \(payURL)"

        var zelleLines: [String] = []
        if invoice.includeZelle, let business, business.zelleIsConfigured {
            zelleLines.append("Pay with Zelle:")
            if !business.zelleTag.isEmpty { zelleLines.append("  Name/Tag: \(business.zelleTag)") }
            if !business.zelleEmail.isEmpty { zelleLines.append("  Email: \(business.zelleEmail)") }
            if !business.zellePhone.isEmpty { zelleLines.append("  Phone: \(business.zellePhone)") }
            if zelleLines.count == 1, business.zelleQRCodeData != nil {
                zelleLines.append("  Scan the Zelle QR code on the attached invoice PDF.")
            }
        }
        let zelleSection = zelleLines.count > 1 ? "\n\n" + zelleLines.joined(separator: "\n") : ""

        return """
        Hi \(name),

        \(intro(invoice: invoice, business: business))

        \(summary)\(paySection)\(zelleSection)

        \(closing(invoice: invoice, business: business))\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(invoice: Invoice, business: BusinessProfile?, payLinkURL: String? = nil) -> String {
        let name = greetingName(invoice)
        let number = esc(trimmed(invoice.number))
        let total = esc(invoice.total.formatted(.money))
        let balance = esc(invoice.balanceDue.formatted(.money))
        let due = esc(invoice.dueDate.formatted(.englishMessageDate))

        let logoTag = EmailSignature.logoTag(business: business)

        let job = esc(trimmed(invoice.jobTitle))
        var rows: [(label: String, value: String, strong: Bool)] = []
        if !job.isEmpty { rows.append(("Project", job, false)) }
        if !number.isEmpty { rows.append(("Invoice", number, false)) }
        rows.append(("Total", total, true))
        if invoice.amountPaid > 0 {
            rows.append(("Paid", esc(invoice.amountPaid.formatted(.money)), false))
        }
        if invoice.creditDue > 0 {
            rows.append(("Credit due", esc(invoice.creditDue.formatted(.money)), true))
        }
        rows.append(("Balance", balance, true))
        if invoice.hasAmountDueRequest {
            let detail = trimmed(invoice.amountDueDetail)
            let label = detail.isEmpty ? "Amount due now" : "Amount due now (\(esc(detail)))"
            rows.append((label, esc(invoice.currentAmountDue.formatted(.money)), true))
        }
        rows.append(("Due by", due, false))

        let signature = EmailSignature.block(business: business)

        let payURL = trimmed(payLinkURL)
        let payButton = payURL.isEmpty ? "" : """
        <p style="margin:0 0 18px;text-align:center;"><a href="\(esc(payURL))" style="display:inline-block;background:#9C7A2E;color:#ffffff;text-decoration:none;font-weight:600;font-size:16px;padding:13px 28px;border-radius:8px;">Pay this invoice</a></p>
        """

        let zelleBlock: String
        if invoice.includeZelle, let business, business.zelleIsConfigured {
            var items: [String] = []
            if !business.zelleTag.isEmpty { items.append("Name/Tag: <strong>\(esc(business.zelleTag))</strong>") }
            if !business.zelleEmail.isEmpty { items.append("Email: <strong>\(esc(business.zelleEmail))</strong>") }
            if !business.zellePhone.isEmpty { items.append("Phone: <strong>\(esc(business.zellePhone))</strong>") }
            if items.isEmpty, business.zelleQRCodeData != nil {
                items.append("Scan the Zelle QR code on the attached invoice PDF.")
            }
            if items.isEmpty {
                zelleBlock = ""
            } else {
                zelleBlock = """
                <div style="margin:0 0 18px;padding:12px 16px;background:#f8f6f0;border-left:4px solid #9C7A2E;border-radius:4px;">
                  <p style="margin:0 0 6px;font-weight:600;color:#9C7A2E;">Pay with Zelle</p>
                  <p style="margin:0;font-size:14px;line-height:1.5;">\(items.joined(separator: "<br>"))</p>
                </div>
                """
            }
        } else {
            zelleBlock = ""
        }

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(invoice: invoice, business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        \(payButton)
        \(zelleBlock)
        <p style="margin:0 0 16px;">\(htmlText(closing(invoice: invoice, business: business)))</p>
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
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

// MARK: - Dates in English-pinned messages

extension FormatStyle where Self == Date.FormatStyle {
    /// A date in a customer message that is written in English whatever the app's language (the
    /// estimate, invoice and payment-receipt texts and emails): "Oct 3, 2026" — US English on the
    /// Gregorian calendar. The phone's settings used to leak in: "3 oct. 2569 E.B." on a French
    /// phone with the Buddhist calendar (QA 2026-10-03 F139).
    nonisolated static var englishMessageDate: Self {
        Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"),
                         calendar: Calendar(identifier: .gregorian), timeZone: .autoupdatingCurrent)
    }
}
