//
//  DocumentScannerView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import VisionKit

/// Presents Apple's document scanner — the Notes-style flow with automatic edge detection,
/// perspective correction, and the Color / Grayscale / Black & White filter button. Returns the
/// scanned page images (filtered per the user's choice in the scanner), each already shrunk to
/// `ReceiptScanPages.pageWidth` wide and upright, off the main thread (law 62).
///
/// Note: `VNDocumentCameraViewController.isSupported` is false on the Simulator (no camera);
/// callers should gate presentation on that.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // Full-size pages are 10+ MB each, so they are read and shrunk one at a time on a
            // background thread (Apple's own VisionKit sample reads a scan's pages off the main
            // thread too); only the small pages come back to the main actor.
            let source = ScanSource(scan: scan)
            let onComplete = onComplete
            Task {
                let pages = await Task.detached(priority: .userInitiated) { source.shrunkPages() }.value
                onComplete(pages)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}


/// A finished scan handed to a background thread. VisionKit's scan object is not marked
/// Sendable; it is only read (never changed) after the delegate hands it over, one page at a
/// time, which is how Apple's VisionKit sample uses it.
nonisolated private struct ScanSource: @unchecked Sendable {
    let scan: VNDocumentCameraScan

    nonisolated func shrunkPages() -> [UIImage] {
        (0..<scan.pageCount).map { index in
            autoreleasepool { ReceiptScanPages.shrunk(scan.imageOfPage(at: index)) }
        }
    }
}

/// A receipt photo ready to keep: the upright image the OCR reads, and the JPEG the receipt
/// stores (encoded once, off the main thread).
nonisolated struct ReceiptScanImage: Sendable {
    let image: UIImage
    let jpeg: Data
}

/// Receipt scans, one helper for every scanner (the Receipts list and the assistant's scan).
/// Law 62, owner ruling 2026-10-04: each page of a multi-page receipt scan is shrunk to
/// 1024 px wide before the pages are stacked into the receipt's one image, so every page keeps
/// a readable height (shrinking the whole stack by its long edge left a 4-page receipt about
/// 386 px wide). A one-page scan keeps the fleet's 1024 px long edge. Nothing here touches the
/// main actor: every function is safe on a background thread.
nonisolated enum ReceiptScanPages {
    /// The width, in pixels, each page of a multi-page scan is kept at.
    static let pageWidth: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.7

    /// `page` drawn upright at scale 1, at most `maxWidth` px wide and `maxHeight` px tall,
    /// never enlarged.
    static func shrunk(_ page: UIImage, maxWidth: CGFloat = pageWidth,
                       maxHeight: CGFloat = .greatestFiniteMagnitude) -> UIImage {
        let size = pixelSize(of: page)
        guard size.width > 0, size.height > 0 else { return page }
        let factor = min(1, maxWidth / size.width, maxHeight / size.height)
        let target = CGSize(width: max(1, (size.width * factor).rounded()),
                            height: max(1, (size.height * factor).rounded()))
        // Already upright, scale 1 and small enough: nothing to redraw.
        if factor == 1, page.imageOrientation == .up, page.scale == 1 { return page }
        return render(target) { page.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// The pages stacked top to bottom into one upright image. One page keeps law 62's 1024 px
    /// long edge; with two or more, each page is at most `pageWidth` wide and keeps its own
    /// height. A narrower page is never enlarged (it sits at the left edge).
    static func stitched(_ pages: [UIImage]) -> UIImage? {
        guard let first = pages.first else { return nil }
        guard pages.count > 1 else {
            return shrunk(first, maxWidth: ImageDownsampler.intakeMaxEdge, maxHeight: ImageDownsampler.intakeMaxEdge)
        }
        let shrunkPages = pages.map { shrunk($0) }
        let sizes = shrunkPages.map(pixelSize(of:))
        let canvas = CGSize(width: sizes.map(\.width).max() ?? pageWidth,
                            height: sizes.map(\.height).reduce(0, +))
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        return render(canvas) {
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvas))
            var y: CGFloat = 0
            for (page, size) in zip(shrunkPages, sizes) {
                page.draw(in: CGRect(x: 0, y: y, width: size.width, height: size.height))
                y += size.height
            }
        }
    }

    /// Stitches and encodes a scan once, on a background thread. Nil only when there are no
    /// pages or the image can't be encoded.
    static func prepared(_ pages: [UIImage]) async -> ReceiptScanImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = stitched(pages),
                  let jpeg = image.jpegData(compressionQuality: jpegQuality) else { return nil }
            return ReceiptScanImage(image: image, jpeg: jpeg)
        }.value
    }

    /// A stored receipt photo decoded for display, upright and at most `maxPixelSize` px on its
    /// long edge (never enlarged), on a background thread.
    static func displayImage(from data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            ImageDownsampler.thumbnail(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private static func render(_ size: CGSize, _ draw: () -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw() }
    }
}
