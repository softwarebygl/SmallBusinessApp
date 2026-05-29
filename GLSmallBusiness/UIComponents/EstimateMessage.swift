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
        let jobClause = job.isEmpty ? "" : " for \(job)"
        let numberClause = trimmed(estimate.number).isEmpty ? "" : " (\(trimmed(estimate.number)))"
        let total = estimate.total.formatted(.currency(code: "USD"))
        let valid = estimate.validUntil.formatted(date: .abbreviated, time: .omitted)
        let phone = trimmed(business?.phone)
        let callClause = phone.isEmpty ? "" : " or call \(phone)"
        let signoff = company.isEmpty ? "" : "\n\n— \(company)"

        return """
        Hi \(name),

        Thank you for the opportunity to earn your business! Your estimate\(jobClause)\(numberClause) is attached.

        Total: \(total) · Valid until: \(valid)

        Questions or ready to move forward? Just reply\(callClause).\(signoff)
        """
    }

    // MARK: - HTML body (email)

    @MainActor
    static func htmlBody(estimate: Estimate, business: BusinessProfile?) -> String {
        let name = greetingName(estimate)
        let company = trimmed(business?.businessName)
        let job = trimmed(estimate.jobTitle)
        let jobClause = job.isEmpty ? "" : " for \(esc(job))"
        let number = esc(trimmed(estimate.number))
        let total = esc(estimate.total.formatted(.currency(code: "USD")))
        let valid = esc(estimate.validUntil.formatted(date: .abbreviated, time: .omitted))
        let phone = trimmed(business?.phone)
        let email = trimmed(business?.email)
        let license = trimmed(business?.licenseNumber)
        let callClause = phone.isEmpty ? "" : " or call \(esc(phone))"

        var logoTag = ""
        if let data = logoPNGData(business: business) {
            logoTag = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" width=\"150\" style=\"display:block;margin:0 0 18px;max-width:150px;height:auto;\" alt=\"\(esc(company))\" />"
        }

        var signature = "Warm regards,<br><strong style=\"color:#9C7A2E;\">\(esc(company))</strong>"
        if !phone.isEmpty { signature += "<br>\(esc(phone))" }
        if !email.isEmpty { signature += "<br>\(esc(email))" }
        if !license.isEmpty { signature += "<br>License #\(esc(license))" }

        return """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;color:#1c1c1e;font-size:15px;line-height:1.5;max-width:560px;">
        \(logoTag)
        <p style="margin:0 0 14px;">Hi \(esc(name)),</p>
        <p style="margin:0 0 14px;">Thank you for the opportunity to earn your business. Your estimate\(jobClause) is attached as a PDF for your review.</p>
        <p style="margin:0 0 14px;"><strong>Estimate:</strong> \(number)<br><strong>Total:</strong> \(total)<br><strong>Valid until:</strong> \(valid)</p>
        <p style="margin:0 0 14px;">If you have any questions or would like to move forward, just reply to this email\(callClause).</p>
        <p style="margin:18px 0 0;">\(signature)</p>
        </div>
        """
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

    /// PNG of the brand logo, downsized for email/Messages. Business logo first, GL monogram fallback.
    @MainActor
    static func logoPNGData(business: BusinessProfile?, maxDimension: CGFloat = 240) -> Data? {
        if let data = business?.logoData, let image = UIImage(data: data) {
            return resizedPNGData(image, maxDimension: maxDimension)
        }
        let renderer = ImageRenderer(content:
            Image("glLogo")
                .resizable()
                .scaledToFit()
                .frame(width: maxDimension, height: maxDimension)
        )
        renderer.scale = 3
        return renderer.uiImage?.pngData()
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
