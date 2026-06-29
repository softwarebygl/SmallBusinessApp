//
//  PaginatedPDF.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Renders a fixed-width SwiftUI document view into a multi-page US-Letter PDF (612×792pt). Tall content
//  (a long invoice / estimate / change order / receipt) is split across pages so a row is never sliced
//  through the middle — a row that wouldn't fit moves whole to the next page (like Word). Breaks land on
//  the horizontal divider lines the documents draw between rows, or in the wide gaps between sections;
//  the tall full-width gap *inside* a row (its title above its "1 job × $X" subtitle, where the
//  right-aligned price leaves the right blank) is never used. Every page keeps a top and bottom margin;
//  horizontal margins come from each document's own padding.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum PaginatedPDF {
    // `nonisolated` so they can serve as a default-argument value (evaluated in a nonisolated context)
    // and be read from nonisolated callers — they're plain immutable layout constants, safe to share.
    nonisolated static let pageWidth: CGFloat = 612     // US Letter at 72 dpi
    nonisolated static let pageHeight: CGFloat = 792

    /// Top/bottom margin kept on every page. Matches the documents' own 40pt padding so page 1 (whose top
    /// margin comes from that padding) and later pages (whose top margin is added here) look identical.
    private static let verticalMargin: CGFloat = 40
    /// How far above an ideal break we'll hunt for a clean break before hard-cutting. Caps the blank space
    /// a pushed-down row can leave at the bottom of a page.
    private static let maxBreakSearch: CGFloat = 260
    /// A blank gap this tall (points) is a section break and is always safe to cut in, divider or not —
    /// big enough to clear the gaps that appear inside a row (≤~11pt), small enough to catch real sections.
    private static let sectionGap: CGFloat = 16

    /// One row of the rasterized content: all-background, a full-width rule (divider), or has real content.
    private enum RowInk { case blank, line, content }

    /// Renders `content` (already laid out to `width`) into a multi-page Letter PDF at `url`.
    /// Returns `url` on success, or `nil` if the view couldn't be rendered.
    static func render(_ content: some View, width: CGFloat = pageWidth, to url: URL, scale: CGFloat = 2) -> URL? {
        let pageH = pageHeight * (width / pageWidth)        // Letter-proportioned page for this width
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        guard let image = renderer.uiImage, let cg = image.cgImage, image.size.height > 0 else { return nil }

        let contentH = image.size.height                    // points
        let ink = rowInk(cg)                                // per-pixel-row classification, or nil
        let scaleY = CGFloat(cg.height) / contentH          // pixels per point (≈ `scale`)

        let pages = paginate(contentHeight: contentH, pageHeight: pageH, ink: ink, scaleY: scaleY)

        let pageSize = CGSize(width: width, height: pageH)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        do {
            try pdf.writePDF(to: url) { ctx in
                for band in pages {
                    ctx.beginPage()
                    let g = ctx.cgContext
                    g.setFillColor(UIColor.white.cgColor)           // white margins, never transparent
                    g.fill(CGRect(origin: .zero, size: pageSize))
                    g.saveGState()
                    // Show only this page's slice, inset from the top by its margin; the rest is clipped.
                    g.clip(to: CGRect(x: 0, y: band.topInset, width: width, height: band.end - band.start))
                    image.draw(in: CGRect(x: 0, y: band.topInset - band.start, width: width, height: contentH))
                    g.restoreGState()
                }
            }
            return url
        } catch {
            return nil
        }
    }

    /// One page's vertical slice of the content, in content-points, plus the y-offset to draw it at.
    private struct Band { let start: CGFloat; let end: CGFloat; let topInset: CGFloat }

    /// Splits `[0, contentHeight]` into page-sized bands, ending each at a row separator when possible.
    /// Page 1 uses the document's own top padding as its top margin (topInset 0); later pages add one.
    private static func paginate(contentHeight: CGFloat, pageHeight pageH: CGFloat,
                                 ink: [RowInk]?, scaleY: CGFloat) -> [Band] {
        var bands: [Band] = []
        var start: CGFloat = 0
        var first = true
        while start < contentHeight - 0.5, bands.count < 200 {  // bands cap guards a pathological input
            let topInset: CGFloat = first ? 0 : verticalMargin
            let maxBand = max(1, pageHeight - topInset - verticalMargin)
            let idealEnd = min(start + maxBand, contentHeight)
            let end = idealEnd >= contentHeight
                ? contentHeight
                : breakPoint(start: start, idealEnd: idealEnd, ink: ink, scaleY: scaleY)
            bands.append(Band(start: start, end: max(end, start + 1), topInset: topInset))
            start = end
            first = false
        }
        return bands.isEmpty ? [Band(start: 0, end: contentHeight, topInset: 0)] : bands
    }

    /// Finds a content-point y at or just above `idealEnd` that sits in a blank run which is either a wide
    /// section gap or borders a divider rule — i.e. a real boundary *between* rows, never the gap inside a
    /// row. Falls back to `idealEnd` (a hard cut) only if nothing qualifies within `maxBreakSearch`.
    private static func breakPoint(start: CGFloat, idealEnd: CGFloat, ink: [RowInk]?, scaleY: CGFloat) -> CGFloat {
        guard let ink else { return idealEnd }
        let idealRow = min(Int(idealEnd * scaleY), ink.count - 1)
        let floorRow = max(Int((idealEnd - maxBreakSearch) * scaleY), Int(start * scaleY) + 1)
        guard idealRow > floorRow else { return idealEnd }
        let sectionRows = max(1, Int(sectionGap * scaleY))
        var r = idealRow
        while r > floorRow {
            guard ink[r] == .blank else { r -= 1; continue }
            var top = r; while top > floorRow, ink[top - 1] == .blank { top -= 1 }
            var bot = r; while bot < idealRow, ink[bot + 1] == .blank { bot += 1 }
            let isSection = bot - top + 1 >= sectionRows
            let bordersDivider = (top > 0 && ink[top - 1] == .line) || (bot + 1 < ink.count && ink[bot + 1] == .line)
            if isSection || bordersDivider {
                return CGFloat((top + bot) / 2) / scaleY        // cut in the middle of the gap
            }
            r = top - 1                                         // a gap inside a row — skip it, keep hunting
        }
        return idealEnd
    }

    /// Rasterizes `cg` to grayscale and classifies each pixel row: all-background (`blank`), a full-width
    /// rule like a divider (`line`, ≥half the width inked), or real `content`. Returns nil if the raster
    /// can't be built (callers hard-cut then).
    private static func rowInk(_ cg: CGImage) -> [RowInk]? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A CGImage drawn into a bitmap context lands with buffer row 0 == the TOP of the image (CGImage
        // data is top-row-first), which matches how `image.draw` places it in the PDF — so do NOT flip,
        // or the analysis ends up mirrored vs. the drawing and breaks land at the wrong place.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h)

        let threshold: UInt8 = 244                          // anything lighter counts as background
        var kinds = [RowInk](repeating: .content, count: h)
        for row in 0..<h {
            let base = row * w
            var inked = 0
            for c in 0..<w where buf[base + c] < threshold { inked += 1 }
            if inked == 0 { kinds[row] = .blank }
            else if inked * 2 >= w { kinds[row] = .line }   // ≥50% covered → a horizontal rule / fill
        }
        return kinds
    }
}
