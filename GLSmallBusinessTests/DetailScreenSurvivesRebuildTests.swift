//
//  DetailScreenSurvivesRebuildTests.swift
//  GLSmallBusinessTests
//
//  The exact 2026-09-01 gesture that crashed the app on a real phone: an estimate is OPEN
//  on its detail screen, every group under it is deleted and replaced, and SwiftUI hands the
//  still-live detail screen one more render over the graph — where reading any property of a
//  now-deleted group trapped uncatchably. `liveRows(_:)` (Models/LiveRows.swift) is the fence;
//  this is the fence under the real gesture, not in isolation.
//
//  The forms no longer save this way — RowReconciler updates rows in place — but the gesture
//  still arrives from sync: a pull that deletes and re-creates rows under an open screen does
//  exactly this. The fence has to hold whoever performs it, so the test performs it directly
//  rather than through a form.
//
//  What a pass proves: the live screen re-rendered across the wholesale replacement
//  without a trap, and a fresh render afterwards saw the rebuilt graph. What it cannot
//  prove is what the screen SAYS (see GLTestHost.swift, note 2) — the totals it would
//  print are asserted on the models that drive it instead.
//
//  `.serialized` is load-bearing: hosted @Query views and RunLoop pumping must not
//  interleave across tests (project_swiftdata_test_process_trap).
//

import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct DetailScreenSurvivesRebuildTests {

    /// Estimate detail stays alive while every group under it is deleted and one rebuilt
    /// group is inserted and saved — the wife's-crash gesture.
    @Test func estimateDetailSurvivesEveryGroupBeingRebuiltUnderIt() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.twoGroupEstimate(number: "EST-DR-0001", in: context)
        try context.save()

        let oldGroups = estimate.sortedGroups
        #expect(oldGroups.count == 2)
        #expect(close(estimate.total, 1250))

        var rebuilt: EstimateGroup?
        var saveError: Error?
        GLTestHost.renderAcross(EstimateDetailScreen(estimate: estimate), container: container) {
            for group in oldGroups { context.delete(group) }
            estimate.groups = []
            let group = EstimateGroup(name: "Rebuilt", sortIndex: 0)
            context.insert(group)
            let line = EstimateLineItem(name: "Line 0", quantity: 1, unit: .job,
                                        unitPrice: 725, isTaxable: false, sortIndex: 0)
            line.group = group
            context.insert(line)
            group.lineItems = [line]
            group.estimate = estimate
            estimate.groups = [group]
            rebuilt = group
            do { try context.save() } catch { saveError = error }
        }
        // Reaching here at all is the headline: the live screen re-rendered over the
        // rebuilt graph without trapping.
        #expect(saveError == nil, "the rebuild save failed: \(String(describing: saveError))")

        // The graph the screen's cards now read.
        #expect(estimate.sortedGroups.count == 1)
        #expect(estimate.sortedGroups.first === rebuilt)
        #expect(estimate.allLineItems.count == 1)
        #expect(close(estimate.total, 725))
        #expect(oldGroups.allSatisfy { $0.modelContext == nil }, "the deleted groups did not detach")

        // A second, fresh render over the rebuilt graph — the state the person sees after
        // the form dismisses. `onAppear` proves the body actually ran; the count it saw
        // proves it ran over the NEW graph.
        var renderedGroupCount: Int?
        GLTestHost.render(
            EstimateDetailScreen(estimate: estimate)
                .onAppear { renderedGroupCount = estimate.sortedGroups.count },
            container: container)
        #expect(renderedGroupCount == 1, "the post-rebuild render never happened or saw the wrong graph")
    }

    /// Same gesture on the invoice side — the form rebuilds groups the same way, and the
    /// invoice screen adds payments and change-order cards on top.
    @Test func invoiceDetailSurvivesEveryGroupBeingRebuiltUnderIt() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let invoice = TS.twoGroupInvoice(number: "INV-DR-0001", in: context)
        try context.save()

        let oldGroups = invoice.sortedGroups
        #expect(oldGroups.count == 2)
        #expect(close(invoice.total, 1250))

        var rebuilt: InvoiceGroup?
        var saveError: Error?
        GLTestHost.renderAcross(InvoiceDetailScreen(invoice: invoice), container: container) {
            for group in oldGroups { context.delete(group) }
            invoice.groups = []
            let group = InvoiceGroup(name: "Rebuilt", sortIndex: 0)
            context.insert(group)
            let line = InvoiceLineItem(name: "Line 0", quantity: 1, unit: .job,
                                       unitPrice: 725, isTaxable: false, sortIndex: 0)
            line.group = group
            context.insert(line)
            group.lineItems = [line]
            group.invoice = invoice
            invoice.groups = [group]
            rebuilt = group
            do { try context.save() } catch { saveError = error }
        }
        #expect(saveError == nil, "the rebuild save failed: \(String(describing: saveError))")

        #expect(invoice.sortedGroups.count == 1)
        #expect(invoice.sortedGroups.first === rebuilt)
        #expect(invoice.allLineItems.count == 1)
        #expect(close(invoice.total, 725))
        #expect(close(invoice.balanceDue, 725))
        #expect(oldGroups.allSatisfy { $0.modelContext == nil }, "the deleted groups did not detach")

        var renderedGroupCount: Int?
        GLTestHost.render(
            InvoiceDetailScreen(invoice: invoice)
                .onAppear { renderedGroupCount = invoice.sortedGroups.count },
            container: container)
        #expect(renderedGroupCount == 1, "the post-rebuild render never happened or saw the wrong graph")
    }
}
