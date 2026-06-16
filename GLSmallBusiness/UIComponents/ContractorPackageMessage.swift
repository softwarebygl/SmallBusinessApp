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

    /// The full text/email body: intro, closing, then the business signature.
    static func body(business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        return "\(intro(business: business))\n\n\(closing(business: business))\(signoff)"
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
