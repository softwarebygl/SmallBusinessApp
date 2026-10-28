//
//  DrawnText.swift
//  GLSmallBusinessTests — Harness
//
//  What a hosted screen actually DRAWS, read back off its pixels with Vision. GLTestHost can't
//  read a SwiftUI screen's text (its header, note 2), so a test that must check what a screen
//  says draws it into an image and reads that. One helper for every suite that needs it.
//  (MoneyRoundingTests still carries an older private copy of `read`; move it onto this one
//  when that file is next touched.)
//

import SwiftUI
import SwiftData
import UIKit
import Vision

@MainActor
enum DrawnText {
    /// Everything Vision reads off `image`, one recognized line per row.
    static func read(_ image: CGImage, languages: [String] = ["en-US"]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Hosts `view` (in a NavigationStack, like a pushed screen), lets it settle, runs `change`
    /// while the screen is still live — e.g. deleting the record it holds, the way a delete on
    /// iPad or a synced pull lands under an open screen — lets SwiftUI re-render, then reads
    /// the drawn screen. `change` errors are rethrown after teardown.
    static func screen<V: View>(_ view: V, container: ModelContainer,
                                size: CGSize = CGSize(width: 430, height: 1400),
                                languages: [String] = ["en-US"],
                                drawn: ((CGImage) -> Void)? = nil,
                                after change: @escaping () throws -> Void = {}) throws -> String {
        var captured: CGImage?
        var changeError: Error?
        GLTestHost.render(view, container: container, scheme: .light, size: size) { controller in
            do { try change() } catch { changeError = error }
            var turns = 0
            while RunLoop.current.run(mode: .default, before: .distantPast), turns < 50 { turns += 1 }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
            let bounds = controller.view.bounds
            captured = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }.cgImage
        }
        if let changeError { throw changeError }
        guard let captured else { throw DrawnTextError.nothingDrawn }
        drawn?(captured)   // e.g. a test attaching the exact pixels it read, as evidence
        return try read(captured, languages: languages)
    }

    enum DrawnTextError: Error { case nothingDrawn }
}
