//
//  PaginatedPDF.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Renders a fixed-width SwiftUI document view into a multi-page US-Letter PDF (612×792pt), splitting
//  tall content (a long invoice / estimate / change order / receipt) across pages instead of emitting
//  one oversized page that prints scaled-down or clips. Content is rasterized at `scale` so pagination
//  is reliable and predictable. Shared by all of the app's ImageRenderer-based document generators.
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

    /// Renders `content` (already laid out to `width`) into a multi-page Letter PDF at `url`.
    /// Returns `url` on success, or `nil` if the view couldn't be rendered.
    static func render(_ content: some View, width: CGFloat = pageWidth, to url: URL, scale: CGFloat = 2) -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        guard let image = renderer.uiImage, image.size.height > 0 else { return nil }

        // Each page is Letter-proportioned for the requested width (792pt tall at 612pt wide).
        let height = pageHeight * (width / pageWidth)
        let pageSize = CGSize(width: width, height: height)
        let contentHeight = image.size.height
        let pageCount = max(1, Int((contentHeight / height).rounded(.up)))

        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        do {
            try pdf.writePDF(to: url) { ctx in
                for page in 0..<pageCount {
                    ctx.beginPage()
                    // Draw the full content shifted up so this page shows its band; the page bounds clip
                    // the rest. A row can split across a page boundary, but every page is true Letter size.
                    image.draw(in: CGRect(x: 0, y: -CGFloat(page) * height, width: width, height: contentHeight))
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
