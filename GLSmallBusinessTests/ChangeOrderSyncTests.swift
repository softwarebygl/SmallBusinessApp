//
//  ChangeOrderSyncTests.swift
//  GLSmallBusinessTests
//
//  The change-order ↔ invoice billing sync beyond plain apply / remove (which — with decline and the
//  apply-once rule — lives in CalendarJobsEstimatesCoverageTests, section 8): editing re-syncs the
//  billed amounts, deleting a linked order cascades its group away, the pre-link legacy fallback,
//  and applied items billing at the invoice's LIVE tax rate. These need a live context
//  (insert/delete/cascade), so they build on TestStore's in-memory container.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ChangeOrderSyncTests {

    /// Invoice + approved CO in a fresh store's main context, saved and ready to apply.
    private func makeScenario(taxRatePercent: Double = 0,
                              invoiceLines: [(Double, Bool)] = [(1000, false)],
                              coLines: [(Double, Bool)] = [(200, false)])
    throws -> (ModelContext, Invoice, ChangeOrder) {
        let ctx = try TestStore.makeContainer().mainContext
        let inv = TS.invoice(taxRatePercent: taxRatePercent, lines: invoiceLines, in: ctx)
        let co = TS.changeOrder(inv, status: .approved, taxRatePercent: taxRatePercent,
                                lines: coLines, in: ctx)
        try ctx.save()
        return (ctx, inv, co)
    }

    @Test func applyEditResyncBillsTheNewAmount() throws {
        let (ctx, inv, co) = try makeScenario()
        co.addItemsToInvoice(using: ctx)
        try ctx.save()
        let groupSortIndex = co.invoiceGroup?.sortIndex
        #expect(close(inv.total, 1200))

        // Edit the order the way the form does: replace its line items with new amounts.
        for old in co.sortedLineItems { ctx.delete(old) }
        let bigger = ChangeOrderLineItem(name: "Bigger scope", quantity: 1, unit: .job,
                                         unitPrice: 350, sortIndex: 0)
        bigger.changeOrder = co
        ctx.insert(bigger)
        try ctx.save()

        #expect(co.resyncInvoiceItems(using: ctx))
        try ctx.save()
        #expect(co.appliedToInvoice)
        #expect(close(inv.total, 1350))              // the invoice re-bills the edited amount
        #expect(co.invoiceGroup?.sortIndex == groupSortIndex)   // keeps its position
    }

    @Test func deletingLinkedAppliedOrderCascadesItsGroup() throws {
        let (ctx, inv, co) = try makeScenario()
        co.addItemsToInvoice(using: ctx)
        try ctx.save()
        #expect(inv.sortedGroups.count == 2)

        ctx.delete(co)
        try ctx.save()
        #expect(inv.sortedGroups.count == 1)         // the cascade removed the pushed group
        #expect(close(inv.total, 1000))
        #expect(try ctx.fetchCount(FetchDescriptor<ChangeOrder>()) == 0)
    }

    @Test func legacyUnlinkedSingleAppliedOrderIsIdentifiedAndRemoved() throws {
        let (ctx, inv, co) = try makeScenario()
        co.addItemsToInvoice(using: ctx)
        try ctx.save()

        // Simulate a pre-link apply: the group exists but carries no order link.
        co.invoiceGroup?.changeOrder = nil
        co.invoiceGroup = nil
        co.appliedToInvoice = true                   // clearing the link must not clear the flag
        try ctx.save()

        #expect(co.removeItemsFromInvoice(using: ctx))   // the single-CO fallback finds it
        try ctx.save()
        #expect(!co.appliedToInvoice)
        #expect(close(inv.total, 1000))
        #expect(inv.sortedGroups.count == 1)
    }

    @Test func legacyFallbackRefusesWhenAmbiguous() throws {
        let (ctx, inv, co) = try makeScenario()
        co.addItemsToInvoice(using: ctx)
        // A second applied order makes the unlinked group ambiguous.
        let co2 = TS.changeOrder(inv, number: "CO-0002", status: .approved, lines: [(50, false)], in: ctx)
        co2.addItemsToInvoice(using: ctx)
        try ctx.save()

        // Strip both links to simulate two pre-link applies.
        for order in [co, co2] {
            order.invoiceGroup?.changeOrder = nil
            order.invoiceGroup = nil
            order.appliedToInvoice = true
        }
        try ctx.save()

        #expect(!co.removeItemsFromInvoice(using: ctx))  // can't tell whose group is whose
        #expect(co.appliedToInvoice)                     // nothing was touched
        #expect(inv.sortedGroups.count == 3)
    }

    @Test func appliedItemsBillAtTheRateTheOrderWasSignedAt() throws {
        // Signed and applied at 8%, invoice later moves to 10% — the invoice keeps billing the CO
        // items at the signed 8% (law 87: a signed document never changes; QA F82), and removal
        // still takes off exactly what the group billed.
        let (ctx, inv, co) = try makeScenario(taxRatePercent: 8,
                                              invoiceLines: [(1000, false)],
                                              coLines: [(200, true)])
        co.addItemsToInvoice(using: ctx)
        try ctx.save()
        #expect(close(inv.total, 1216))              // 1000 + 200 + 8% of 200

        inv.taxRatePercent = 10
        #expect(close(inv.total, 1216))              // the order's 8% still bills; it was 1220 before F82
        #expect(close(inv.total, 1000 + co.total))

        #expect(co.removeItemsFromInvoice(using: ctx))
        try ctx.save()
        #expect(close(inv.total, 1000))
    }
}
