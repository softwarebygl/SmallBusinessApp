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
        let lines = await recognizeLines(image)
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
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY } // top of page first
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
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
