//
//  InvoiceDetailDisplayTests.swift
//  GLSmallBusinessTests
//
//  QA fixes on InvoiceDetailScreen: change-order credit lines display signed on screen (matching
//  the PDF and Invoice.totals, instead of flooring to $0.00), and the Stripe paid-prompt path may
//  record a collected amount that exceeds the remaining balance while manual entries stay
//  hard-blocked.
//

import Testing
import Foundation
import SwiftData
import MessageUI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct InvoiceDetailDisplayTests {

    // MARK: - Signed change-order credit display (screen mirrors InvoicePDFDocument)

    @Test func creditChangeOrderLineDisplaysSignedAndSubtotalReconciles() throws {
        let invoice = TS.invoice(lines: [(1000, false), (-500, false)])
        let group = try #require(invoice.sortedGroups.first)
        let credit = try #require(group.sortedLineItems.last)
        credit.fromChangeOrder = true

        let screen = InvoiceDetailScreen(invoice: invoice)
        // The credit keeps its sign — the floored lineTotal (what the screen used to show) is $0.00.
        #expect(close(credit.lineTotal, 0))
        #expect(close(screen.displayLineTotal(credit), -500))
        // And the group subtotal uses the same signed math, so it reconciles with the totals card.
        #expect(close(screen.groupSubtotal(group), 500))
        #expect(close(invoice.subtotal, 500))
    }

    @Test func originalWorkStaysFlooredAtZero() throws {
        // An over-discounted ORIGINAL line still floors at 0 — only change-order lines go signed.
        let invoice = TS.invoice(lines: [(100, false)])
        let group = try #require(invoice.sortedGroups.first)
        let item = try #require(group.sortedLineItems.first)
        item.discountType = .fixed
        item.discountValue = 150

        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(screen.displayLineTotal(item), 0))
        #expect(close(screen.groupSubtotal(group), 0))
    }

    // MARK: - Stripe paid-prompt overage vs. manual over-balance guard

    @Test func stripePrefilledOverageIsSavable() {
        // $1,000 invoice, $500 link paid at Stripe, but a $700 check was recorded first → balance
        // $300. Stripe still collected the full $500; the prompt-opened sheet must allow it as-is.
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 700)
        let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 500, prefillMethod: .stripe,
                                       prefillStripeLinkId: "plink_test")
        #expect(sheet.exceedsBalance)
        #expect(!sheet.saveBlocked)
    }

    @Test func manualOverBalanceStaysBlocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 700)
        let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 500)   // no link id → manual
        #expect(sheet.exceedsBalance)
        #expect(sheet.saveBlocked)
    }

    @Test func zeroAmountBlockedEvenOnStripePath() {
        let invoice = TS.invoice(lines: [(1000, false)])
        let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 0, prefillMethod: .stripe,
                                       prefillStripeLinkId: "plink_test")
        #expect(sheet.saveBlocked)
    }

    @Test func withinBalanceStripeSaveNotBlocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 400, prefillMethod: .stripe,
                                       prefillStripeLinkId: "plink_test")
        #expect(!sheet.exceedsBalance)
        #expect(!sheet.saveBlocked)
    }

    // MARK: - Invoice Attachments (Photos & Documents)

    @Test func invoiceAttachmentsAccessorsFilterPhotosAndDocuments() {
        let invoice = TS.invoice(lines: [(500, false)])
        let photo1 = JobAttachment(kind: .photo, name: "Site Before", data: Data([1, 2]), invoice: invoice)
        let photo2 = JobAttachment(kind: .photo, name: "Site After", data: Data([3, 4]), invoice: invoice)
        let doc = JobAttachment(kind: .document, name: "Permit.pdf", data: Data([5, 6]), invoice: invoice)
        invoice.attachments = [photo1, photo2, doc]

        #expect(invoice.photos.count == 2)
        #expect(invoice.documents.count == 1)
        #expect(invoice.documents.first?.name == "Permit.pdf")
    }

    @Test func rendersInvoiceDetailScreenWithPhotosAndDocuments() throws {
        let world = try TestStore.demoWorld()
        let invoice = try #require(world.invoices.first)
        let photo1 = JobAttachment(kind: .photo, name: "Site Before", data: Data([1, 2]), invoice: invoice)
        let doc = JobAttachment(kind: .document, name: "Permit.pdf", data: Data([3, 4]), invoice: invoice)
        world.context.insert(photo1)
        world.context.insert(doc)
        invoice.attachments = [photo1, doc]
        try world.context.save()

        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: world.container)
    }

    @Test func rendersInvoiceDetailScreenWithChangeOrdersAndPayments() throws {
        let world = try TestStore.demoWorld()
        let invoice = try #require(world.invoices.first)
        let co = ChangeOrder(number: "CO-1", title: "Extra Work")
        co.note = "Notes"
        co.status = .approved
        co.invoice = invoice
        world.context.insert(co)
        let line = ChangeOrderLineItem(name: "Extra Tile", details: "", quantity: 10, unit: .squareFoot, unitPrice: 20, isTaxable: true)
        line.changeOrder = co
        world.context.insert(line)
        co.lineItems = [line]

        let payment = InvoicePayment(amount: 50, date: .now, method: .cash, note: "Cash deposit")
        payment.invoice = invoice
        world.context.insert(payment)
        invoice.payments = [payment]
        invoice.changeOrders = [co]
        try world.context.save()

        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: world.container)
    }

    @Test func rendersInvoiceFormScreenWithLinkedJob() throws {
        let world = try TestStore.demoWorld()
        let customer = Customer(firstName: "John", lastName: "Appleseed")
        world.context.insert(customer)
        let job = ScheduledJob(title: "Tile install", customer: customer)
        world.context.insert(job)
        let attachment = JobAttachment(kind: .photo, name: "Job site photo", data: Data([1, 2]), job: job)
        world.context.insert(attachment)
        job.attachments = [attachment]
        try world.context.save()

        GLTestHost.render(InvoiceFormScreen(customer: customer, job: job), container: world.container)
    }

    @Test func savesRecordPaymentAndSetAmountDue() throws {
        let world = try TestStore.demoWorld()
        let invoice = try #require(world.invoices.first)
        let recordSheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 100, prefillMethod: .cash)
        let saved = recordSheet.save()
        #expect(saved)
        #expect(invoice.payments?.contains { $0.amount == 100 } == true)

        let amountDueSheet = SetAmountDueSheet(invoice: invoice)
        GLTestHost.render(amountDueSheet, container: world.container)
        amountDueSheet.save()
    }

    @Test func rendersPaymentReceiptSheetAndSendOptions() throws {
        let world = try TestStore.demoWorld()
        let invoice = try #require(world.invoices.first)
        let payment = InvoicePayment(amount: 150, date: .now, method: .check, note: "Check 101")
        payment.invoice = invoice
        world.context.insert(payment)
        if invoice.payments == nil { invoice.payments = [] }
        invoice.payments?.append(payment)
        try world.context.save()

        let receiptSheet = PaymentReceiptSheet(invoice: invoice, payment: payment)
        GLTestHost.renderBothSchemes(receiptSheet, container: world.container)

        #expect(PaymentReceiptSheet.SendAction.email.id == 0)
        #expect(PaymentReceiptSheet.SendAction.text.id == 1)

        receiptSheet.noteSend(.failed)
        receiptSheet.noteSend(.sent)
        if MFMailComposeViewController.canSendMail() {
            GLTestHost.render(receiptSheet.sendSheet(.email), container: world.container)
        }
        if MFMessageComposeViewController.canSendText() {
            GLTestHost.render(receiptSheet.sendSheet(.text), container: world.container)
        }
    }

    @Test func rendersInvoiceDetailScreenWithIncompleteProfile() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let customer = Customer(firstName: "Bob", lastName: "Builder")
        let invoice = Invoice(jobTitle: "Drywall repair", customer: customer)
        ctx.insert(customer)
        ctx.insert(invoice)
        try ctx.save()

        // Empty business profile -> profileIsComplete is false -> "Set up business profile to send" button
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: container)
    }
}

