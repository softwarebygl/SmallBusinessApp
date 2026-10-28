//
//  ContractorPackageMessage.swift
//  GLSmallBusiness
//
//  Branded subject + body used when the Contractor Package is shared by text or email. Single source
//  of truth, mirroring EstimateMessage / InvoiceMessage: prepared defaults that the business can
//  override (stored on BusinessProfile). Empty overrides fall back to the defaults, so improving a
//  default reaches everyone who hasn't customized.
//

import Foundation

enum ContractorPackageMessage {

    // MARK: - Customizable wording (prepared defaults, overridable per business)

    static let defaultSubject = "Contractor package"
    static let defaultIntro = "Attached is our contractor package — certificate of insurance, W-9, and any supporting documents you requested."
    static let defaultClosing = "Please let us know if there's anything else you need. Thank you,"

    /// Email subject. Custom override first, otherwise a default that names the business when set.
    static func subject(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.packageMessageSubject)
        if !custom.isEmpty { return custom }
        let company = trimmed(business?.businessName)
        return company.isEmpty ? defaultSubject : "Contractor package from \(company)"
    }

    static func intro(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.packageMessageIntro)
        return custom.isEmpty ? defaultIntro : custom
    }

    static func closing(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.packageMessageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    /// The PLAIN-TEXT body — the share sheet (AirDrop, Messages, third-party
    /// apps) can carry nothing else.
    static func body(business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        return "\(intro(business: business))\n\n\(closing(business: business))\(signoff)"
    }

    /// The HTML body for the Mail composer — logo and signature block included.
    ///
    /// This was the ONE customer email that never got the shared signature
    /// (owner report 2026-08-31: "I have the setting on to include my logo in
    /// documents and emails and yet I don't see it in the email"). The package
    /// only ever went out through the share sheet, which is plain text, so the
    /// logo and the signature had nowhere to live — every other sender
    /// (estimate, invoice, change order, receipt, review request) already
    /// builds HTML through this same pair of helpers.
    static func htmlBody(business: BusinessProfile?) -> String {
        let logoTag = EmailSignature.logoTag(business: business)
        let signature = EmailSignature.block(business: business)
        let inner = """
        \(logoTag)
        <p style="margin:0 0 16px;">\(htmlText(intro(business: business)))</p>
        <p style="margin:0 0 16px;">\(htmlText(closing(business: business)))</p>
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
        """
        return EmailHTML.page(inner)
    }

    /// Escape, then honour the author's line breaks.
    private static func htmlText(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
