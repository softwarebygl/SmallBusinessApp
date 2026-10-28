//
//  MessageTests.swift
//  GLSmallBusinessTests
//
//  The email/text builders are pure string functions — high-value to test directly.
//

import Testing
import Foundation
import UIKit
@testable import GLSmallBusiness

@MainActor
struct MessageTests {
    private func business(name: String = "Gold Life LLC") -> BusinessProfile {
        let b = BusinessProfile()
        b.businessName = name
        b.phone = "555-1212"
        b.email = "a@b.com"
        return b
    }

    // MARK: - EmailHTML scaffold

    @Test func emailPageWrapsInAWhiteCard() {
        let html = EmailHTML.page("<p>hi</p>")
        #expect(html.contains("background-color:#ffffff"))   // the readable card
        #expect(html.contains("<p>hi</p>"))
    }

    @Test func summaryBoxRendersRows() {
        let box = EmailHTML.summaryBox([("Total", "$100.00", true), ("Due", "tomorrow", false)])
        #expect(box.contains("Total"))
        #expect(box.contains("$100.00"))
        #expect(box.contains("Due"))
    }

    // MARK: - Subjects

    @Test func invoiceSubjectVariants() {
        let inv = TS.invoice(number: "INV-0002")
        #expect(InvoiceMessage.subject(invoice: inv, business: business()) == "Invoice INV-0002 from Gold Life LLC")
        #expect(InvoiceMessage.subject(invoice: inv, business: nil) == "Your invoice INV-0002")
        let noNumber = TS.invoice(number: "")
        #expect(InvoiceMessage.subject(invoice: noNumber, business: business()) == "Your invoice from Gold Life LLC")
        #expect(InvoiceMessage.subject(invoice: noNumber, business: nil) == "Your invoice")
    }

    @Test func estimateSubjectVariants() {
        let est = TS.estimate(number: "EST-0009")
        #expect(EstimateMessage.subject(estimate: est, business: business()) == "Estimate EST-0009 from Gold Life LLC")
        #expect(EstimateMessage.subject(estimate: est, business: nil) == "Your estimate EST-0009")
        let noNum = TS.estimate(number: "")
        #expect(EstimateMessage.subject(estimate: noNum, business: business()) == "Your estimate from Gold Life LLC")
        #expect(EstimateMessage.subject(estimate: noNum, business: nil) == "Your estimate")
    }

    @Test func estimatePlainAndHtmlBodies() {
        let est = TS.estimate(number: "EST-0009", lines: [(1500, false)])
        est.customerFirstName = "Devin"
        let plain = EstimateMessage.plainBody(estimate: est, business: business())
        #expect(plain.contains("Hi Devin"))
        #expect(plain.contains("$1,500.00"))
        #expect(plain.contains("Gold Life LLC"))
        let html = EstimateMessage.htmlBody(estimate: est, business: business())
        #expect(html.contains("background-color:#ffffff"))
        #expect(html.contains("Hi Devin"))
        #expect(html.contains("$1,500.00"))
    }

    @Test func customWordingOverridesDefaults() {
        let b = business()
        b.messageIntro = "Custom intro line."
        b.messageClosing = "Custom closing."
        let est = TS.estimate()
        #expect(EstimateMessage.intro(estimate: est, business: b) == "Custom intro line.")
        #expect(EstimateMessage.closing(for: b) == "Custom closing.")
    }

    // MARK: - Bodies

    @Test func invoicePlainBodyHasGreetingAndFigures() {
        let inv = TS.invoice(lines: [(1000, false)])
        inv.customerFirstName = "Devin"
        TS.pay(inv, 400)
        let body = InvoiceMessage.plainBody(invoice: inv, business: business())
        #expect(body.contains("Hi Devin"))
        #expect(body.contains("$1,000.00"))   // total
        #expect(body.contains("$600.00"))     // balance
        #expect(body.contains("Gold Life LLC"))
    }

    @Test func invoiceHtmlBodyIsWrappedAndShowsTotals() {
        let inv = TS.invoice(lines: [(1000, false)])
        inv.customerFirstName = "Devin"
        let html = InvoiceMessage.htmlBody(invoice: inv, business: business())
        #expect(html.contains("background-color:#ffffff"))
        #expect(html.contains("Hi Devin"))
        #expect(html.contains("$1,000.00"))
    }

    @Test func htmlEscapesCustomerName() {
        let inv = TS.invoice()
        inv.customerFirstName = "A<b>&\"c"
        let html = InvoiceMessage.htmlBody(invoice: inv, business: business())
        #expect(html.contains("A&lt;b&gt;&amp;&quot;c"))
        #expect(!html.contains("A<b>&\"c"))
    }

    @Test func greetingFallsBackToThereWhenNoName() {
        let inv = TS.invoice()
        inv.customerFirstName = ""
        let body = InvoiceMessage.plainBody(invoice: inv, business: business())
        #expect(body.contains("Hi there"))
    }

    // MARK: - Payment receipt wording

    @Test func receiptMessageLeadsWithPaymentReceived() {
        let inv = TS.invoice(lines: [(1000, false)])
        inv.customerFirstName = "Devin"
        let p = TS.pay(inv, 400)
        let plain = PaymentReceiptMessage.plainBody(invoice: inv, payment: p, business: business())
        #expect(plain.contains("Payment received: $400.00"))
        #expect(plain.contains("Remaining balance: $600.00"))
        let html = PaymentReceiptMessage.htmlBody(invoice: inv, payment: p, business: business())
        #expect(html.contains("background-color:#ffffff"))
        #expect(html.contains("Payment received"))
    }

    @Test func receiptSaysPaidInFullWhenZeroRemaining() {
        let inv = TS.invoice(lines: [(1000, false)])
        let p = TS.pay(inv, 1000)
        let plain = PaymentReceiptMessage.plainBody(invoice: inv, payment: p, business: business())
        #expect(plain.contains("Paid in full"))
        #expect(PaymentReceiptMessage.subject(invoice: inv, business: business()).contains("Receipt"))
    }

    // MARK: - Change order wording

    @Test func changeOrderMessageShowsDeltaAndRevisedTotal() {
        let inv = TS.invoice(lines: [(1000, false)])
        inv.customerFirstName = "Devin"
        let co = TS.changeOrder(inv, status: .pending, lines: [(480, false)])
        let plain = ChangeOrderMessage.plainBody(co, business: business())
        #expect(plain.contains("+$480.00"))
        #expect(plain.contains("$1,480.00"))   // revised total
        let html = ChangeOrderMessage.htmlBody(co, business: business())
        #expect(html.contains("background-color:#ffffff"))
        #expect(ChangeOrderMessage.subject(co, business: business()).contains("CO-0001"))
    }

    // MARK: - Custom subject / wording overrides (consistent across all documents)

    @Test func estimateAndInvoiceSubjectsAcceptCustomOverride() {
        let b = business()
        b.estimateMessageSubject = "Your project quote"
        b.invoiceMessageSubject = "Time to pay 🙂"
        #expect(EstimateMessage.subject(estimate: TS.estimate(number: "EST-1"), business: b) == "Your project quote")
        #expect(InvoiceMessage.subject(invoice: TS.invoice(number: "INV-1"), business: b) == "Time to pay 🙂")
    }

    @Test func receiptCustomWordingOverridesDefaults() {
        let b = business()
        b.receiptMessageSubject = "Got it — thanks!"
        b.receiptMessageIntro = "We received your payment."
        b.receiptMessageClosing = "Questions? Call us."
        let inv = TS.invoice(lines: [(1000, false)])
        let p = TS.pay(inv, 400)
        #expect(PaymentReceiptMessage.subject(invoice: inv, business: b) == "Got it — thanks!")
        let plain = PaymentReceiptMessage.plainBody(invoice: inv, payment: p, business: b)
        #expect(plain.contains("We received your payment."))
        #expect(plain.contains("Questions? Call us."))
    }

    @Test func changeOrderCustomWordingOverridesDefaults() {
        let b = business()
        b.changeOrderMessageSubject = "Scope update"
        b.changeOrderMessageIntro = "Please review this change."
        b.changeOrderMessageClosing = "Reply yes to approve."
        let co = TS.changeOrder(TS.invoice(lines: [(1000, false)]), status: .pending, lines: [(100, false)])
        #expect(ChangeOrderMessage.subject(co, business: b) == "Scope update")
        let plain = ChangeOrderMessage.plainBody(co, business: b)
        #expect(plain.contains("Please review this change."))
        #expect(plain.contains("Reply yes to approve."))
    }

    // MARK: - Logo (no fallback to the bundled mark)

    @Test func emailOmitsLogoWhenNoneUploaded() {
        let b = business()   // no logoData uploaded
        let html = EstimateMessage.htmlBody(estimate: TS.estimate(lines: [(100, false)]), business: b)
        #expect(!html.contains("data:image/png;base64"))         // no embedded logo
        #expect(EstimateMessage.logoAttachmentURL(business: b) == nil)  // nothing attached to a text
        #expect(EstimateMessage.logoPNGData(business: b) == nil)
    }

    @Test func emailEmbedsUploadedLogo() {
        let b = business()
        b.logoData = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData()
        let html = EstimateMessage.htmlBody(estimate: TS.estimate(lines: [(100, false)]), business: b)
        #expect(html.contains("data:image/png;base64"))         // the uploaded logo is embedded
        #expect(EstimateMessage.logoAttachmentURL(business: b) != nil)
    }

    @Test func emptyOverridesFallBackToDefaults() {
        // Blank custom fields must not blank out the message — defaults still apply.
        let b = business()
        b.receiptMessageClosing = "   "
        let inv = TS.invoice(lines: [(1000, false)])
        let p = TS.pay(inv, 400)
        #expect(PaymentReceiptMessage.closing(business: b) == PaymentReceiptMessage.defaultClosing)
        #expect(PaymentReceiptMessage.plainBody(invoice: inv, payment: p, business: b).contains(PaymentReceiptMessage.defaultClosing))
    }
}
