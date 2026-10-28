//
//  InvoiceCreditDueTests.swift
//  GLSmallBusinessTests
//
//  QA 2026-10-03 F85: an invoice cut below what was already paid (a credit change order, or an
//  edit) read Paid with a $0.00 balance, locked, and the money owed back to the customer showed
//  nowhere. Now every surface that prints Paid and Balance also prints "Credit due" whenever the
//  payments are more than the total, so Paid − Credit due == Total (law 60), and every screen
//  save that would settle (and so lock) an invoice with payments on it asks first.
//
//  Also the QA F82 demo check: how many demo invoices change total now that change-order lines
//  bill at their own order's signed rate (expected 0 — every demo order was signed at its
//  invoice's rate).
//
//  Serialized: it hosts the invoice detail screen (GLTestHost.render).
//

import Foundation
import PDFKit
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct InvoiceCreditDueTests {

    /// $1,000 of work, sent, $800 paid, then an approved −$300 credit order added: total $700,
    /// paid $800 → $100 owed back to the customer.
    private func overpaid(in context: ModelContext) -> Invoice {
        let invoice = TS.invoice(number: "INV-CREDIT", status: .sent, lines: [(1000, false)], in: context)
        invoice.customerFirstName = "Dana"
        TS.pay(invoice, 800, in: context)
        let credit = TS.changeOrder(invoice, status: .approved, lines: [(-300, false)], in: context)
        context.saveChanges()
        credit.addItemsToInvoice(using: context)
        context.saveChanges()
        return invoice
    }

    // MARK: - The figure

    @Test func paidLessCreditDueIsTheTotal() throws {
        let context = try DomainFixtures.context()
        let invoice = overpaid(in: context)
        #expect(invoice.total == 700 && invoice.amountPaid == 800)
        #expect(invoice.balanceDue == 0 && invoice.isPaid, "it reads Paid, balance $0.00")
        #expect(invoice.creditDue == 100)
        #expect(invoice.amountPaid - invoice.creditDue == invoice.total, "law 60")
    }

    @Test func creditDueIsZeroUnlessPaymentsExceedTheTotal() {
        #expect(GLInvoiceMath.creditDue(total: 700, paid: 800) == 100)
        #expect(GLInvoiceMath.creditDue(total: 700, paid: 700) == 0)
        #expect(GLInvoiceMath.creditDue(total: 700, paid: 0) == 0)
        #expect(GLInvoiceMath.creditDue(total: 0.1, paid: 0.3) == 0.2, "whole cents, exact")
    }

    // MARK: - The screens' lock question

    @Test func theScreensAskOnlyWhenMoneyWasPaid() {
        #expect(PaidLockSaveGuard.fires(true, amountPaid: 800), "a save that settles a paid-into invoice")
        #expect(!PaidLockSaveGuard.fires(true, amountPaid: 0), "a $0 comp with nothing paid saves without a word")
        #expect(!PaidLockSaveGuard.fires(false, amountPaid: 800), "money still owed: nothing locks")
    }

    @Test func aCreditThatCoversTheBalanceIsAskedAbout() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        TS.pay(invoice, 800, in: context)
        let small = TS.changeOrder(invoice, status: .approved, lines: [(-100, false)], in: context)
        let big = TS.changeOrder(invoice, number: "CO-0002", status: .approved, lines: [(-300, false)], in: context)
        context.saveChanges()
        #expect(!PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: small), amountPaid: invoice.amountPaid),
                "$900 left against $800 paid: still owed")
        #expect(PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: big), amountPaid: invoice.amountPaid),
                "$700 against $800 paid: settles, locks, $100 credit due")
    }

    @Test func anInvoiceEditBelowWhatWasPaidIsAskedAbout() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        TS.pay(invoice, 800, in: context)
        context.saveChanges()
        var draft = InvoiceDraft(invoice)
        draft.groups[0].lines[0].unitPrice = 600
        #expect(PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(invoice, applying: draft), amountPaid: invoice.amountPaid))
        draft.groups[0].lines[0].unitPrice = 900
        #expect(!PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(invoice, applying: draft), amountPaid: invoice.amountPaid))
    }

    // MARK: - The tax line's percent (QA F82)

    @Test func theTaxPercentIsShownOnlyWhenEveryLineBillsAtIt() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 6, lines: [(1000, true)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, taxRatePercent: 6, lines: [(100, true)], in: context)
        context.saveChanges()
        order.addItemsToInvoice(using: context)
        context.saveChanges()
        #expect(invoice.shownTaxRatePercent == 6)
        invoice.taxRatePercent = 7
        #expect(invoice.shownTaxRatePercent == nil, "the order still bills at its signed 6%")
        #expect(invoice.total == 1070 + 106)
    }

    // MARK: - The message (text and email)

    @Test func theTextMessageSaysTheCreditDue() throws {
        let context = try DomainFixtures.context()
        let invoice = overpaid(in: context)
        let body = InvoiceMessage.plainBody(invoice: invoice, business: nil)
        #expect(body.contains("Total: $700.00") && body.contains("Paid: $800.00"))
        #expect(body.contains("Credit due: $100.00"), "read: \(body)")
    }

    @Test func theEmailSaysTheCreditDue() throws {
        let context = try DomainFixtures.context()
        let invoice = overpaid(in: context)
        let html = InvoiceMessage.htmlBody(invoice: invoice, business: nil)
        #expect(html.contains("Credit due") && html.contains("$100.00"))
    }

    @Test func aBalanceStillOwedPrintsNoCredit() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)], in: context)
        TS.pay(invoice, 400, in: context)
        context.saveChanges()
        #expect(!InvoiceMessage.plainBody(invoice: invoice, business: nil).contains("Credit due"))
        #expect(!InvoiceMessage.htmlBody(invoice: invoice, business: nil).contains("Credit due"))
    }

    // MARK: - The PDF and the detail screen (what is actually drawn)

    @Test func thePDFPrintsTheCreditDue() throws {
        let context = try DomainFixtures.context()
        let invoice = overpaid(in: context)
        let url = try #require(InvoicePDF.render(invoice, business: nil))
        let document = try #require(PDFDocument(url: url))
        var text: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
            text.append(try DrawnText.read(try #require(image.cgImage)))
        }
        let read = text.joined(separator: "\n")
        #expect(read.contains("Credit due"), "read: \(read)")
        #expect(read.contains("$100.00"), "read: \(read)")
    }

    @Test func theDetailScreenShowsTheCreditDue() throws {
        let container = try TestStore.makeContainer()
        let invoice = overpaid(in: container.mainContext)
        // Tall enough to hold the totals card without scrolling; settled before it is read.
        let read = try DrawnText.screen(InvoiceDetailScreen(invoice: invoice), container: container,
                                        size: CGSize(width: 430, height: 2400),
                                        after: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 2)) })
        #expect(read.contains("Paid") && read.contains("$700.00"), "the totals card was drawn; read: \(read)")
        #expect(read.contains("Credit due"), "read: \(read)")
        #expect(read.contains("$100.00"), "read: \(read)")
    }

    // MARK: - Every screen save that could settle an invoice asks first

    /// A call-site fact (SourceScan.swift): the lock preview only helped the assistant before,
    /// so the forms and both "Add to invoice" buttons could settle and lock an invoice with
    /// payments on it without a word.
    @Test func everyMoneySaveOnTheScreensAsksTheLockPreview() throws {
        let invoiceForm = try #require(GLSource.file("Screens/InvoiceFormScreen.swift"))
        let changeOrders = try #require(GLSource.file("Screens/ChangeOrderScreens.swift"))
        let invoiceDetail = try #require(GLSource.file("Screens/InvoiceDetailScreen.swift"))
        #expect(invoiceForm.contains("PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(editingInvoice, applying:"),
                "the invoice form")
        #expect(changeOrders.contains("PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(editing, applying:"),
                "the change-order form")
        #expect(changeOrders.contains("PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: changeOrder)"),
                "the change order's Add to invoice")
        #expect(invoiceDetail.contains("PaidLockSaveGuard.fires(MoneyLockPreview.wouldLock(applying: changeOrder)"),
                "the invoice's Add to invoice")
    }

    // MARK: - QA F82: the demo data under the signed rates

    @Test func noDemoInvoiceChangesTotalUnderTheSignedRates() throws {
        let world = try TestStore.demoWorld()
        var moved: [String] = []
        for invoice in world.invoices {
            let items = invoice.allLineItems
            let original: [(lineTotal: Decimal, isTaxable: Bool)] =
                items.filter { !$0.fromChangeOrder }.map { ($0.exactLineTotal, $0.isTaxable) }
            // What the invoice billed before F82: every change-order line at the invoice's rate.
            let atInvoiceRate: [(signedLineTotal: Decimal, isTaxable: Bool)] =
                items.filter(\.fromChangeOrder).map { ($0.exactSignedLineTotal, $0.isTaxable) }
            let before = GLInvoiceMath.totals(original: original, changeOrder: atInvoiceRate,
                                              taxRatePercent: invoice.taxRatePercent,
                                              discountType: invoice.discountType,
                                              discountValue: invoice.discountValue)
            if before.total != invoice.total { moved.append("\(invoice.number): \(before.total) → \(invoice.total)") }
        }
        print("QA F82: \(moved.count) of \(world.invoices.count) demo invoices change total under the signed rates. \(moved)")
        #expect(world.invoices.count > 0)
        #expect(moved.isEmpty, "\(moved)")
    }
}
