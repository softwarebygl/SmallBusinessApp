//
//  ReviewRequestMessage.swift
//  GLSmallBusiness
//
//  The standalone "would you leave us a review?" message, sent from My Business Details by text or
//  email. Unlike the receipt's review footer this is the whole message, so it carries its own
//  greeting, context, and sign-off — a bare link with no explanation reads as spam. Mirrors
//  `PaymentReceiptMessage` / `InvoiceMessage` and reuses the estimate's brand-logo helpers.
//

import SwiftUI

enum ReviewRequestMessage {

    static func subject(business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        return company.isEmpty ? "We’d love your feedback" : "We’d love your feedback — \(company)"
    }

    // MARK: - Plain-text body (SMS / iMessage)

    /// The recipient is chosen in the compose sheet, so the greeting is generic. SMS clients
    /// auto-link the URL, making it one tap.
    static func plainBody(business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let thanks = company.isEmpty
            ? "Thank you for letting us take care of your project."
            : "Thank you for choosing \(company)."
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        let linkSection = linkLine(business: business)

        return """
        Hi there,

        \(thanks) If you were happy with our work, would you take a minute to leave us a review? It makes a real difference for a small business.\(linkSection)

        Thank you — we truly appreciate it.\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let thanks = company.isEmpty
            ? "Thank you for letting us take care of your project."
            : "Thank you for choosing \(esc(company))."

        let logoTag = EmailSignature.logoTag(business: business)

        var button = ""
        if let url = business?.reviewsLink {
            let href = esc(url.absoluteString)
            button = """
            <p style="margin:0 0 18px;text-align:center;">
              <a href="\(href)" style="display:inline-block;background-color:#9C7A2E;color:#ffffff;text-decoration:none;padding:13px 28px;border-radius:8px;font-weight:600;font-size:16px;">★ Leave us a review</a>
            </p>
            """
        }

        let signature = EmailSignature.block(business: business)

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi there,</p>
        <p style="margin:0 0 16px;">\(thanks) If you were happy with our work, would you take a minute to leave us a review? It makes a real difference for a small business.</p>
        \(button)
        <p style="margin:0 0 16px;">Thank you — we truly appreciate it.</p>
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Helpers

    /// The tappable link paragraph for the plain body — empty when no reviews link is set (the send
    /// flow is only offered once one exists, but the helper stays safe without it).
    private static func linkLine(business: BusinessProfile?) -> String {
        guard let url = business?.reviewsLink else { return "" }
        return "\n\nLeave a review here: \(url.absoluteString)"
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
}
