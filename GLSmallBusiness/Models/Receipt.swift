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

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
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
    /// The optional job this receipt is for (independent of `customer`). Nullify on delete — a receipt
    /// is a financial record that outlives the job. The inverse lives on `ScheduledJob.receipts`.
    var job: ScheduledJob?
    /// The optional contract this receipt is for.
    var contract: Contract?

    init(
        vendor: String = "",
        date: Date = .now,
        total: Double = 0,
        category: String = "",
        notes: String = "",
        recognizedText: String = "",
        scanData: Data? = nil,
        customer: Customer? = nil,
        job: ScheduledJob? = nil,
        contract: Contract? = nil
    ) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.category = category
        self.notes = notes
        self.recognizedText = recognizedText
        self.scanData = scanData
        self.customer = customer
        self.job = job
        self.createdAt = .now
    }
}

extension Receipt {
    var displayVendor: String {
        let trimmed = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Receipt" : trimmed
    }
}
