//
//  CompletionPackageMessage.swift
//  GLSmallBusiness
//
//  The branded wording for sharing a job's completion package — subject + intro + closing, each with
//  an editable override on the BusinessProfile and a sensible default. Mirrors the other message types.
//

import Foundation

enum CompletionPackageMessage {
    static let defaultIntro = "Your job is complete. Attached is your completion package — a paid-in-full receipt and our warranty."
    static let defaultClosing = "Thank you for your business. If anything comes up, just reply to this message."

    static func subject(job: ScheduledJob, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.completionMessageSubject)
        if !custom.isEmpty { return custom }
        let company = trimmed(business?.businessName)
        let base = "Completion package — \(job.displayTitle)"
        return company.isEmpty ? base : "\(base) from \(company)"
    }

    static func intro(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.completionMessageIntro)
        return custom.isEmpty ? defaultIntro : custom
    }

    static func closing(business: BusinessProfile?) -> String {
        let custom = trimmed(business?.completionMessageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    static func body(job: ScheduledJob, business: BusinessProfile?) -> String {
        let name = trimmed(job.customerName).isEmpty ? "there" : trimmed(job.customerName)
        let company = trimmed(business?.businessName)
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"
        return """
        Hi \(name),

        \(intro(business: business))

        \(closing(business: business))\(signoff)
        """
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
