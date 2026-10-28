//
//  ReceiptServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The receipt save path shared by the Receipt form, the receipt lists and the assistant.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct ReceiptServiceTests {

    private var day: Date { TS.day(2026, 9, 15) }

    @Test func createTrimsLinksAndSavesAnID() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Bath", start: day, customer: customer, in: context)
        context.saveChanges()
        let draft = ReceiptDraft(vendor: " Home Depot ", date: day, total: 45.5, category: " Materials ",
                                 notes: " grout ", customer: customer, job: job)
        let receipt = try DomainState.subscribed.run { try ReceiptService.create(draft, in: context) }
        #expect(receipt.vendor == "Home Depot" && receipt.category == "Materials" && receipt.notes == "grout")
        #expect(receipt.total == 45.5 && receipt.date == day)
        #expect(receipt.customer === customer && receipt.job === job)
        #expect(receipt.syncID != nil && receipt.updatedAt != nil && !context.hasChanges,
                "saved now — the form used to leave it for autosave, with no syncID")
    }

    @Test func aBusinessReceiptMayGoOnAnyJobButACustomersOnlyOnTheirs() throws {
        let context = try DomainFixtures.context()
        let mine = TS.customer(in: context)
        let other = TS.customer(first: "Ann", last: "Lee", in: context)
        let othersJob = TS.job("Fence", start: day, customer: other, in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            _ = try ReceiptService.create(ReceiptDraft(vendor: "Lowe's", job: othersJob), in: context)
            #expect(domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "Lowe's", customer: mine, job: othersJob), in: context) }
                    == .jobBelongsToAnotherCustomer)
        }
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1)
    }

    /// Only a pairing being made now is checked: an old receipt already on another customer's job
    /// still saves a vendor fix, but moving it onto such a job is refused.
    @Test func anOldMismatchedPairingStillSaves() throws {
        let context = try DomainFixtures.context()
        let mine = TS.customer(in: context)
        let other = TS.customer(first: "Ann", last: "Lee", in: context)
        let othersJob = TS.job("Fence", start: day, customer: other, in: context)
        let myJob = TS.job("Deck", start: day, customer: mine, in: context)
        let old = Receipt(vendor: "Lowe", date: day, total: 10, category: "")
        old.customer = mine
        old.job = othersJob                                  // made before the check existed
        context.insert(old)
        context.saveChanges()
        try DomainState.subscribed.run {
            var fix = ReceiptDraft(old)
            fix.vendor = "Lowe's"
            try ReceiptService.update(old, with: fix, in: context)
            #expect(old.vendor == "Lowe's" && old.job === othersJob)
            var moved = ReceiptDraft(old)
            moved.job = myJob
            try ReceiptService.update(old, with: moved, in: context)
            var back = ReceiptDraft(old)
            back.job = othersJob
            #expect(domainError { try ReceiptService.update(old, with: back, in: context) } == .jobBelongsToAnotherCustomer)
        }
        #expect(old.job === myJob && !context.hasChanges)
    }

    /// The form's field can't make a negative total and it never refused a stored one; a tool can't.
    @Test func aNegativeTotalIsRefusedForAToolOnly() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            #expect(domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "Refund", total: -5), in: context) }
                    == .negativeValue)
            let saved = try ReceiptService.create(ReceiptDraft(vendor: "Refund", total: -5), origin: .screen, in: context)
            #expect(saved.total == -5)
        }
    }

    @Test func validationAndGates() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            #expect(domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "  "), in: context) }
                    == .receiptDetailsRequired)
            #expect(domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "X", total: -1), in: context) }
                    == .negativeValue)
            // A photo alone is enough.
            _ = try ReceiptService.create(ReceiptDraft(scanData: Data([1])), in: context)
            // So is a total.
            _ = try ReceiptService.create(ReceiptDraft(total: 3), in: context)
        }
        #expect(DomainState.lapsed.run { domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "X"), in: context) } }
                == .readOnly(operation: "saveReceipt", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 2)
    }

    @Test func theFreeReceiptCapApplies() throws {
        let context = try DomainFixtures.context()
        for _ in 0..<FreeTier.receipts { _ = TS.receipt(total: 1, category: "", date: day, in: context) }
        context.saveChanges()
        #expect(DomainState.neverSubscribed.run { domainError { _ = try ReceiptService.create(ReceiptDraft(vendor: "X"), in: context) } }
                == .freeLimitReached(operation: "saveReceipt"))
    }

    @Test func updateAndScan() throws {
        let context = try DomainFixtures.context()
        let receipt = TS.receipt(total: 10, category: "Fuel", date: day, in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            var draft = ReceiptDraft(receipt)
            draft.total = 12
            try ReceiptService.update(receipt, with: draft, in: context)
            #expect(receipt.total == 12 && receipt.category == "Fuel")

            try ReceiptService.setScan(Data([7]), recognizedText: "SHELL", for: receipt, in: context)
            #expect(receipt.scanData == Data([7]) && receipt.recognizedText == "SHELL")
            try ReceiptService.setScan(nil, for: receipt, in: context)
            #expect(receipt.scanData == nil, "vendor and total still carry it")
        }
        #expect(!context.hasChanges)

        // A photo-only receipt can't lose its photo.
        let photoOnly = try DomainState.subscribed.run { try ReceiptService.create(ReceiptDraft(scanData: Data([1])), in: context) }
        #expect(DomainState.subscribed.run { domainError { try ReceiptService.setScan(nil, for: photoOnly, in: context) } }
                == .receiptDetailsRequired)
        #expect(photoOnly.scanData != nil)
    }

    /// The form's prefill: blanks only; the date only while the person hasn't picked one.
    @Test func prefillFillsOnlyTheBlanks() {
        let scanned = ReceiptScanner.parse(lines: ["ACE HARDWARE", "09/10/2026", "TOTAL 23.50"])
        var blank = ReceiptDraft(date: day)
        let filled = ReceiptService.prefill(&blank, from: scanned, keepDate: false)
        #expect(blank.vendor == scanned.vendor && !blank.vendor.isEmpty)
        #expect(blank.total == 23.5)
        #expect(filled == scanned.date)
        #expect(blank.date == (scanned.date ?? day))
        #expect(blank.recognizedText == scanned.recognizedText)

        var typed = ReceiptDraft(vendor: "Mine", date: day, total: 5)
        #expect(ReceiptService.prefill(&typed, from: scanned, keepDate: true) == nil)
        #expect(typed.vendor == "Mine" && typed.total == 5 && typed.date == day)
        #expect(typed.recognizedText == scanned.recognizedText, "the recognized text is always replaced")
    }

    @Test func deleteIsAllOrNothing() throws {
        let context = try DomainFixtures.context()
        let a = TS.receipt(total: 1, category: "", date: day, in: context)
        let b = TS.receipt(total: 2, category: "", date: day, in: context)
        context.saveChanges()
        #expect(DomainState.offline.run { domainError { try DeletionService.delete([.receipt(a)], in: context) } }
                == .readOnly(operation: "deleteReceipt", lapsed: false))
        _ = try DomainState.subscribed.run { try DeletionService.delete([.receipt(a)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1 && !context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.receipt(b), .receipt(a)], in: context) } }
                == .recordNotFound)
        #expect(try context.fetchCount(FetchDescriptor<Receipt>()) == 1)
    }

    // MARK: Photo size (law 62)

    /// One receipt photo (a library pick, or the assistant's first scanned page) is stored at the
    /// fleet's 1024 px long edge. HEAD kept 2000 px.
    @Test func aReceiptPhotoIsStoredAtTheFleetLongEdge() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let data = try #require(ReceiptService.photoData(from: big))
        let stored = try #require(UIImage(data: data))
        let longEdge = max(stored.size.width, stored.size.height) * stored.scale
        #expect(longEdge == ImageDownsampler.intakeMaxEdge, "stored at \(longEdge) px")
        #expect(ReceiptService.maxPhotoDimension == ImageDownsampler.intakeMaxEdge)
    }
}
