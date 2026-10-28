//
//  DeletedRowFenceTests.swift
//  GLSmallBusinessTests
//
//  A confirmed swipe delete crashed the iPhone Estimates list (2026-10-03 QA, F4), and the
//  Invoices list the same way: SwiftUI renders the deleted record's row (and its status badge)
//  once more, the row reads `total`, and the SAVED-deleted record still handed back its old
//  line items, because with no `modelContext` `liveRows` took it for an unmanaged fixture.
//  Reading `EstimateLineItem.discountType` on one of those traps inside SwiftData.
//
//  `liveRows` now returns nothing for a saved delete (`isSavedDelete`). The failing shape needs
//  a STORE-BACKED record, fetched in a context of its own the way a list's @Query hands rows
//  out: before the fence, `aStoreBackedSavedDeletedEstimateReadsNoRows` still got its 2 dead
//  line items back and a non-zero total (measured 2026-10-03; the app traps reading them).
//  Records built in the same context read empty either way, so the two same-context tests
//  below guard the shape, not the red. Every test reads `total` once before the delete, as the
//  list row does: a saved-deleted record's OWN attributes that were never read trap too
//  (measured 2026-10-03, `\Estimate.discountType`), which the fence cannot help.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct DeletedRowFenceTests {

    /// A fixture that was never inserted is alive: its rows and totals still read.
    @Test func anUnmanagedRecordIsNotASavedDelete() {
        let estimate = TS.estimate(lines: [(1000, false)])
        #expect(estimate.modelContext == nil)
        #expect(!estimate.isSavedDelete)
        #expect(estimate.allLineItems.count == 1)
        #expect(close(estimate.total, 1000))
    }

    /// Inserted (not yet saved), saved, and pending-delete records are not saved deletes.
    @Test func liveAndPendingRecordsAreNotSavedDeletes() throws {
        let context = try TestStore.makeContainer().mainContext
        let estimate = TS.estimate(number: "EST-FENCE-1", lines: [(1000, false)], in: context)
        #expect(!estimate.isSavedDelete, "inserted, not saved")
        try context.save()
        #expect(!estimate.isSavedDelete, "saved")
        context.delete(estimate)
        #expect(!estimate.isSavedDelete, "a pending delete is still attached (isDeleted covers it)")
    }

    /// The crash shape: the delete is saved (what DeletionService does) while a row still holds
    /// the estimate. Its accessors and totals must read nothing instead of its dead line items.
    @Test func aSavedDeletedEstimateReadsNoRows() throws {
        let context = try TestStore.makeDiskContainer().mainContext   // SQLite, as the app
        let estimate = TS.estimate(number: "EST-FENCE-2", lines: [(1000, false), (250, true)], in: context)
        try context.save()
        #expect(close(estimate.total, 1250))   // the row rendered it once, as the list does
        try DeletionService.delete([.estimate(estimate)], origin: .screen, in: context)   // the list's confirmed delete
        #expect(estimate.modelContext == nil)
        #expect(estimate.isSavedDelete)
        #expect(estimate.sortedGroups.isEmpty)
        #expect(estimate.allLineItems.isEmpty)
        #expect(close(estimate.total, 0), "the row's total read must not reach the dead line items")
    }

    /// The red shape (fails without the fence): the estimate comes from the store into a context
    /// of its own, as a list's @Query hands it to a row, and that context deletes and saves it.
    @Test func aStoreBackedSavedDeletedEstimateReadsNoRows() throws {
        let container = try TestStore.makeDiskContainer()
        let seed = container.mainContext
        _ = TS.estimate(number: "EST-FENCE-3", lines: [(1000, false), (250, true)], in: seed)
        try seed.save()
        let context = ModelContext(container)
        let estimate = try #require(try context.fetch(FetchDescriptor<Estimate>()).first)
        #expect(close(estimate.total, 1250))   // the row rendered it once, as the list does
        try DeletionService.delete([.estimate(estimate)], origin: .screen, in: context)
        #expect(estimate.modelContext == nil)
        #expect(estimate.isSavedDelete)
        #expect(estimate.allLineItems.isEmpty, "a saved delete hands back none of its dead line items")
        #expect(close(estimate.total, 0))
    }

    /// Same for an invoice: its rows and status badge read `total` and `isPaid`.
    @Test func aSavedDeletedInvoiceReadsNoRows() throws {
        let context = try TestStore.makeDiskContainer().mainContext   // SQLite, as the app
        let invoice = TS.invoice(number: "INV-FENCE-1", lines: [(1000, false)], in: context)
        try context.save()
        #expect(close(invoice.total, 1000))   // the row rendered it once, as the list does
        _ = invoice.displayStatus              // and so did its InvoiceStatusBadge
        try DeletionService.delete([.invoice(invoice)], origin: .screen, in: context)   // the list's confirmed delete
        #expect(invoice.isSavedDelete)
        #expect(close(invoice.total, 0))
        _ = invoice.displayStatus   // the badge's re-read, the second crash site (must not trap)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
}
