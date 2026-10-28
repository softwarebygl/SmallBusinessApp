//
//  ReviewsLinkTests.swift
//  GLSmallBusinessTests
//
//  The website / reviews URL fields and the review call-to-action on payment receipts: URLs are made
//  click-ready, and the reviews link appears in the receipt email/text only when one is set.
//

import Testing
import SwiftData
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

    @Test func receiptMessageIncludesReviewLinkWhenSetAndEnabled() {
        let invoice = TS.invoice(lines: [(100, false)])
        let payment = TS.pay(invoice, 100)
        let business = BusinessProfile()
        business.businessName = "Acme"
        business.reviewsURL = "g.page/acme"
        business.includeReviewLinkOnReceipts = true

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
        business.includeReviewLinkOnReceipts = true

        let plain = PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business)
        #expect(!plain.localizedCaseInsensitiveContains("leave us a quick review"))

        let html = PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business)
        #expect(!html.contains("Leave us a review"))
    }

    /// Receipts stay a pure acknowledgement by default — a saved reviews link alone must NOT add the
    /// review ask; the owner opts in with the receipts toggle (off is the stored default).
    @Test func receiptMessageOmitsReviewWhenToggleOff() {
        let invoice = TS.invoice(lines: [(100, false)])
        let payment = TS.pay(invoice, 100)
        let business = BusinessProfile()
        business.reviewsURL = "g.page/acme"
        #expect(business.includeReviewLinkOnReceipts == false)   // the schema default is off
        #expect(business.receiptReviewLink == nil)

        let plain = PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business)
        #expect(!plain.contains("https://g.page/acme"))

        let html = PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business)
        #expect(!html.contains("Leave us a review"))
    }

    // MARK: - Standalone review request (sent from My Business Details)

    @Test func reviewRequestCarriesLinkAndContext() {
        let business = BusinessProfile()
        business.businessName = "Acme"
        business.reviewsURL = "g.page/acme"

        let subject = ReviewRequestMessage.subject(business: business)
        #expect(subject.contains("Acme"))

        let plain = ReviewRequestMessage.plainBody(business: business)
        #expect(plain.contains("https://g.page/acme"))
        #expect(plain.contains("Acme"))
        #expect(plain.localizedCaseInsensitiveContains("review"))
        #expect(plain.localizedCaseInsensitiveContains("thank you"))   // context, not a bare link

        let html = ReviewRequestMessage.htmlBody(business: business)
        #expect(html.contains("https://g.page/acme"))
        #expect(html.contains("Leave us a review"))
        #expect(html.contains("Acme"))
    }

    /// The standalone request ignores the receipts toggle — it's an explicit send, so the link is
    /// included whenever one is set.
    @Test func reviewRequestIgnoresReceiptsToggle() {
        let business = BusinessProfile()
        business.reviewsURL = "g.page/acme"
        business.includeReviewLinkOnReceipts = false

        #expect(ReviewRequestMessage.plainBody(business: business).contains("https://g.page/acme"))
        #expect(ReviewRequestMessage.htmlBody(business: business).contains("https://g.page/acme"))
    }
}
