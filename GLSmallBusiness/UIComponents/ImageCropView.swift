//
//  ImageCropView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI
import UIKit

/// A pinch-to-zoom / drag-to-position cropper that returns a square image, sized for the
/// circular customer avatar.
///
/// `PhotosPicker` (which the app uses, so there's no photo-library permission prompt) doesn't
/// offer a crop step, so this provides one: the picked image is shown behind a circular window
/// the user can position the subject within, then `onCrop` returns the cropped square.
///
/// The same `croppableImage(side:)` view is used for both the live preview and the final
/// `ImageRenderer` capture, so what the user sees is exactly what gets saved.
struct ImageCropView: View {
    /// The crop guide/overlay shape. The output image is always square; this only changes the
    /// cutout's look — a circle for round avatars, a rounded rectangle for logos.
    enum Guide { case circle, roundedRect }

    let image: UIImage
    var guide: Guide = .circle
    var onCancel: () -> Void
    var onCrop: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var cropSide: CGFloat = 300

    /// Stored image resolution (square, in pixels).
    private let outputSize: CGFloat = 600
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width, geo.size.height) - 48)
            ZStack {
                Color.black

                croppableImage(side: side)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(side: side).simultaneously(with: magnifyGesture(side: side)))

                guideMask(side: side).allowsHitTesting(false)

                // Bar pinned to the top, pushed below the measured safe-area inset (handles the
                // status bar / Dynamic Island even when the cover doesn't pass the safe area down).
                VStack(spacing: 0) {
                    topBar
                        .padding(.top, max(geo.safeAreaInsets.top, Self.windowTopInset))
                    Spacer()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { cropSide = side; clamp(side: side) }
            .onChange(of: side) { _, newSide in
                cropSide = newSide
                clamp(side: newSide)
            }
        }
        .ignoresSafeArea()
    }

    /// The image, transformed and clipped to the crop square. Shared by the preview and the render.
    private func croppableImage(side: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: side, height: side)
            .clipped()
    }

    /// Dims everything outside the crop window and outlines it, in the configured shape.
    @ViewBuilder
    private func guideMask(side: CGFloat) -> some View {
        switch guide {
        case .circle:      dimmedOutside(side: side, shape: Circle())
        case .roundedRect: dimmedOutside(side: side, shape: RoundedRectangle(cornerRadius: 28))
        }
    }

    private func dimmedOutside<S: InsettableShape>(side: CGFloat, shape: S) -> some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .reverseMask { shape.frame(width: side, height: side) }
            .overlay {
                shape
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: side, height: side)
            }
    }

    /// Nav-bar-style top bar: Cancel (leading), title (center), Use (trailing). As the first element
    /// of a safe-area-respecting VStack, it always sits below the status bar / Dynamic Island.
    private var topBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
            Spacer()
            Text("Move & Scale")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Use") { crop(side: cropSide) }
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Gestures

    private func magnifyGesture(side: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), maxScale)
                clamp(side: side)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                clamp(side: side)
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// Keeps the image covering the crop window so no black gaps can show.
    private func clamp(side: CGFloat) {
        let fill = max(side / image.size.width, side / image.size.height)
        let displayedW = image.size.width * fill * scale
        let displayedH = image.size.height * fill * scale
        let maxX = max(0, (displayedW - side) / 2)
        let maxY = max(0, (displayedH - side) / 2)
        offset = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    // MARK: - Render

    @MainActor private func crop(side: CGFloat) {
        let renderer = ImageRenderer(content: croppableImage(side: side))
        renderer.scale = outputSize / side
        onCrop(renderer.uiImage ?? image)
    }

    /// The device's top safe-area inset, read straight from the key window — a reliable fallback
    /// for when the presentation (e.g. a `fullScreenCover`) doesn't pass the SwiftUI safe area in.
    @MainActor private static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

private extension View {
    /// Punches the given shape out of the receiver (the inverse of `.mask`).
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
        }
    }
}
