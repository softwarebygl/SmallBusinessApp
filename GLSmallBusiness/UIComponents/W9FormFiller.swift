//
//  W9FormFiller.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Fills the official IRS Form W-9 (Rev. March 2024) by stamping the company's saved details onto
//  the bundled template (Resources/W9Template.pdf) at the form's real field coordinates, then
//  flattening to a single shareable page. Field rects were read from the template's AcroForm.

import UIKit
import PDFKit
import CoreText

enum W9PDF {
    /// Fills the official W-9 template and returns a single-page flattened PDF URL.
    @MainActor
    static func render(_ profile: BusinessProfile, signatureImage: UIImage? = nil, signedDate: Date? = nil) -> URL? {
        guard let templateURL = Bundle.main.url(forResource: "W9Template", withExtension: "pdf"),
              let template = PDFDocument(url: templateURL),
              let page = template.page(at: 0) else { return nil }
        var box = page.bounds(for: .mediaBox)

        let safeName = profile.w9LegalName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "Form-W-9\(safeName.isEmpty ? "" : "-\(safeName)").pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)        // the blank official form
        ctx.setFillColor(UIColor.black.cgColor)
        fill(ctx, profile: profile, signatureImage: signatureImage, signedDate: signedDate)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// Renders page 1 of a generated W-9 PDF to an image for in-app preview.
    static func pageImage(from url: URL, scale: CGFloat = 2) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: box.size, format: format).image { rc in
            let cg = rc.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: box.size))
            cg.translateBy(x: 0, y: box.size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    // MARK: - Field stamping (coordinates in PDF points, origin bottom-left)

    @MainActor
    private static func fill(_ ctx: CGContext, profile: BusinessProfile, signatureImage: UIImage?, signedDate: Date?) {
        // Line 1 — name; Line 2 — business/DBA name if different.
        text(ctx, profile.w9LegalName, x: 62, y: 663, size: 9, maxWidth: 510)
        let dba = profile.businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dba.isEmpty, dba != profile.w9LegalName {
            text(ctx, dba, x: 62, y: 639, size: 9, maxWidth: 510)
        }

        // Line 3a — classification checkbox (+ LLC letter / Other description).
        switch profile.w9TaxClassification {
        case .individual:   check(ctx, x: 73, y: 603.7)
        case .cCorporation: check(ctx, x: 180, y: 603.7)
        case .sCorporation: check(ctx, x: 252, y: 603.7)
        case .partnership:  check(ctx, x: 324, y: 603.7)
        case .trustEstate:  check(ctx, x: 388.8, y: 603.7)
        case .llc:
            check(ctx, x: 73, y: 590.5)
            text(ctx, profile.w9LLCClassification.uppercased(), x: 427, y: 590.5, size: 10)
        case .other:
            check(ctx, x: 73, y: 554)
            text(ctx, profile.w9OtherClassification, x: 165, y: 554, size: 9, maxWidth: 278)
        case .none:
            break
        }

        // Line 4 — exemption codes (optional).
        text(ctx, profile.w9ExemptPayeeCode, x: 546, y: 590, size: 9, maxWidth: 28)
        text(ctx, profile.w9FATCACode, x: 503, y: 554, size: 9, maxWidth: 70)

        // Lines 5 & 6 — address.
        text(ctx, streetLine(profile.address), x: 62, y: 495, size: 9, maxWidth: 322)
        text(ctx, cityLine(profile.address), x: 62, y: 471, size: 9, maxWidth: 322)

        // Part I — TIN. SSN is split 3-2-4; EIN is split 2-7. Each cell is 14.4 pt wide.
        let digits = profile.secureTIN.filter(\.isNumber)
        switch profile.w9TINType {
        case .ssn:
            comb(ctx, String(digits.prefix(3)), x: 417.6, y: 402, cell: 14.4)
            comb(ctx, String(digits.dropFirst(3).prefix(2)), x: 475.2, y: 402, cell: 14.4)
            comb(ctx, String(digits.dropFirst(5).prefix(4)), x: 518.4, y: 402, cell: 14.4)
        case .ein:
            comb(ctx, String(digits.prefix(2)), x: 417.6, y: 354, cell: 14.4)
            comb(ctx, String(digits.dropFirst(2).prefix(7)), x: 460.8, y: 354, cell: 14.4)
        case .none:
            break
        }

        // Part II — signature + date (manual area; no form field).
        if let cg = signatureImage?.cgImage {
            let maxW: CGFloat = 235, maxH: CGFloat = 20
            let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
            var w = maxH * aspect, h = maxH
            if w > maxW { w = maxW; h = maxW / aspect }
            ctx.saveGState()
            ctx.draw(cg, in: CGRect(x: 132, y: 193, width: w, height: h))
            ctx.restoreGState()
        }
        if let signedDate {
            text(ctx, signedDate.formatted(date: .numeric, time: .omitted), x: 420, y: 198, size: 9)
        }
    }

    // MARK: - Drawing helpers

    private static func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                             maxWidth: CGFloat? = nil, bold: Bool = false) {
        guard !string.isEmpty else { return }
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        var fontSize = size
        var font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        if let maxWidth {
            while fontSize > 5 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
                if CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(maxWidth) { break }
                fontSize -= 0.5
                font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            }
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: UIColor.black.cgColor]))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func check(_ ctx: CGContext, x: CGFloat, y: CGFloat) {
        text(ctx, "X", x: x + 0.6, y: y + 0.6, size: 9.5, bold: true)
    }

    private static func comb(_ ctx: CGContext, _ digits: String, x: CGFloat, y: CGFloat, cell: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (i, ch) in digits.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(ch), attributes: [.font: font, .foregroundColor: UIColor.black.cgColor]))
            let b = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(x: x + (CGFloat(i) + 0.5) * cell - b.width / 2, y: y)
            CTLineDraw(line, ctx)
        }
    }

    private static func streetLine(_ a: Address) -> String {
        [a.street1, a.street2 ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func cityLine(_ a: Address) -> String {
        let cityState = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        return [cityState, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
