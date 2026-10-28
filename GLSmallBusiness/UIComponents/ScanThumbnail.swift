//
//  ScanThumbnail.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  A small thumbnail of a stored receipt scan. Scans are saved at full capture resolution, so the
//  receipts list must NOT do `UIImage(data:)` per row on the main thread — that faults a multi-MB
//  blob and decodes tens of MB while scrolling. This decodes only a small thumbnail (via ImageIO,
//  which never fully decodes the original) OFF the main thread, so scrolling stays smooth.
//

import SwiftUI
import GoldLifeUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

enum ImageDownsampler {
    /// Decode just a thumbnail no larger than `maxPixelSize` px from `data`, without decoding the
    /// full image into memory. `nonisolated` so the decode genuinely runs off the main actor — the
    /// project defaults declarations to @MainActor, which would otherwise pull this back onto it and
    /// defeat the whole point (it touches only its params + ImageIO/UIImage, no main-actor state).
    nonisolated static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Downsize image `data` to at most `maxPixelSize` px on the long edge and re-encode as JPEG, for
    /// STORAGE (not just a thumbnail). Memory-efficient — never fully decodes the original. nonisolated
    /// so callers can run it off the main actor.
    nonisolated static func downsizedJPEG(from data: Data, maxPixelSize: CGFloat, quality: CGFloat = 0.7) -> Data? {
        (thumbnail(from: data, maxPixelSize: maxPixelSize) ?? UIImage(data: data))?
            .jpegData(compressionQuality: quality)
    }

    /// Photo Intake Memory Defense (fleet rule): a picked photo is downsampled to at most this
    /// many pixels on its long edge BEFORE it is held in memory, encoded or stored.
    nonisolated static let intakeMaxEdge: CGFloat = 1024

    /// A picked photo's bytes as a JPEG no larger than `intakeMaxEdge`, decoded OFF the main
    /// thread (ImageIO thumbnailing — the full-size image is never decoded).
    nonisolated static func intakeJPEG(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            downsizedJPEG(from: data, maxPixelSize: intakeMaxEdge)
        }.value
    }

    /// A picked photo's bytes as an image no larger than `intakeMaxEdge`, decoded off the main
    /// thread — for a step that still works on the picture (the logo crop).
    nonisolated static func intakeImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            thumbnail(from: data, maxPixelSize: intakeMaxEdge)
        }.value
    }

    /// The side, in pixels, a cropped profile photo or business logo is saved at (the crop
    /// screen draws the square at most this big, never enlarging a small photo).
    nonisolated static let croppedSide: CGFloat = 600

    /// Downsize a UIImage to at most `maxDimension` pt on the long edge and JPEG-encode it.
    nonisolated static func downsizedJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat = 0.7) -> Data? {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension else { return image.jpegData(compressionQuality: quality) }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: (image.size.width * scale).rounded(),
                             height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
            .jpegData(compressionQuality: quality)
    }
}

/// A picked photo, already shrunk by `ImageDownsampler.intakeImage`, waiting in the crop screen
/// (GoldLifeUI's `GLSquarePhotoCropper`) — the `.fullScreenCover(item:)` wrapper that makes a
/// `UIImage` Identifiable. Shared by every profile-photo flow (customer, employee, subcontractor).
struct CroppableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ScanThumbnail: View {
    @Environment(\.colorScheme) private var colorScheme
    let data: Data?
    var size: CGFloat = 44

    @State private var image: UIImage?

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    gold.opacity(0.15)
                    Image(systemName: "doc.text.image").foregroundStyle(gold)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        // A picture with no words of its own: silent here. A row says what it is next to it,
        // and a thumbnail that is a button gets its name from that button.
        .accessibilityHidden(true)
        .task(id: data) {
            guard let data else { image = nil; return }
            let maxPixel = size * 3   // crisp on retina, still tiny
            let decoded = await Task.detached(priority: .utility) {
                ImageDownsampler.thumbnail(from: data, maxPixelSize: maxPixel)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}
