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
    let image: UIImage
    var onCancel: () -> Void
    var onCrop: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Stored image resolution (square, in pixels).
    private let outputSize: CGFloat = 600
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width, geo.size.height) - 64)
            ZStack {
                Color.black.ignoresSafeArea()

                croppableImage(side: side)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(side: side).simultaneously(with: magnifyGesture(side: side)))

                circleMask(side: side).allowsHitTesting(false)

                VStack {
                    Spacer()
                    controlsBar(side: side)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { clamp(side: side) }
        }
        .background(Color.black.ignoresSafeArea())
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

    /// Dims everything outside the crop circle and draws the circle outline.
    private func circleMask(side: CGFloat) -> some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .reverseMask { Circle().frame(width: side, height: side) }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: side, height: side)
            }
            .ignoresSafeArea()
    }

    private func controlsBar(side: CGFloat) -> some View {
        HStack {
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white)
            Spacer()
            Text("Pinch to zoom · drag to position")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button("Use") { crop(side: side) }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.4))
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
