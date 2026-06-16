//
//  EstimateMessage.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import UIKit

/// Builds the branded subject, greeting, and sign-off used when an estimate is emailed or
/// texted to a customer. Single source of truth so email and Messages stay consistent.
///
/// Branding logo: the business's own uploaded logo (`BusinessProfile.logoData`) when present,
/// otherwise the bundled GL monogram (`glLogo` asset) as a fallback.
enum EstimateMessage {

    // MARK: - Customizable wording (prepared defaults, overridable per business)

    /// Prepared default intro shown after the salutation. Used when the business hasn't set
    /// a custom `messageIntro`, so improving this default reaches everyone who hasn't customized.
    static let defaultIntro = "Thank you for the opportunity to earn your business. Your estimate is attached for your review."

    /// Prepared default closing shown before the signature.
    static let defaultClosing = "If you have any questions, just reply to this message. Warm regards,"

    /// The custom intro if set, otherwise a default that names the job when there is one.
    static func intro(estimate: Estimate, business: BusinessProfile?) -> String {
        let custom = trimmed(business?.messageIntro)
        if !custom.isEmpty { return custom }
        let job = trimmed(estimate.jobTitle)
        if job.isEmpty { return defaultIntro }
        return "Thank you for the opportunity to earn your business. Here's your estimate for \(job)."
    }

    static func closing(for business: BusinessProfile?) -> String {
        let custom = trimmed(business?.messageClosing)
        return custom.isEmpty ? defaultClosing : custom
    }

    // MARK: - Subject

    static func subject(estimate: Estimate, business: BusinessProfile?) -> String {
        let company = trimmed(business?.businessName)
        let number = trimmed(estimate.number)
        switch (company.isEmpty, number.isEmpty) {
        case (false, false): return "Estimate \(number) from \(company)"
        case (false, true):  return "Your estimate from \(company)"
        case (true, false):  return "Your estimate \(number)"
        case (true, true):   return "Your estimate"
        }
    }

    // MARK: - Plain-text body (SMS / iMessage)

    static func plainBody(estimate: Estimate, business: BusinessProfile?) -> String {
        let name = greetingName(estimate)
        let company = trimmed(business?.businessName)
        let job = trimmed(estimate.jobTitle)
        let number = trimmed(estimate.number)
        let total = estimate.total.formatted(.currency(code: "USD"))
        let valid = estimate.validUntil.formatted(date: .abbreviated, time: .omitted)

        var summaryParts: [String] = []
        if !number.isEmpty { summaryParts.append(number) }
        summaryParts.append("Total: \(total)")
        summaryParts.append("Valid until: \(valid)")
        let summary = summaryParts.joined(separator: " · ")
        let projectLine = job.isEmpty ? "" : "Project: \(job)\n"
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        return """
        Hi \(name),

        \(intro(estimate: estimate, business: business))

        \(projectLine)\(summary)

        \(closing(for: business))\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(estimate: Estimate, business: BusinessProfile?) -> String {
        let name = greetingName(estimate)
        let company = trimmed(business?.businessName)
        let job = trimmed(estimate.jobTitle)
        let number = esc(trimmed(estimate.number))
        let total = esc(estimate.total.formatted(.currency(code: "USD")))
        let valid = esc(estimate.validUntil.formatted(date: .abbreviated, time: .omitted))
        let phone = trimmed(business?.phone)
        let email = trimmed(business?.email)
        let license = trimmed(business?.licenseNumber)

        var logoTag = ""
        if let data = logoPNGData(business: business) {
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"140\" style=\"display:block;margin:0 0 20px;max-width:140px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        var rows: [(label: String, value: String, strong: Bool)] = []
        if !job.isEmpty { rows.append(("Project", esc(job), false)) }
        if !number.isEmpty { rows.append(("Estimate", number, false)) }
        rows.append(("Total", total, true))
        rows.append(("Valid until", valid, false))

        var signature = "<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if !email.isEmpty { signature += "<br>\(esc(email))" }
        if !license.isEmpty { signature += "<br>License #\(esc(license))" }

        let inner = """
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 16px;">\(htmlText(intro(estimate: estimate, business: business)))</p>
        \(EmailHTML.summaryBox(rows))
        <p style="margin:0 0 16px;">\(htmlText(closing(for: business)))</p>
        <p style="margin:20px 0 0;">\(signature)</p>
        """
        return EmailHTML.page(inner)
    }

    // MARK: - Logo

    /// The brand logo written to a temp PNG, for attaching to a Message. Nil if no logo.
    @MainActor
    static func logoAttachmentURL(business: BusinessProfile?) -> URL? {
        guard let data = logoPNGData(business: business) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("estimate-logo.png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Cached PNG of the GL-monogram fallback (it never changes), so emails for users without an
    /// uploaded logo don't re-run a main-thread `ImageRenderer` on every build.
    @MainActor private static var cachedFallbackLogo: Data?

    /// PNG of the brand logo, downsized for email/Messages. Business logo first, GL monogram fallback.
    @MainActor
    static func logoPNGData(business: BusinessProfile?, maxDimension: CGFloat = 240) -> Data? {
        if let data = business?.logoData, let image = UIImage(data: data) {
            return resizedPNGData(image, maxDimension: maxDimension)
        }
        if maxDimension == 240, let cached = cachedFallbackLogo { return cached }
        let renderer = ImageRenderer(content:
            Image("glLogo")
                .resizable()
                .scaledToFit()
                .frame(width: maxDimension, height: maxDimension)
        )
        renderer.scale = 3
        let data = renderer.uiImage?.pngData()
        if maxDimension == 240 { cachedFallbackLogo = data }
        return data
    }

    // MARK: - Helpers

    private static func greetingName(_ estimate: Estimate) -> String {
        let first = trimmed(estimate.customerFirstName)
        return first.isEmpty ? "there" : first
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes the characters that would otherwise break the surrounding HTML. `&` must go first.
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

    private static func resizedPNGData(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image.pngData() }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.pngData()
    }
}
