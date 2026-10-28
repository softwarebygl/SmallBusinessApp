//
//  EmailSignature.swift — the ONE email signature block (owner feature,
//  2026-08-29: "spice up the email to look more professional").
//
//  Every customer email the app composes (estimate, invoice, change order,
//  payment receipt, review request) ends with the same block: the LIGHT logo —
//  email grounds are white, so the light version is the default, falling back
//  to the dark upload for a single-logo business — then the business name in
//  brand gold, the owner's standard info, the license, and an optional line
//  the owner writes in Settings ▸ Email. One builder, so the five senders can
//  never drift apart; the Settings toggle empties the whole block at once.
//
//  The logo travels as a data: URI, which Apple Mail composes and renders
//  reliably; some receiving webmail clients strip data URIs — recorded caveat,
//  the text half of the signature survives everywhere.
//

import Foundation
import SwiftData
import SwiftUI

enum EmailSignature {

    /// The signature's name line: the OWNER's name by default, or the signed-in
    /// person's Gold Life ID name when they turned on "My name" (Settings ▸ What
    /// customers see ▸ Name in emails — a per-person app setting on UserProfile).
    /// The name itself always comes from the Gold Life ID (law 48a, audit F19), so
    /// an edit there shows in the next email. Nil context (signed out) = owner.
    @MainActor
    private static func senderName(business: BusinessProfile?, context: ModelContext?) -> String {
        let owner = trimmed("\(trimmed(business?.ownerFirstName)) \(trimmed(business?.ownerLastName))")
        let useMyName = context
            .flatMap { try? $0.fetch(FetchDescriptor<UserProfile>()).first }?
            .useMyNameInEmails ?? false
        return senderName(owner: owner, useMyName: useMyName, myName: MBIdentity.shared.current.fullName)
    }

    /// The rule: "My name" signs with the Gold Life ID name, and falls back to the owner
    /// whenever that name is blank, so a preference can never blank the name line.
    nonisolated static func senderName(owner: String, useMyName: Bool, myName: String) -> String {
        let mine = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        return useMyName && !mine.isEmpty ? mine : owner
    }

    /// The `<img>` tag for the signature logo, or empty — gated by the
    /// email-signature toggle, resized to a retina inline logo (280px for the
    /// 140-point display width).
    static func logoTag(business: BusinessProfile?) -> String {
        guard let raw = business?.emailLogoData,
              let image = UIImage(data: raw),
              let png = resizedPNG(image, maxDimension: 280) else { return "" }
        let company = esc((business?.businessName ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return "<img src=\"data:image/png;base64,\(png.base64EncodedString())\" width=\"140\" style=\"display:block;margin:0 0 20px;max-width:140px;height:auto;\" alt=\"\(company)\" />"
    }

    /// Downscale to keep the data: URI light; PNG so transparent logos keep
    /// their transparency on the email's white ground.
    private static func resizedPNG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let largest = max(image.size.width, image.size.height)
        guard largest > 0 else { return nil }
        let scale = min(1, maxDimension / largest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.pngData()
    }

    /// The signature paragraph's inner HTML, or empty when the toggle is off.
    /// Callers wrap it in their own `<p>` so surrounding margins stay theirs.
    @MainActor
    static func block(business: BusinessProfile?) -> String {
        block(business: business, context: UserScopedStore.shared.activeMainContext)
    }

    /// `block(business:)` against a given store (the signed-in person's, or a test's).
    @MainActor
    static func block(business: BusinessProfile?, context: ModelContext?) -> String {
        guard let business, business.emailSignatureEnabled else { return "" }
        let company = trimmed(business.businessName)
        let owner = senderName(business: business, context: context)
        let phone = trimmed(business.phone)
        let email = trimmed(business.email)
        let website = trimmed(business.websiteURL)
        let license = trimmed(business.licenseNumber)
        let custom = trimmed(business.emailSignatureText)

        var lines: [String] = []
        if !company.isEmpty { lines.append("<strong style=\"color:#9C7A2E;\">\(esc(company))</strong>") }
        if !owner.isEmpty { lines.append(esc(owner)) }
        if !phone.isEmpty { lines.append(esc(phone)) }
        if !email.isEmpty { lines.append(esc(email)) }
        if !website.isEmpty { lines.append(esc(website)) }
        if !license.isEmpty { lines.append("License #\(esc(license))") }
        if !custom.isEmpty {
            lines.append("<span style=\"color:#6b6b6b;\">\(esc(custom).replacingOccurrences(of: "\n", with: "<br>"))</span>")
        }
        return lines.joined(separator: "<br>")
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

