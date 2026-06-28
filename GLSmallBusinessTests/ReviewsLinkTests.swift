//
//  ReviewsLinkTests.swift
//  GLSmallBusinessTests
//
//  The website / reviews URL fields and the review call-to-action on payment receipts: URLs are made
//  click-ready, and the reviews link appears in the receipt email/text only when one is set.
//

import Testing
@testable import GLSmallBusiness

@MainActor
struct ReviewsLinkTests {

    @Test func clickableURLPrependsSchemeWhenMissing() {
        #expect(BusinessProfile.clickableURL("g.page/acme")?.absoluteString == "https://g.page/acme")
        #expect(BusinessProfile.clickableURL("www.yelp.com/biz/x")?.absoluteString == "https://www.yelp.com/biz/x")
    }

    @Test func clickableURLKeepsAnExistingScheme() {
        #expect(BusinessProfile.clickableURL("https://yelp.com/biz/x")?.absoluteString == "https://yelp.com/biz/x")
        #expect(BusinessProfile.clickableURL("http://example.com")?.absoluteString == "http://example.com")
    }

    @Test func clickableURLIsNilWhenBlank() {
        #expect(BusinessProfile.clickableURL("") == nil)
        #expect(BusinessProfile.clickableURL("   ") == nil)
    }

    @Test func receiptMessageIncludesReviewLinkWhenSet() {
        let invoice = TS.invoice(lines: [(100, false)])
        let payment = TS.pay(invoice, 100)
        let business = BusinessProfile()
        business.businessName = "Acme"
        business.reviewsURL = "g.page/acme"

        let plain = PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business)
        #expect(plain.contains("https://g.page/acme"))
        #expect(plain.localizedCaseInsensitiveContains("review"))

        let html = PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business)
        #expect(html.contains("https://g.page/acme"))
        #expect(html.contains("Leave us a review"))
    }

    @Test func receiptMessageOmitsReviewWhenUnset() {
        let invoice = TS.invoice(lines: [(100, false)])
        let payment = TS.pay(invoice, 100)
        let business = BusinessProfile()   // no reviewsURL

        let plain = PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business)
        #expect(!plain.localizedCaseInsensitiveContains("leave us a quick review"))

        let html = PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business)
        #expect(!html.contains("Leave us a review"))
    }
}
