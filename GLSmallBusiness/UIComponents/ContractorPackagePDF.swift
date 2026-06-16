//
//  ContractorPackagePDF.swift
//  GLSmallBusiness
//
//  The engine behind the Contractor Package: locate the certificate-holder box on an uploaded COI,
//  stamp the requesting holder onto it (optionally covering any holder text already printed there),
//  and merge the package's documents — COI, W-9, workers'-comp, and license — into one shareable PDF.
//
//  COIs arrive as flattened PDFs (or images): the text is painted on, with no fillable fields. So we
//  search the page text for the "CERTIFICATE HOLDER" label to anchor the new holder, fall back to a
//  sensible lower-left position when the text isn't found (e.g. an image COI or a non-ACORD layout),
//  and let the caller nudge it. Nothing in the original is erased unless "cover existing" is on.
//

import UIKit
import PDFKit
import CoreText

enum ContractorPackagePDF {

    // MARK: - Holder placement

    /// Where the holder block goes on page 1 of a COI, in PDF points (origin bottom-left).
    struct HolderPlacement: Equatable {
        /// Top-left of the holder text block.
        var anchor: CGPoint
        /// Wrap/cover width for the block.
        var width: CGFloat
        /// Page-1 size, for mapping between PDF points and on-screen preview points.
        var pageSize: CGSize
        /// True when `anchor` came from finding the "CERTIFICATE HOLDER" label (vs. the fallback).
        var autoDetected: Bool
    }

    /// Builds a `PDFDocument` from COI data that may be a PDF or a single image.
    static func document(from data: Data) -> PDFDocument? {
        if let doc = PDFDocument(data: data) { return doc }
        if let image = UIImage(data: data), let page = PDFPage(image: image) {
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            return doc
        }
        return nil
    }

    /// The holder lines to stamp, in order: company, owner, address lines, then any extra details.
    /// Every field is optional — blanks are dropped and the first surviving line is drawn bold.
    static func holderLines(company: String, owner: String, address: String, details: String) -> [String] {
        var lines: [String] = []
        for single in [company, owner] {
            let line = single.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        for block in [address, details] {
            for raw in block.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
            }
        }
        return lines
    }

    /// Picks the "CERTIFICATE HOLDER" box-label rect from the matches found on the page. ACORD 25
    /// prints the label twice — once in the disclaimer sentence near the top, once as the box header
    /// in the lower-left — so prefer a match in the bottom of the page, lowest first. Pure + testable.
    static func chooseLabelRect(_ rects: [CGRect], pageHeight: CGFloat) -> CGRect? {
        rects.filter { $0.minY < pageHeight * 0.45 }
             .min(by: { $0.minY < $1.minY })
    }

    /// Resolves where to place the holder block on page 1 of `document`.
    static func locateHolder(in document: PDFDocument) -> HolderPlacement? {
        guard let page = document.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)

        let matches = document.findString("CERTIFICATE HOLDER", withOptions: [.caseInsensitive])
        let labelRects = matches.compactMap { selection -> CGRect? in
            guard selection.pages.contains(where: { $0 === page }) else { return nil }
            let rect = selection.bounds(for: page)
            return rect.isNull || rect.isEmpty ? nil : rect
        }

        if let label = chooseLabelRect(labelRects, pageHeight: pageRect.height) {
            // Start the block just below the label, left-aligned to it.
            let anchor = CGPoint(x: label.minX, y: label.minY - 8)
            let width = min(pageRect.width * 0.46, pageRect.width - label.minX - 12)
            return HolderPlacement(anchor: anchor, width: max(width, 120),
                                   pageSize: pageRect.size, autoDetected: true)
        }

        // Fallback for image COIs / non-ACORD layouts: lower-left quadrant, nudge-able by the user.
        let anchor = CGPoint(x: pageRect.width * 0.07, y: pageRect.height * 0.20)
        return HolderPlacement(anchor: anchor, width: pageRect.width * 0.46,
                               pageSize: pageRect.size, autoDetected: false)
    }

    // MARK: - Stamping

    /// Geometry of the holder block as drawn, shared by the PDF stamp and the live preview so the two
    /// stay pixel-aligned (WYSIWYG).
    enum HolderLayout {
        static let nameSize: CGFloat = 9.5
        static let bodySize: CGFloat = 9
        static let lineHeight: CGFloat = 12
        static let topPadding: CGFloat = 2

        /// Height of the block (and its cover box) for `count` lines.
        static func blockHeight(lineCount count: Int) -> CGFloat {
            CGFloat(max(count, 1)) * lineHeight + topPadding * 2
        }
    }

    /// Produces a stamped copy of the COI as PDF data: every page preserved, the holder block (and
    /// optional white cover) drawn onto page 1. `width`, when given, overrides the auto-detected box
    /// width (the block still grows in height to fit every line). Returns nil if the COI can't be read.
    static func stampedCOIData(coiData: Data, lines: [String],
                               offset: CGSize, coverExisting: Bool, width: CGFloat? = nil) -> Data? {
        guard let doc = document(from: coiData),
              var placement = locateHolder(in: doc),
              let firstPage = doc.page(at: 0) else { return nil }
        if let width { placement.width = max(width, 40) }

        var mediaBox = firstPage.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            ctx.beginPDFPage(nil)
            page.draw(with: .mediaBox, to: ctx)
            if i == 0 {
                drawHolder(in: ctx, placement: placement, lines: lines,
                           offset: offset, coverExisting: coverExisting)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func drawHolder(in ctx: CGContext, placement: HolderPlacement, lines: [String],
                                   offset: CGSize, coverExisting: Bool) {
        let anchor = CGPoint(x: placement.anchor.x + offset.width,
                             y: placement.anchor.y + offset.height)

        if coverExisting {
            let height = HolderLayout.blockHeight(lineCount: lines.count)
            let top = anchor.y + HolderLayout.topPadding
            let cover = CGRect(x: anchor.x - 3, y: top - height,
                               width: placement.width + 6, height: height)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(cover)
        }

        ctx.setFillColor(UIColor.black.cgColor)
        var y = anchor.y
        for (index, line) in lines.enumerated() {
            let size = index == 0 ? HolderLayout.nameSize : HolderLayout.bodySize
            drawText(in: ctx, line, x: anchor.x, y: y - size,
                     size: size, maxWidth: placement.width, bold: index == 0)
            y -= HolderLayout.lineHeight
        }
    }

    /// Draws one line of Helvetica text, shrinking to fit `maxWidth` (mirrors the W-9 filler).
    private static func drawText(in ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat,
                                 size: CGFloat, maxWidth: CGFloat, bold: Bool) {
        guard !string.isEmpty else { return }
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        var fontSize = size
        var font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        while fontSize > 5 {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: [.font: font]))
            if CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(maxWidth) { break }
            fontSize -= 0.5
            font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: UIColor.black.cgColor]))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    // MARK: - Page-1 preview

    /// Renders page 1 of COI data to an image for the placement preview.
    static func coiPageImage(from data: Data, scale: CGFloat = 2) -> UIImage? {
        guard let doc = document(from: data), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
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

    // MARK: - Merge

    /// Merges the given document datas (PDFs and/or images), in order, into one PDF written to a temp
    /// file. Images become full pages. Returns nil if nothing readable was supplied.
    static func merge(_ sources: [Data], fileName: String) -> URL? {
        let combined = PDFDocument()
        var index = 0
        for data in sources {
            guard let doc = document(from: data) else { continue }
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p), let copy = page.copy() as? PDFPage else { continue }
                combined.insert(copy, at: index)
                index += 1
            }
        }
        guard index > 0 else { return nil }
        let safe = fileName.isEmpty ? "Contractor-Package.pdf" : fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        return combined.write(to: url) ? url : nil
    }
}
