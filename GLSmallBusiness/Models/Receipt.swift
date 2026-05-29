//
//  Receipt.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData

/// A scanned expense receipt for a customer's job. The scan image (a compressed JPEG of the
/// VisionKit document scan — grayscale/B&W keeps it small) plus details read from it via OCR.
@Model
final class Receipt {
    var vendor: String = ""
    var date: Date = Date.now
    var total: Double = 0
    var category: String = ""
    var notes: String = ""
    /// The raw text Vision read off the scan, kept for reference/search.
    var recognizedText: String = ""
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var scanData: Data?

    var customer: Customer?

    init(
        vendor: String = "",
        date: Date = .now,
        total: Double = 0,
        category: String = "",
        notes: String = "",
        recognizedText: String = "",
        scanData: Data? = nil,
        customer: Customer? = nil
    ) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.category = category
        self.notes = notes
        self.recognizedText = recognizedText
        self.scanData = scanData
        self.customer = customer
        self.createdAt = .now
    }
}

extension Receipt {
    var displayVendor: String {
        let trimmed = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Receipt" : trimmed
    }
}
