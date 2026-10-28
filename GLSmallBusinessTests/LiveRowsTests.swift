//
//  LiveRowsTests.swift
//  GLSmallBusinessTests
//
//  The ONE fence against reading deleted models (Models/LiveRows.swift). Reading any
//  property of a deleted @Model traps uncatchably, and SwiftUI hands a covered screen one
//  more render over dead rows whenever a save or a synced pull deletes models the UI still
//  holds. `liveRows(_:)` sits at the model accessors so every screen, total, and export
//  inherits safety — which only holds while EVERY relationship read goes through it.
//
//  Four behaviors and one lint:
//   (a) an UNMANAGED graph keeps every child — the day-one regression, when the first
//       fence filtered `modelContext == nil` children of an uninserted fixture too;
//   (b) a pending delete (before the save) vanishes from the sorted rows and the totals;
//   (c) a committed delete (after the save) vanishes, and the dead reference reads
//       `modelContext == nil` — the branch the fence relies on for committed deletes;
//   (d) invoice money math ignores a deleted payment before AND after the save;
//   (e) a source scan: no raw `(relationship ?? [])` / `relationship?.` read outside the
//       fence and the sync layer. A missing call is exactly what unit-testing the fence can
//       never catch, so the scan is the honest instrument.
//
//  Reads on a committed-deleted row are limited to `modelContext` here, on purpose: the
//  fence short-circuits before `isDeleted`, and anything else on a dead row can trap.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct LiveRowsTests {

    // MARK: - (a) unmanaged graphs

    /// A fixture that was never inserted has children whose `modelContext` is nil and
    /// which are perfectly alive. The fence must pass them through untouched — the first
    /// version filtered them and every uninserted fixture's line items vanished.
    @Test func anUnmanagedGraphKeepsEveryChild() {
        let estimate = TS.estimate(lines: [(1000, false), (500, true)])   // never inserted

        // The shape that tripped the first fence: parent AND children without a context.
        #expect(estimate.modelContext == nil)
        #expect(estimate.sortedGroups.first?.modelContext == nil)

        #expect(estimate.sortedGroups.count == 1)
        #expect(estimate.allLineItems.count == 2)
        #expect(close(estimate.total, 1500))
    }

    // MARK: - (b) pending delete

    /// `context.delete` without a save: the row is still attached (`isDeleted` is the only
    /// tell), and every accessor and total on the parent must already exclude it.
    @Test func aPendingDeleteVanishesBeforeTheSave() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.twoGroupEstimate(number: "EST-LR-0002", in: context)
        try context.save()

        let kept = try #require(estimate.sortedGroups.first)
        let doomed = try #require(estimate.sortedGroups.last)
        #expect(estimate.sortedGroups.count == 2)
        #expect(close(estimate.total, 1250))

        context.delete(doomed)
        #expect(doomed.isDeleted, "the pre-save window is the isDeleted branch — nothing else was exercised")
        #expect(doomed.modelContext != nil, "a pending delete is still attached; only isDeleted marks it")

        #expect(estimate.sortedGroups.count == 1)
        #expect(estimate.sortedGroups.first === kept)
        #expect(estimate.allLineItems.count == 1)
        #expect(close(estimate.total, 1000))

        // The fence itself, fed the dead row explicitly — independent of whether SwiftData
        // has already pruned the relationship array.
        let filtered = estimate.liveRows([kept, doomed])
        #expect(filtered.count == 1)
        #expect(filtered.first === kept)
    }

    // MARK: - (c) committed delete

    /// After the save the dead row detaches (`modelContext == nil`) while the UI may still
    /// hold a reference to it — the exact shape of the 2026-09-01 estimate-save crash.
    @Test func aCommittedDeleteVanishesAfterTheSave() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let estimate = TS.twoGroupEstimate(number: "EST-LR-0003", in: context)
        try context.save()

        let kept = try #require(estimate.sortedGroups.first)
        let doomed = try #require(estimate.sortedGroups.last)
        context.delete(doomed)
        try context.save()

        #expect(doomed.modelContext == nil, "a committed delete must detach — the fence keys on this")

        #expect(estimate.sortedGroups.count == 1)
        #expect(estimate.sortedGroups.first === kept)
        #expect(estimate.allLineItems.count == 1)
        #expect(close(estimate.total, 1000))

        let filtered = estimate.liveRows([kept, doomed])
        #expect(filtered.count == 1)
        #expect(filtered.first === kept)
    }

    // MARK: - (d) invoice money math

    /// `amountPaid` / `balanceDue` (Invoice.swift) read `liveRows(payments)`. A deleted
    /// payment must drop out of both before the save and stay out after it.
    @Test func invoiceMathIgnoresDeadRows() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-LR-0004", lines: [(1000, false)], in: context)
        let first = TS.pay(invoice, 300, date: TS.day(2026, 8, 1), in: context)
        let second = TS.pay(invoice, 200, date: TS.day(2026, 8, 2), in: context)
        try context.save()

        #expect(invoice.sortedPayments.count == 2)
        #expect(close(invoice.amountPaid, 500))
        #expect(close(invoice.balanceDue, 500))

        context.delete(second)
        #expect(second.isDeleted)
        #expect(invoice.sortedPayments.count == 1)
        #expect(invoice.sortedPayments.first === first)
        #expect(close(invoice.amountPaid, 300))
        #expect(close(invoice.balanceDue, 700))
        #expect(invoice.isPartiallyPaid)
        #expect(!invoice.isPaid)

        try context.save()
        #expect(second.modelContext == nil)
        #expect(invoice.sortedPayments.count == 1)
        #expect(invoice.sortedPayments.first === first)
        #expect(close(invoice.amountPaid, 300))
        #expect(close(invoice.balanceDue, 700))
        #expect(close(invoice.paidThrough(first), 300))
        #expect(close(invoice.remainingAfter(first), 700))
    }

    // MARK: - (e) the lint

    /// The to-many relationship names across every @Model, and the reads that turn one
    /// into UI or math. A raw read of any of these outside the fence needs a written
    /// reason on the same line: `// LIVEROWS-OK: <why dead rows are wanted here>`.
    private static let relationships =
        "paychecks|timeEntries|payments|invoices|estimates|groups|lineItems|changeOrders|"
        + "billingInvoices|attachments|receipts|jobs|packageDocuments|scheduledJobs|"
        + "customers|subcontractors|employees"
    private static let readers =
        "filter|reduce|map|contains|sorted|first|compactMap|flatMap|allSatisfy|count|isEmpty"

    /// `invoice.payments ?? []` anywhere — read inline, iterated, or bound to a local — is the
    /// coalesced form; every one of them keeps dead rows.
    private static let rawCoalescedRead = try! NSRegularExpression(
        pattern: #"(?:^|[^.\w])(?:\w+\.)?("# + relationships + #")\s*\?\?\s*\[\]"#)
    /// `invoice.payments?.reduce…` — the optional-chained form.
    private static let optionalChainedRead = try! NSRegularExpression(
        pattern: #"\.("# + relationships + #")\?\.("# + readers + #")"#)

    private static let waiver = "LIVEROWS-OK:"

    /// Every offending line as `path:line: text`, scanning line by line so the waiver has
    /// to sit on the SAME line as the read it excuses.
    private static func offenders(in files: [(path: String, text: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                guard !line.contains(waiver) else { continue }
                let whole = NSRange(line.startIndex..., in: line)
                let hit = rawCoalescedRead.firstMatch(in: line, range: whole) != nil
                    || optionalChainedRead.firstMatch(in: line, range: whole) != nil
                if hit {
                    out.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return out
    }

    /// The scanner has to catch the thing it exists to catch, and honor the waiver, before a
    /// clean scan of the app means anything. A broken pattern would otherwise pass forever.
    @Test func theLintCatchesBothRawFormsAndHonorsTheWaiver() {
        let coalesced = "        let paid = (invoice.payments ?? []).reduce(0) { $0 + $1.amount }"
        let coalescedBare = "        (paychecks ?? []).filter { $0.payDate > cutoff }"
        let chained = "        if job.billingInvoices?.contains(where: { $0.isPaid }) == true {"
        let waived = "        let all = (invoice.payments ?? []).map(\\.syncID)   // LIVEROWS-OK: tombstones need dead rows"
        let fenced = "        liveRows(payments).reduce(0) { $0 + $1.amount }"
        let unrelated = "        let names = (people ?? []).map(\\.name)"
        let iterated = "        for group in estimate.groups ?? [] {"
        let bound = "        let payments = invoice.payments ?? []"

        let probe = [coalesced, coalescedBare, chained, waived, fenced, unrelated, iterated, bound]
            .joined(separator: "\n")
        let caught = Self.offenders(in: [(path: "Probe.swift", text: probe)])
        #expect(caught.count == 5, "expected exactly the five raw reads, got:\n\(caught.joined(separator: "\n"))")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:7:") }, "the iterated form was missed")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:8:") }, "the bound-to-a-local form was missed")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:1:") }, "the coalesced form was missed")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:2:") }, "the bare coalesced form was missed")
        #expect(caught.contains { $0.hasPrefix("Probe.swift:3:") }, "the optional-chained form was missed")
        #expect(!caught.contains { $0.hasPrefix("Probe.swift:4:") }, "the LIVEROWS-OK waiver was not honored")
    }

    /// Every relationship read that feeds UI or math goes through `liveRows(_:)`. The sync
    /// layer is excluded on purpose — tombstones and delete routing WANT dead rows — and so is
    /// the fence's own file. The failure message lists each offender so the fix is one
    /// click away: route it through `liveRows`, or waive it with a written reason.
    @Test func everyRelationshipReadGoesThroughLiveRows() {
        let files = GLSource.files(under: GLSource.appRoot, excluding: ["Sync/", "Models/LiveRows.swift"])
        #expect(files.count > 50, "the app sources were not readable — \(files.count) file(s); a scan of nothing proves nothing")
        #expect(!files.contains { $0.path.hasPrefix("Sync/") || $0.path == "Models/LiveRows.swift" })

        let found = Self.offenders(in: files)
        #expect(found.isEmpty, """
            \(found.count) raw relationship read(s) outside liveRows(_:). Route each through \
            `owner.liveRows(owner.relationship)` or add `// LIVEROWS-OK: <reason>` on the same line:
            \(found.joined(separator: "\n"))
            """)
    }
}

// MARK: - Fixtures (shared with DetailScreenSurvivesRebuildTests)

extension TS {
    /// `TS.estimate` plus a second group ("Extras", one $250 line, sortIndex 1), wired both
    /// ways like every other builder: total 1250, and deleting the second group leaves 1000.
    static func twoGroupEstimate(number: String = "EST-LR-0001",
                                 in context: ModelContext? = nil) -> Estimate {
        let estimate = TS.estimate(number: number, lines: [(1000, false)], in: context)
        let extras = EstimateGroup(name: "Extras", sortIndex: 1)
        context?.insert(extras)
        let line = EstimateLineItem(name: "Line 0", quantity: 1, unit: .job,
                                    unitPrice: 250, isTaxable: false, sortIndex: 0)
        line.group = extras
        extras.lineItems = [line]
        extras.estimate = estimate
        context?.insert(line)
        estimate.groups = (estimate.groups ?? []) + [extras]
        return estimate
    }

    /// `TS.invoice` plus a second group ("Extras", one $250 line, sortIndex 1): total 1250.
    static func twoGroupInvoice(number: String = "INV-LR-0001",
                                in context: ModelContext? = nil) -> Invoice {
        let invoice = TS.invoice(number: number, lines: [(1000, false)], in: context)
        let extras = InvoiceGroup(name: "Extras", sortIndex: 1)
        context?.insert(extras)
        let line = InvoiceLineItem(name: "Line 0", quantity: 1, unit: .job,
                                   unitPrice: 250, isTaxable: false, sortIndex: 0)
        line.group = extras
        extras.lineItems = [line]
        extras.invoice = invoice
        context?.insert(line)
        invoice.groups = (invoice.groups ?? []) + [extras]
        return invoice
    }
}
