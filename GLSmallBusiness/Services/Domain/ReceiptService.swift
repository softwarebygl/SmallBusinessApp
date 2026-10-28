//
//  ReceiptService.swift
//  GLSmallBusiness
//
//  Every receipt write — the Receipt form (new, scanned, edited) and (later) the assistant's tools
//  (the lists' delete is `DeletionService`'s). Rules kept from the form: vendor, category and notes trimmed; a
//  receipt needs a vendor, a total above zero, or a photo; the customer nil means "Business".
//  New here: every write ends in `saveChanges()` — the form used to rely on autosave, so a new
//  receipt had no syncID until the next launch. A new or CHANGED job/customer pairing has to match
//  (the form's picker only ever offered the customer's jobs, but its save never checked; an old
//  receipt already mismatched still saves when neither changes). From a tool the total can't be
//  negative (the form's field can't produce one, and it never refused a stored one).
//

import Foundation
import SwiftData
import UIKit

/// A receipt's editable fields, as the form or a tool supplies them (untrimmed is fine).
struct ReceiptDraft {
    var vendor = ""
    var date: Date = .now
    var total: Double = 0
    var category = ""
    var notes = ""
    /// The text OCR read off the photo, kept for reference and search.
    var recognizedText = ""
    /// The photo (a downsized JPEG), or nil for none.
    var scanData: Data?
    /// nil = a business expense.
    var customer: Customer?
    var job: ScheduledJob?

    init(vendor: String = "", date: Date = .now, total: Double = 0, category: String = "",
         notes: String = "", recognizedText: String = "", scanData: Data? = nil,
         customer: Customer? = nil, job: ScheduledJob? = nil) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.category = category
        self.notes = notes
        self.recognizedText = recognizedText
        self.scanData = scanData
        self.customer = customer
        self.job = job
    }

    /// The receipt's current values — the starting point for a partial edit.
    init(_ receipt: Receipt) {
        self.init(vendor: receipt.vendor, date: receipt.date, total: receipt.total,
                  category: receipt.category, notes: receipt.notes,
                  recognizedText: receipt.recognizedText, scanData: receipt.scanData,
                  customer: receipt.customer, job: receipt.job)
    }

    /// A vendor, a total of at least a cent (as it will show and be stored), or a photo — what the
    /// form's Save requires.
    var hasDetails: Bool {
        !vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || DomainMoney.roundedToCents(total) > 0 || scanData != nil
    }
}

@MainActor
enum ReceiptService {

    /// The longest side a stored single receipt photo keeps: the fleet's 1024 px (law 62). A
    /// multi-page camera scan is stitched by `ReceiptScanPages` instead, 1024 px wide per page.
    static let maxPhotoDimension: CGFloat = ImageDownsampler.intakeMaxEdge

    /// Adds a receipt. Checked against the free receipt cap, as every door to the form already is.
    @discardableResult
    static func create(_ draft: ReceiptDraft, origin: WriteOrigin = .tool, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> Receipt {
        try DomainGate.requireCanCreate(Receipt.self, cap: FreeTier.receipts, operation: .saveReceipt,
                                        in: context, subscription)
        try validate(draft, origin, stored: nil)
        let receipt = Receipt()
        context.insert(receipt)
        apply(draft, to: receipt)
        context.saveChanges()
        return receipt
    }

    /// Edits a receipt in place (including its photo: nil removes it).
    static func update(_ receipt: Receipt, with draft: ReceiptDraft, origin: WriteOrigin = .tool,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveReceipt, subscription)
        try DomainGate.requireLive(receipt, .saveReceipt)
        try validate(draft, origin, stored: receipt)
        apply(draft, to: receipt)
        context.saveChanges()
    }

    /// Sets the receipt photo, or removes it with `nil`. Removing the photo of a receipt with no
    /// vendor and no total would leave nothing to show, so that is refused like the form's Save.
    static func setScan(_ data: Data?, recognizedText: String? = nil, for receipt: Receipt,
                        in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveReceipt, subscription)
        try DomainGate.requireLive(receipt, .saveReceipt)
        var draft = ReceiptDraft(receipt)
        draft.scanData = data
        guard draft.hasDetails else { throw DomainGate.refusal(.receiptDetailsRequired, .saveReceipt) }
        setIfChanged(receipt, \.scanData, data)
        if let recognizedText { setIfChanged(receipt, \.recognizedText, recognizedText) }
        context.saveChanges()
    }

    // MARK: Photo reading (no writes)

    /// Reads vendor, date and total off a receipt photo with on-device OCR.
    static func read(_ image: UIImage) async -> ScannedReceipt {
        await ReceiptScanner.parse(image)
    }

    /// Fills the draft's blanks from what OCR read — the form's prefill rule: the vendor only when
    /// empty, the total only when zero, the date only when `keepDate` is false (the person hasn't
    /// picked one). The recognized text is always replaced. Returns the date it filled in, if any.
    @discardableResult
    static func prefill(_ draft: inout ReceiptDraft, from scanned: ScannedReceipt, keepDate: Bool) -> Date? {
        if draft.vendor.isEmpty { draft.vendor = scanned.vendor }
        var filledDate: Date?
        if !keepDate, let date = scanned.date {
            draft.date = date
            filledDate = date
        }
        if draft.total == 0, let total = scanned.total { draft.total = total }
        draft.recognizedText = scanned.recognizedText
        return filledDate
    }

    /// A photo as the form stores it: downsized JPEG.
    static func photoData(from image: UIImage) -> Data? {
        ImageDownsampler.downsizedJPEG(image, maxDimension: maxPhotoDimension)
    }

    // MARK: - Rules

    private static func validate(_ draft: ReceiptDraft, _ origin: WriteOrigin, stored: Receipt?) throws {
        guard draft.hasDetails else { throw DomainGate.refusal(.receiptDetailsRequired, .saveReceipt) }
        if origin == .tool { try DomainGate.requireNonNegative(draft.total, for: .saveReceipt) }
        if let customer = draft.customer { try DomainGate.requireLive(customer, .saveReceipt) }
        if let job = draft.job {
            try DomainGate.requireLive(job, .saveReceipt)
            // Only a pairing being made now is checked: re-saving an old receipt with the same job
            // and customer (fixing a vendor typo) keeps working, whatever that pairing is.
            let pairingChanged = stored.map {
                $0.job?.persistentModelID != job.persistentModelID
                    || $0.customer?.persistentModelID != draft.customer?.persistentModelID
            } ?? true
            // A Business receipt may go on any job; a customer's only on that customer's jobs.
            if pairingChanged, let customer = draft.customer,
               job.customer?.persistentModelID != customer.persistentModelID {
                throw DomainGate.refusal(.jobBelongsToAnotherCustomer, .saveReceipt)
            }
        }
    }

    private static func apply(_ draft: ReceiptDraft, to receipt: Receipt) {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        setIfChanged(receipt, \.customer, draft.customer)
        setIfChanged(receipt, \.job, draft.job)
        setIfChanged(receipt, \.vendor, trim(draft.vendor))
        setIfChanged(receipt, \.date, draft.date)
        setIfChanged(receipt, \.total, DomainMoney.roundedToCents(draft.total))   // stored as it shows (law 60)
        setIfChanged(receipt, \.category, trim(draft.category))
        setIfChanged(receipt, \.notes, trim(draft.notes))
        setIfChanged(receipt, \.recognizedText, draft.recognizedText)
        setIfChanged(receipt, \.scanData, draft.scanData)
    }
}
