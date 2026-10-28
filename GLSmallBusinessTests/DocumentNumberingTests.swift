//
//  DocumentNumberingTests.swift
//  GLSmallBusinessTests
//
//  THE home for document numbering: the per-document `nextNumber` sequences (invoice, estimate,
//  change order), the malformed numbers each one ignores, and the two anti-reuse mechanisms —
//  BusinessProfile's monotonic counter for invoices / estimates and the invoice's
//  `changeOrderNumberSeed` for change orders — so deleting the highest-numbered document can never
//  hand its number to the next one.
//

import Testing
@testable import GLSmallBusiness

@MainActor
struct DocumentNumberingTests {

    // MARK: - Invoices

    @Test func nextNumberHandlesEmptyGarbageAndWideNumbers() {
        #expect(Invoice.nextNumber(after: []) == "INV-0001")

        let garbage = [Invoice(number: "not-a-number"), Invoice(number: ""), Invoice(number: "INV-abc")]
        #expect(Invoice.nextNumber(after: garbage) == "INV-0001")   // unparseable entries are ignored

        let wide = [Invoice(number: "INV-9999")]
        #expect(Invoice.nextNumber(after: wide) == "INV-10000")     // format grows past four digits

        let mixed = [Invoice(number: "INV-0007"), Invoice(number: "INV-0003"), Invoice(number: "nope")]
        #expect(Invoice.nextNumber(after: mixed) == "INV-0008")     // no profile → plain max + 1
    }

    @Test func nextNumberUsesAndBumpsTheProfileCounterSoDeletionsCantReuseANumber() {
        // A fresh profile starts the sequence at 0001 and walks it one number at a time.
        let fresh = BusinessProfile()
        #expect(Invoice.nextNumber(after: [], profile: fresh) == "INV-0001")
        let first = Invoice(number: "INV-0001")
        #expect(Invoice.nextNumber(after: [first], profile: fresh) == "INV-0002")
        // Delete the highest-numbered invoice (only INV-0001 is left) and mint again: the counter
        // remembered 0002, so the next number is 0003 — NOT a reused 0002.
        #expect(Invoice.nextNumber(after: [first], profile: fresh) == "INV-0003")

        let profile = BusinessProfile()
        profile.lastInvoiceNumber = 12
        // Highest existing (5) is below the counter → the counter wins.
        #expect(Invoice.nextNumber(after: [Invoice(number: "INV-0005")], profile: profile) == "INV-0013")
        #expect(profile.lastInvoiceNumber == 13)
        // Delete everything and ask again: the number is NOT reused.
        #expect(Invoice.nextNumber(after: [], profile: profile) == "INV-0014")
        #expect(profile.lastInvoiceNumber == 14)
        // An existing number above the counter wins instead.
        #expect(Invoice.nextNumber(after: [Invoice(number: "INV-0200")], profile: profile) == "INV-0201")
        #expect(profile.lastInvoiceNumber == 201)
    }

    // MARK: - Estimates

    /// Estimate numbering ignores malformed numbers and honors the profile's monotonic counter.
    @Test func estimateNumberingIgnoresGarbageAndRespectsTheCounter() {
        #expect(Estimate.nextNumber(after: []) == "EST-0001")
        #expect(Estimate.nextNumber(after: [Estimate(number: "EST-abc")]) == "EST-0001")   // non-numeric alone is ignored
        #expect(Estimate.nextNumber(after: [Estimate(number: "EST-0007")]) == "EST-0008")

        let existing = [Estimate(number: "EST-0007"), Estimate(number: "EST-abc"),
                        Estimate(number: ""), Estimate(number: "EST-0012")]
        #expect(Estimate.nextNumber(after: existing) == "EST-0013")

        let profile = BusinessProfile()
        profile.lastEstimateNumber = 40
        #expect(Estimate.nextNumber(after: existing, profile: profile) == "EST-0041")
        #expect(profile.lastEstimateNumber == 41)
        // The counter now leads, so deleting the highest estimate can't reuse its number.
        #expect(Estimate.nextNumber(after: [], profile: profile) == "EST-0042")
    }

    // MARK: - Change orders

    /// Change-order numbering: garbage numbers are ignored, and the numeric parser rejects
    /// anything that isn't a plain "CO-N".
    @Test func changeOrderNumberParsingRejectsGarbage() {
        #expect(ChangeOrder.numberValue(of: "CO-0004") == 4)
        #expect(ChangeOrder.numberValue(of: "CO-12") == 12)
        #expect(ChangeOrder.numberValue(of: "CO-") == nil)
        #expect(ChangeOrder.numberValue(of: "") == nil)
        #expect(ChangeOrder.numberValue(of: "X-1") == nil)
        #expect(ChangeOrder.numberValue(of: "CO-abc") == nil)
        #expect(ChangeOrder.numberValue(of: "CO-0004a") == nil)

        #expect(ChangeOrder.nextNumber(after: []) == "CO-0001")
        #expect(ChangeOrder.nextNumber(after: [ChangeOrder(number: "CO-oops"),
                                               ChangeOrder(number: "")]) == "CO-0001")
        // Without a seed it is plain max + 1 — the sequence is per invoice.
        #expect(ChangeOrder.nextNumber(after: [ChangeOrder(number: "CO-0003")]) == "CO-0004")
    }

    @Test func nextNumberNeverReusesDeletedHighest() {
        // The invoice's seed remembers every number ever minted, so deleting the highest
        // order can't hand its number to the next one: next = max(seed, highest) + 1.
        #expect(ChangeOrder.nextNumber(after: [], seed: 3) == "CO-0004")
        #expect(ChangeOrder.nextNumber(after: [ChangeOrder(number: "CO-0002")], seed: 3) == "CO-0004")
        #expect(ChangeOrder.nextNumber(after: [ChangeOrder(number: "CO-0003")], seed: 9) == "CO-0010")
        #expect(ChangeOrder.nextNumber(after: [ChangeOrder(number: "CO-0005")], seed: 3) == "CO-0006")

        let invoice = Invoice(number: "INV-0001")
        invoice.changeOrderNumberSeed = 3
        #expect(ChangeOrder.nextNumber(for: invoice) == "CO-0004")
    }
}
