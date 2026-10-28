//
//  ReceiptScanner.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import UIKit
@preconcurrency import Vision

/// Best-effort details read off a scanned receipt.
struct ScannedReceipt {
    var vendor: String = ""
    var date: Date?
    var total: Double?
    var recognizedText: String = ""
}

/// On-device receipt OCR (Vision) plus heuristic extraction of vendor, date, and total.
/// Vision text recognition runs on the Simulator too (only the camera doesn't), so the parser
/// is testable without a device.
enum ReceiptScanner {
    static func parse(_ image: UIImage) async -> ScannedReceipt {
        parse(lines: await recognizeLines(image))
    }

    /// The pure half: recognized lines in, a receipt out. Split from `parse(_:)` so the
    /// extraction rules — which decide what dollar amount lands on an expense — can be
    /// tested for exact answers. Driving them through OCR can't do that: recognition of
    /// a rendered receipt is close but not certain, so an assertion on an exact total
    /// would be testing Vision's accuracy rather than these rules.
    static func parse(lines: [String]) -> ScannedReceipt {
        let text = lines.joined(separator: "\n")
        return ScannedReceipt(
            vendor: vendor(from: lines),
            date: date(from: text),
            total: total(from: lines),
            recognizedText: text
        )
    }

    /// Recognized text lines, ordered top-to-bottom on the page.
    private static func recognizeLines(_ image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        // The pixels may be stored turned (a photo keeps the camera's turn as its orientation).
        // Vision is told how they are turned, so its boxes, and the top-to-bottom order below,
        // follow the receipt as it is read rather than the raw pixels.
        let orientation = cgOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // perform(_:) is synchronous, so results are read after it returns rather than in a
                // completion handler — that guarantees the continuation resumes exactly once, even
                // when perform throws (Vision can both call the handler with an error AND throw).
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let lines = (request.results ?? [])
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY } // top of page first
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
        }
    }

    /// UIKit's orientation as the EXIF value Vision takes.
    nonisolated static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    // MARK: - Heuristic extraction

    /// The first line that reads like a name (the merchant is usually at the top).
    private static func vendor(from lines: [String]) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.filter(\.isLetter).count >= 3 { return trimmed }
        }
        return ""
    }

    /// The first date found anywhere in the text (NSDataDetector handles many formats).
    private static func date(from text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.date
    }

    /// Prefer a currency amount on a line mentioning "total" (but not "subtotal"); otherwise the
    /// largest amount found.
    private static func total(from lines: [String]) -> Double? {
        var totalCandidates: [Double] = []
        var allAmounts: [Double] = []
        for line in lines {
            let lower = line.lowercased()
            let amounts = currencyAmounts(in: line)
            allAmounts.append(contentsOf: amounts)
            if lower.contains("total"), !lower.contains("subtotal"), !lower.contains("sub total") {
                totalCandidates.append(contentsOf: amounts)
            }
        }
        return totalCandidates.max() ?? allAmounts.max()
    }

    /// Amounts like 45.47, 1,234.56, 1234.56 (two decimal places).
    private static func currencyAmounts(in string: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"\d[\d,]*\.\d{2}"#) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard let r = Range(match.range, in: string) else { return nil }
            return Double(string[r].replacingOccurrences(of: ",", with: ""))
        }
    }
}
