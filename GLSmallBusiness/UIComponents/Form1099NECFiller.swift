//
//  Form1099NECFiller.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Fills the official IRS Form 1099-NEC (Rev. December 2026), Copy B "For Recipient", by stamping
//  the payer (this business), the recipient (the subcontractor), and Box 1a Nonemployee compensation
//  onto the bundled template (Resources/Form1099NEC.pdf) at the form's real field coordinates, then
//  flattening to a single shareable page. Same technique as W9FormFiller; coordinates were read from
//  the template's AcroForm. We generate Copy B (furnish to the recipient) — Copy A is filed with the
//  IRS separately (e-file or the scannable red form), which the accountant CSV handoff covers.
//
//  The Dec 2026 revision split Box 1 into 1a Nonemployee compensation / 1b Cash tips / 1c TTOC /
//  1d Overtime compensation. A normal NEC payment goes in Box 1a; the rest stay blank.
//

import UIKit
import PDFKit
import CoreText

enum Form1099NECPDF {
    /// Fills Copy B of the 1099-NEC and returns a single-page flattened PDF URL.
    @MainActor
    static func render(payer: BusinessProfile, recipient: Subcontractor, amount: Double, year: Int) -> URL? {
        guard let templateURL = Bundle.main.url(forResource: "Form1099NEC", withExtension: "pdf"),
              let template = PDFDocument(url: templateURL),
              let page = template.page(at: 0) else { return nil }
        var box = page.bounds(for: .mediaBox)

        let safeName = recipient.payeeName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "Form-1099-NEC\(safeName.isEmpty ? "" : "-\(safeName)").pdf"
        // Each generation gets a fresh folder under a per-form root: wiping the root first drops any
        // TIN-bearing PDF a previous generation left behind, and the unique subfolder means repeated
        // generations (year/payee changes) never collide at a predictable path.
        try? FileManager.default.removeItem(at: generatedRoot)
        let folder = generatedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        let url = folder.appendingPathComponent(fileName)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)            // the blank official Copy B
        ctx.setFillColor(UIColor.black.cgColor)
        fill(ctx, payer: payer, recipient: recipient, amount: amount, year: year)
        ctx.endPDFPage()
        ctx.closePDF()
        // Both parties' full TINs are on this page — keep it encrypted whenever the device is
        // locked, matching the year-end CSV export (SubcontractorsScreen.generateExport).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

    /// Root folder for generated 1099-NECs; every render writes into a fresh subfolder beneath it.
    private nonisolated static var generatedRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Generated-1099-NEC", isDirectory: true)
    }

    /// Deletes every generated 1099-NEC PDF. Call once the preview/share is done with the file —
    /// render also wipes prior generations itself, so at most one file ever lingers between calls.
    nonisolated static func cleanUp() {
        try? FileManager.default.removeItem(at: generatedRoot)
    }

    /// Renders the generated 1099-NEC to an image for in-app preview.
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

    // MARK: - Field stamping (coordinates in PDF points, origin bottom-left; page is 612 × 792)

    @MainActor
    private static func fill(_ ctx: CGContext, payer: BusinessProfile, recipient: Subcontractor,
                             amount: Double, year: Int) {
        // PAYER block (left column).
        let payerName = payer.w9LegalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? payer.businessName : payer.w9LegalName
        text(ctx, payerName, x: 54, y: 729, size: 9, maxWidth: 238)
        text(ctx, streetLine(payer.address), x: 54, y: 699, size: 8, maxWidth: 238)
        text(ctx, payer.address.city, x: 54, y: 675, size: 8, maxWidth: 150)
        text(ctx, payer.address.state, x: 54, y: 651, size: 8, maxWidth: 115)
        text(ctx, payer.address.postalCode, x: 212, y: 651, size: 8, maxWidth: 80)

        // For calendar year — the bundled IRS template does NOT preprint the century, so stamp the
        // full 4-digit year (a 2-digit "26" reads as an ambiguous/wrong tax year on a furnished return).
        text(ctx, String(year), x: 414, y: 690, size: 10)

        // TINs.
        text(ctx, formatTIN(payer.secureTIN, type: payer.w9TINType), x: 56, y: 615, size: 9, maxWidth: 112)
        text(ctx, formatTIN(recipient.secureTIN, type: recipient.w9TINType), x: 178, y: 615, size: 9, maxWidth: 112)

        // RECIPIENT block (left column).
        text(ctx, recipient.payeeName, x: 54, y: 585, size: 9, maxWidth: 238)
        text(ctx, streetLine(recipient.address), x: 54, y: 555, size: 8, maxWidth: 238)
        text(ctx, recipient.address.city, x: 54, y: 531, size: 8, maxWidth: 238)
        text(ctx, recipient.address.state, x: 54, y: 507, size: 8, maxWidth: 115)
        text(ctx, recipient.address.postalCode, x: 212, y: 507, size: 8, maxWidth: 80)

        // Box 1a — Nonemployee compensation (the "$" is preprinted; stamp the amount only).
        text(ctx, box1aAmount(amount), x: 318, y: 651, size: 9, maxWidth: 170)
    }

    // MARK: - Helpers

    /// Box 1a amount in fixed US style (comma grouping, dot decimal, two places) regardless of the
    /// device locale — on an official US form "3,050.00" must never print as "3.050,00". Cents by the
    /// one money rule (law 60): half-up on the amount as written.
    nonisolated static func box1aAmount(_ amount: Double) -> String {
        DomainMoney.roundedToCents(amount).formatted(.number.precision(.fractionLength(2)).grouping(.automatic)
            .locale(Locale(identifier: "en_US")))
    }

    /// Formats 9 digits as SSN (3-2-4) or EIN (2-7). Falls back to the raw value if not 9 digits.
    private static func formatTIN(_ tin: String, type: W9TINType?) -> String {
        let d = tin.filter { $0.isASCII && $0.isNumber }
        guard d.count == 9 else { return tin }
        switch type {
        case .ssn:
            return "\(d.prefix(3))-\(d.dropFirst(3).prefix(2))-\(d.dropFirst(5))"
        case .ein:
            return "\(d.prefix(2))-\(d.dropFirst(2))"
        case .none:
            return tin
        }
    }

    private static func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                             maxWidth: CGFloat? = nil) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var fontSize = size
        var font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        if let maxWidth {
            while fontSize > 5 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font]))
                if CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(maxWidth) { break }
                fontSize -= 0.5
                font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            }
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: value, attributes: [.font: font, .foregroundColor: UIColor.black.cgColor]))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func streetLine(_ a: Address) -> String {
        [a.street1, a.street2 ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
