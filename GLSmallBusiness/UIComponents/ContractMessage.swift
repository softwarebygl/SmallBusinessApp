//
//  ContractMessage.swift
//  GLSmallBusiness
//
//  Branded subject, greeting, and sign-off used when a contract is emailed or
//  texted to a customer with the Contract PDF attached.
//

import SwiftUI
import UIKit

enum ContractMessage {

    static let defaultIntro = "Please review the attached contract for your project."
    static let defaultClosing = "If you have any questions or would like to discuss, please let us know. Warm regards,"

    static func intro(contract: Contract, business: BusinessProfile?) -> String {
        let job = trimmed(contract.displayTitle)
        if job.isEmpty { return defaultIntro }
        return "Please find attached the contract for \(job) for your review and records."
    }

    static func closing(for business: BusinessProfile?) -> String {
        let custom = trimmed(business?.messageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    // MARK: - Subject

    static func subject(_ contract: Contract, business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let number = trimmed(contract.number)
        let title = trimmed(contract.displayTitle)
        switch (company.isEmpty, number.isEmpty) {
        case (false, false):
            return "Contract \(number) from \(company) – \(title)"
        case (false, true):
            return "Contract from \(company) – \(title)"
        case (true, false):
            return "Contract \(number) – \(title)"
        case (true, true):
            return "Contract – \(title)"
        }
    }

    static func subject(contract: Contract, business: BusinessProfile?) -> String {
        subject(contract, business: business)
    }

    // MARK: - Plain-text body (SMS / iMessage)

    static func plainBody(contract: Contract, business: BusinessProfile?) -> String {
        let name = greetingName(contract)
        let company = trimmed(business?.businessName)
        let job = trimmed(contract.displayTitle)
        let number = trimmed(contract.number)
        let total = contract.contractedValue.formatted(.money)

        var summaryParts: [String] = []
        if !number.isEmpty { summaryParts.append(number) }
        summaryParts.append("Contract Value: \(total)")
        if !contract.approvedChangeOrders.isEmpty {
            summaryParts.append("Includes \(contract.approvedChangeOrders.count) change order(s)")
        }
        let summary = summaryParts.joined(separator: " · ")
        let projectLine = job.isEmpty ? "" : "Project: \(job)\n"
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        return """
        Hi \(name),

        \(intro(contract: contract, business: business))

        \(projectLine)\(summary)

        \(closing(for: business))\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(contract: Contract, business: BusinessProfile?) -> String {
        let name = greetingName(contract)
        let job = trimmed(contract.displayTitle)
        let number = esc(trimmed(contract.number))
        let total = esc(contract.contractedValue.formatted(.money))

        let logoTag = EmailSignature.logoTag(business: business)

        var rows: [(label: String, value: String, strong: Bool)] = []
        if !job.isEmpty { rows.append(("Project", esc(job), false)) }
        if !number.isEmpty { rows.append(("Contract", number, false)) }
        rows.append(("Contract Value", total, true))
        if !contract.approvedChangeOrders.isEmpty {
            let coCount = contract.approvedChangeOrders.count
            let coSum = esc(contract.approvedChangeOrders.reduce(0.0) { $0 + $1.total }.formatted(.money))
            rows.append(("Change Orders", "\(coCount) approved (\(coSum))", false))
        }
        if contract.isSigned {
            rows.append(("Signature", "Signed", false))
        } else {
            rows.append(("Signature", "Awaiting Client Signature", false))
        }

        let signature = EmailSignature.block(business: business)

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(contract: contract, business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">\(htmlText(closing(for: business)))</p>
        \(signature.isEmpty ? "" : "<p style=\"margin:20px 0 0;\">\(signature)</p>")
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Helpers

    private static func greetingName(_ contract: Contract) -> String {
        let full = trimmed(contract.displayCustomerName)
        guard !full.isEmpty else { return "there" }
        return trimmed(full.components(separatedBy: " ").first ?? full)
    }

    private static func trimmed(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func htmlText(_ s: String) -> String {
        esc(s).replacingOccurrences(of: "\n", with: "<br/>")
    }
}
