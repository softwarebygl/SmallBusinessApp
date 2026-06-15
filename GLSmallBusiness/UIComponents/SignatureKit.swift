//
//  SignatureKit.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Building blocks for the saved signature: a PencilKit drawing canvas, helpers that turn a
//  drawing / typed name / imported photo into a transparent PNG, and a Face ID gate.

import SwiftUI
import PencilKit
import LocalAuthentication

// MARK: - Drawing canvas

/// A PencilKit canvas that signs with finger or Apple Pencil and reports its drawing back.
struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: SignatureCanvas
        init(_ parent: SignatureCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

// MARK: - Rendering to a transparent PNG

enum SignatureRender {
    /// A drawn signature, cropped to its strokes, as a transparent PNG.
    @MainActor
    static func png(from drawing: PKDrawing) -> Data? {
        let bounds = drawing.bounds
        guard !bounds.isEmpty, bounds.width > 1, bounds.height > 1 else { return nil }
        return drawing.image(from: bounds, scale: 3).pngData()
    }

    /// A typed name rendered in the calligraphic brand font as a transparent PNG.
    @MainActor
    static func png(typed name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let renderer = ImageRenderer(content:
            Text(trimmed)
                .font(.custom("Italianno-Regular", size: 64))
                .foregroundStyle(.black)
                .padding(8)
        )
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    /// An imported photo with near-white pixels knocked out so it sits cleanly on a signature line.
    static func transparentPNG(from image: UIImage) -> Data? {
        guard let cg = image.cgImage else { return image.pngData() }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return image.pngData() }
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image.pngData()
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var i = 0
        while i < pixels.count {
            if pixels[i] > 225, pixels[i + 1] > 225, pixels[i + 2] > 225 {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            }
            i += bytesPerPixel
        }
        guard let out = ctx.makeImage() else { return image.pngData() }
        return UIImage(cgImage: out).pngData()
    }
}

// MARK: - Biometric gate

enum BiometricGate {
    /// Prompts for Face ID / Touch ID (with passcode fallback) before revealing or applying the
    /// signature. Returns true on success. If the device has no biometrics or passcode set, there
    /// is nothing to gate against, so access is allowed rather than permanently blocked.
    @MainActor
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Passcode")
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}
