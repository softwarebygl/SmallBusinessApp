//
//  FetchAndDecodeScopeTests.swift
//  GLSmallBusinessTests
//
//  2026-10-03 QA, cluster C64 (F92, F153, F154): work a screen redoes on every draw.
//
//  - F92: All Invoices worked out "Owed to you" over EVERY invoice twice per draw, and a
//    keystroke in its search box is a draw. The total is now worked out once per data change.
//  - F153: detail screens and forms fetched a whole table (every invoice, every line item)
//    only to ask "is my record still there?" or to build type-ahead once. Existence is now a
//    fetch of the one record; type-ahead names are fetched once when the form opens.
//  - F154: the business logo was decoded from its bytes on every draw of the shared
//    background and the Menu's logo slots. It is now decoded once per logo.
//
//  The scans read code only (comments stripped, GLSource). The hosted suite is `.serialized`
//  (GLTestHost header: hosted @Query views must not interleave).
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

// MARK: - Call-site scans

struct FetchAndDecodeScopeScanTests {

    /// The screens this cluster owns.
    nonisolated static let screens = [
        "Screens/AllInvoicesScreen.swift",
        "Screens/EstimateDetailScreen.swift",
        "Screens/InvoiceDetailScreen.swift",
        "Screens/JobDetailScreen.swift",
        "Screens/ChangeOrderScreens.swift",
        "Screens/CustomerDetailScreen.swift",
        "Screens/InvoiceFormScreen.swift",
        "Screens/EstimateFormScreen.swift",
        "Screens/MenuScreen.swift",
        "UIComponents/PersonRowCard.swift",
        "UIComponents/PrimaryBackground.swift",
    ]

    static func code(_ path: String) -> String {
        GLSource.code(path) ?? ""
    }

    /// Every `@Query` property name declared in `code` whose name is never read again.
    static func unusedQueries(in code: String) -> [String] {
        guard let declaration = try? NSRegularExpression(pattern: #"@Query[^\n]*?\bvar\s+(\w+)"#) else { return ["<regex>"] }
        let range = NSRange(code.startIndex..., in: code)
        return declaration.matches(in: code, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: code) else { return nil }
            let name = String(code[nameRange])
            let uses = (try? NSRegularExpression(pattern: "\\b\(name)\\b"))?
                .numberOfMatches(in: code, range: range) ?? 0
            return uses < 2 ? name : nil
        }
    }

    /// Lines that ask "is it still there?" by scanning a fetched list for the record's id —
    /// the whole-table existence check.
    static func wholeTableExistenceChecks(in code: String) -> [Int] {
        let pattern = #"\.contains\s*(\(\s*where:\s*)?\{\s*\$0\.persistentModelID\s*=="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [-1] }
        return regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            Range(match.range, in: code).map { GLSource.line(of: $0.lowerBound, in: code) }
        }
    }

    @Test func theScannedFilesExist() {
        for path in Self.screens {
            #expect(!Self.code(path).isEmpty, "\(path) was not read")
        }
    }

    /// F153: a declared @Query nobody reads still fetches and observes its whole table
    /// (EstimateDetailScreen's `allInvoices`).
    @Test func noScreenDeclaresAQueryItNeverReads() {
        for path in Self.screens {
            let unused = Self.unusedQueries(in: Self.code(path))
            #expect(unused.isEmpty, "\(path) declares @Query it never reads: \(unused)")
        }
        // The scanner itself: it finds an unread query and passes a read one.
        #expect(Self.unusedQueries(in: "@Query private var allInvoices: [Invoice]\nvar x = 1") == ["allInvoices"])
        #expect(Self.unusedQueries(in: "@Query private var rows: [Invoice]\nlet n = rows.count").isEmpty)
    }

    /// F153: "is my record still there?" is a fetch of that one record, never a whole table
    /// scanned for its id.
    @Test func existenceChecksFetchOneRecordNotAWholeTable() {
        for path in Self.screens {
            let lines = Self.wholeTableExistenceChecks(in: Self.code(path))
            #expect(lines.isEmpty, "\(path) scans a whole table for one record at lines \(lines)")
        }
        #expect(Self.wholeTableExistenceChecks(in: "all.contains { $0.persistentModelID == x.persistentModelID }") == [1])
        #expect(Self.wholeTableExistenceChecks(in: "all.contains(where: { $0.persistentModelID == id })") == [1])
    }

    /// F153: the forms' type-ahead names are fetched once when the form opens, not held as a
    /// live @Query over every group and line item ever written.
    @Test func formsDoNotQueryEveryGroupAndLineItem() {
        for path in ["Screens/InvoiceFormScreen.swift", "Screens/EstimateFormScreen.swift"] {
            let queried = Self.code(path).components(separatedBy: "\n").filter { line in
                line.contains("@Query") && ["InvoiceGroup]", "InvoiceLineItem]", "EstimateGroup]", "EstimateLineItem]"]
                    .contains { line.contains($0) }
            }
            #expect(queried.isEmpty, "\(path) still queries every group/line item: \(queried)")
        }
    }

    /// F154: no logo or avatar is decoded with `UIImage(data:)` while a screen draws. The one
    /// allowed decode is the logo cache's own (`LogoImage.decodeUncached`), which runs once
    /// per logo.
    @Test func noImageIsDecodedWhileAScreenDraws() {
        for path in ["UIComponents/PrimaryBackground.swift", "Screens/MenuScreen.swift", "UIComponents/PersonRowCard.swift"] {
            var code = Self.code(path)
            if let cacheBody = GLSource.functionBody("decodeUncached", in: code) {
                code = code.replacingOccurrences(of: cacheBody, with: "")
            }
            let decodes = code.components(separatedBy: "\n").enumerated()
                .filter { $0.element.contains("UIImage(data:") }.map { $0.offset + 1 }
            #expect(decodes.isEmpty, "\(path) decodes an image while drawing at lines \(decodes)")
        }
    }

    /// F92: All Invoices never sums every invoice's balance in its own body — the sum lives in
    /// a view that redraws only when the invoices change.
    @Test func allInvoicesDoesNotSumBalancesInItsBody() {
        let code = Self.code("Screens/AllInvoicesScreen.swift")
        guard let screen = code.range(of: "struct AllInvoicesScreen: View"),
              let body = GLSource.balanced("{", "}", from: screen.lowerBound, in: code) else {
            Issue.record("AllInvoicesScreen not found"); return
        }
        #expect(!body.inner.contains("balanceDue)"), "the screen itself still sums every balance")
        #expect(!body.inner.contains("totalOwed"), "the screen itself still reads a per-draw total")
    }
}

// MARK: - Hosted behavior

@MainActor
@Suite(.serialized)
struct FetchAndDecodeScopeHostedTests {

    // MARK: F92 — the owed total, once per data change

    /// Three unpaid invoices: $1,000 + $1,000 + $1,000, $250 paid on the first.
    private func owedWorld() throws -> (ModelContainer, [Invoice]) {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let invoices = (0..<3).map { i -> Invoice in
            let invoice = TS.invoice(number: "INV-OW-\(i)", status: .sent, in: context)
            invoice.customer = customer
            return invoice
        }
        TS.pay(invoices[0], 250, in: context)
        try context.save()
        return (container, invoices)
    }

    private func textFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        if let field = view as? UITextField { found.append(field) }
        for sub in view.subviews { found.append(contentsOf: textFields(in: sub)) }
        return found
    }

    private func type(_ text: String, into field: UITextField, in controller: UIViewController) {
        field.text = text
        field.sendActions(for: .editingChanged)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    /// Typing in All Invoices' search box redraws the list, never the all-time owed total;
    /// a payment landing on an invoice works it out again.
    @Test func typingInSearchNeverRecomputesTheOwedTotal() throws {
        let (container, invoices) = try owedWorld()
        var typedDelta = -1
        var paidDelta = -1
        var sawField = false
        GLTestHost.render(AllInvoicesScreen(), container: container) { controller in
            guard let field = textFields(in: controller.view).first else { return }
            sawField = true
            let before = OwedToYouCard.computations
            type("I", into: field, in: controller)
            type("IN", into: field, in: controller)
            type("INV", into: field, in: controller)
            typedDelta = OwedToYouCard.computations - before

            let beforePay = OwedToYouCard.computations
            TS.pay(invoices[1], 100, in: container.mainContext)
            try? container.mainContext.save()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            paidDelta = OwedToYouCard.computations - beforePay
        }
        #expect(sawField, "All Invoices drew no search field")
        #expect(typedDelta == 0, "three keystrokes recomputed the all-time owed total \(typedDelta) times")
        #expect(paidDelta >= 1, "a new payment did not recompute the owed total")
    }

    /// The card still says what is owed ($3,000 billed − $250 paid), and drops out once every
    /// invoice is paid in full (a permanent $0.00 is just furniture).
    @Test func allInvoicesStillShowsWhatIsOwedAndHidesAZero() throws {
        let (container, invoices) = try owedWorld()
        let owed = try DrawnText.screen(AllInvoicesScreen(), container: container)
        #expect(owed.contains("Owed to you"), "drew: \(owed)")
        #expect(owed.contains("$2,750.00"), "drew: \(owed)")

        TS.pay(invoices[0], 750, in: container.mainContext)
        TS.pay(invoices[1], 1000, in: container.mainContext)
        TS.pay(invoices[2], 1000, in: container.mainContext)
        try container.mainContext.save()
        let settled = try DrawnText.screen(AllInvoicesScreen(), container: container)
        #expect(!settled.contains("Owed to you"), "drew: \(settled)")
        #expect(settled.contains("INV-OW-1"), "the list itself still draws: \(settled)")
    }

    // MARK: F153 — existence by a one-record fetch, same answers as before

    /// The record a screen holds, inserted and SAVED (temporary id swapped for the store's),
    /// is found by the one-record fetch; deleted and saved, it is not.
    @Test func aOneRecordFetchFindsTheRecordAcrossSaveAndLosesItOnDelete() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-ONE-1", in: context)
        let unsavedID = invoice.persistentModelID
        let pending = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.persistentModelID == unsavedID }))
        #expect(pending.count == 1, "an inserted, unsaved record was not found by its own id")
        try context.save()
        let savedID = invoice.persistentModelID
        let saved = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.persistentModelID == savedID }))
        #expect(saved.count == 1)
        context.delete(invoice)
        try context.save()
        let gone = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.persistentModelID == savedID }))
        #expect(gone.isEmpty)
    }

    private func expectAlive(_ drawn: String, _ marker: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!drawn.contains("was removed"), "a live record drew as removed: \(drawn)", sourceLocation: sourceLocation)
        #expect(drawn.contains(marker), "the screen did not draw its record (\(marker)): \(drawn)", sourceLocation: sourceLocation)
    }

    private func expectRemoved(_ drawn: String, _ noun: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(drawn.contains("This \(noun) was removed") || drawn.contains("The \(noun) was removed"),
                "the screen kept drawing over the deleted \(noun): \(drawn)", sourceLocation: sourceLocation)
    }

    /// Opened on an invoice created but not yet saved, the detail screen keeps showing it after
    /// the save swaps its id (the one-record fetch follows the record, not a stale id).
    @Test func invoiceDetailSurvivesTheFirstSaveOfItsInvoice() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-FS-0001", in: context)
        invoice.jobTitle = "Porch Rebuild"
        let drawn = try DrawnText.screen(InvoiceDetailScreen(invoice: invoice), container: container, after: {
            try context.save()
        })
        expectAlive(drawn, "Porch Rebuild")
    }

    @Test func invoiceDetailIsLiveThenRemoved() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-LR-0001", in: context)
        invoice.jobTitle = "Porch Rebuild"
        try context.save()
        expectAlive(try DrawnText.screen(InvoiceDetailScreen(invoice: invoice), container: container), "Porch Rebuild")
        expectRemoved(try DrawnText.screen(InvoiceDetailScreen(invoice: invoice), container: container, after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.invoice(invoice)], in: context) }
        }), "invoice")
    }

    @Test func estimateDetailIsLiveThenRemoved() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let estimate = TS.estimate(number: "EST-LR-0001", in: context)
        estimate.jobTitle = "Porch Rebuild"
        try context.save()
        expectAlive(try DrawnText.screen(EstimateDetailScreen(estimate: estimate), container: container), "Porch Rebuild")
        expectRemoved(try DrawnText.screen(EstimateDetailScreen(estimate: estimate), container: container, after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.estimate(estimate)], in: context) }
        }), "estimate")
    }

    @Test func jobDetailIsLiveThenRemoved() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let job = TS.job("Porch Rebuild", start: .now.addingTimeInterval(86_400), in: context)
        try context.save()
        expectAlive(try DrawnText.screen(JobDetailScreen(job: job), container: container), "Porch Rebuild")
        expectRemoved(try DrawnText.screen(JobDetailScreen(job: job), container: container, after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.job(job)], in: context) }
        }), "job")
    }

    @Test func changeOrderDetailIsLiveThenRemoved() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-CO-0001", in: context)
        let order = TS.changeOrder(invoice, number: "CO-LR-0001", in: context)
        order.title = "Porch Rebuild"
        try context.save()
        expectAlive(try DrawnText.screen(ChangeOrderDetailSheet(changeOrder: order), container: container), "Porch Rebuild")
        expectRemoved(try DrawnText.screen(ChangeOrderDetailSheet(changeOrder: order), container: container, after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.changeOrder(order)], in: context) }
        }), "change order")
    }
}

// MARK: - F154: the logo is decoded once per logo

@MainActor
struct LogoImageCacheTests {

    /// A small PNG of one solid color.
    private func png(_ color: UIColor, side: CGFloat = 8) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    @Test func theSameLogoIsDecodedOnceAndHandedBackEveryDraw() throws {
        let bytes = png(.red)
        let first = try #require(LogoImage.decoded(bytes))
        // A fresh copy of the same bytes (what a re-read of the stored logo hands back).
        let copy = Data(Array(bytes))
        let again = try #require(LogoImage.decoded(copy))
        #expect(first === again, "the same logo was decoded a second time")
        #expect(first.size == CGSize(width: 8, height: 8))
    }

    @Test func aChangedLogoIsDecodedFreshNeverTheOldPicture() throws {
        let red = try #require(LogoImage.decoded(png(.red, side: 12)))
        let blue = try #require(LogoImage.decoded(png(.blue, side: 12)))
        #expect(red !== blue)
        let resized = try #require(LogoImage.decoded(png(.red, side: 16)))
        #expect(resized.size == CGSize(width: 16, height: 16))
    }

    @Test func bytesThatAreNotAnImageDrawNothing() {
        #expect(LogoImage.decoded(Data("not an image".utf8)) == nil)
        #expect(LogoImage.decoded(Data()) == nil)
    }
}

// MARK: - F153: the forms' shared one-record and names fetches

@MainActor
@Suite(.serialized)
struct FormFetchHelperTests {

    @Test func stillStoresFollowsTheRecordThroughSaveAndDelete() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let estimate = TS.estimate(number: "EST-SS-0001", in: context)
        #expect(context.stillStores(estimate), "an inserted, unsaved record counts as stored")
        try context.save()
        #expect(context.stillStores(estimate))
        let other = TS.estimate(number: "EST-SS-0002", in: context)
        try context.save()
        context.delete(estimate)
        #expect(!context.stillStores(estimate), "a delete not yet saved counts as gone")
        try context.save()
        #expect(!context.stillStores(estimate), "a saved delete counts as gone")
        #expect(context.stillStores(other), "only the deleted record is gone")
        // Never inserted (a calendar occurrence copy): not stored.
        #expect(!context.stillStores(Estimate(number: "EST-SS-0003", jobTitle: "Copy", createdAt: .now, status: .draft)))
    }

    /// The Change Order form's "no order being edited" query (a new order) is a fetch SwiftData
    /// runs and answers with nothing, never an error.
    @Test func theNewOrderFormsEmptyQueryFetchesNothing() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let invoice = TS.invoice(number: "INV-EQ-0001", in: context)
        _ = TS.changeOrder(invoice, number: "CO-EQ-0001", in: context)
        try context.save()
        let none = try context.fetch(FetchDescriptor<ChangeOrder>(predicate: #Predicate<ChangeOrder> { _ in false }))
        #expect(none.isEmpty)
        GLTestHost.render(ChangeOrderFormScreen(invoice: invoice), container: container)
    }

    @Test func storedNamesReadsEveryNameOfOneTypeOnce() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        _ = TS.estimate(number: "EST-NM-0001", lines: [(10, false), (20, false)], in: context)
        _ = TS.invoice(number: "INV-NM-0001", lines: [(10, false)], in: context)
        try context.save()
        #expect(LineItemNameSuggestions.storedNames(\EstimateLineItem.name, in: context).sorted() == ["Line 0", "Line 1"])
        #expect(LineItemNameSuggestions.storedNames(\EstimateGroup.name, in: context) == ["Work"])
        #expect(LineItemNameSuggestions.storedNames(\InvoiceLineItem.name, in: context) == ["Line 0"])
        let counts = LineItemNameSuggestions.counts(
            LineItemNameSuggestions.storedNames(\InvoiceGroup.name, in: context)
                + LineItemNameSuggestions.storedNames(\EstimateGroup.name, in: context))
        #expect(counts == ["Work": 2])
    }
}
