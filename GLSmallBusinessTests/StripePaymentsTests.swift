//
//  StripePaymentsTests.swift
//  GLSmallBusinessTests
//
//  Logic for the Stripe invoice-payments feature: the inclusion enum + status enum, the
//  BusinessProfile accessors, and Invoice's send-time gating + stable correlation id.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct StripePaymentsTests {

    // MARK: - PayLinkInclusion / StripePayLinkStatus

    @Test func inclusionRoundTrips() {
        for value in PayLinkInclusion.allCases {
            #expect(PayLinkInclusion(rawValue: value.rawValue) == value)
            #expect(!value.label.isEmpty)
            #expect(!value.detail.isEmpty)
        }
        #expect(PayLinkInclusion.allCases.count == 3)
    }

    @Test func statusRoundTrips() {
        for value in StripePayLinkStatus.allCases {
            #expect(StripePayLinkStatus(rawValue: value.rawValue) == value)
        }
        #expect(StripePayLinkStatus(rawValue: "garbage") == nil)
    }

    // MARK: - BusinessProfile accessors

    @Test func inclusionDefaultsToAll() {
        let b = BusinessProfile()
        #expect(b.payLinkInclusion == .all)        // default raw value
        #expect(b.stripeIsConnected == false)      // empty account id
    }

    @Test func inclusionAccessorWritesRaw() {
        let b = BusinessProfile()
        b.payLinkInclusion = .customSelect
        #expect(b.payLinkInclusionRaw == "customSelect")
        #expect(b.payLinkInclusion == .customSelect)
    }

    @Test func connectedReflectsAccountId() {
        let b = BusinessProfile()
        #expect(!b.stripeIsConnected)
        b.stripeConnectedAccountId = "acct_abc"
        #expect(b.stripeIsConnected)
    }

    @Test func payLinkDefaultOnDefaultsTrue() {
        // New invoices seed their per-invoice includePayLink from this; defaults on.
        #expect(BusinessProfile().payLinkDefaultOn == true)
    }

    // MARK: - Invoice.shouldIncludePayLink

    @Test func shouldIncludePayLinkNeedsAConnectedChargeReadyAccountAndTheInvoiceOptIn() {
        let invoice = TS.invoice(lines: [(1000, false)])
        invoice.includePayLink = true
        #expect(!invoice.shouldIncludePayLink(nil))                        // no business at all

        let notConnected = BusinessProfile()
        #expect(!invoice.shouldIncludePayLink(notConnected))               // no account id

        // Connected but onboarding unfinished — never mint until the account can actually charge.
        let connectedNoCharges = BusinessProfile()
        connectedNoCharges.stripeConnectedAccountId = "acct_x"
        #expect(!invoice.shouldIncludePayLink(connectedNoCharges))

        let ready = BusinessProfile()
        ready.stripeConnectedAccountId = "acct_x"
        ready.stripeChargesEnabled = true
        #expect(invoice.shouldIncludePayLink(ready))

        invoice.includePayLink = false
        #expect(!invoice.shouldIncludePayLink(ready))                      // per-invoice opt-out wins
    }

    // MARK: - Invoice.ensureStripeAppInvoiceId

    @Test func appInvoiceIdIsLazyAndStable() {
        let inv = TS.invoice()
        #expect(inv.stripeAppInvoiceId.isEmpty)          // not generated until first use

        let first = inv.ensureStripeAppInvoiceId()
        #expect(!first.isEmpty)
        #expect(UUID(uuidString: first) != nil)          // a real UUID
        #expect(inv.stripeAppInvoiceId == first)         // persisted on the invoice

        let second = inv.ensureStripeAppInvoiceId()
        #expect(second == first)                         // stable across calls
    }

    @Test func payLinkStatusAccessorRoundTripsAndDefaultsSafely() {
        let invoice = TS.invoice(lines: [(100, false)])
        #expect(invoice.stripePayLinkStatus == .none)          // empty raw
        invoice.stripePayLinkStatusRaw = "garbage-from-a-newer-build"
        #expect(invoice.stripePayLinkStatus == .none)          // unknown raw never traps
        invoice.stripePayLinkStatus = .paid
        #expect(invoice.stripePayLinkStatusRaw == "paid")
        invoice.stripePayLinkStatus = .open
        #expect(invoice.stripePayLinkStatusRaw == "open")
    }

    /// Only the card-shaped methods may satisfy a Stripe pay link during reconciliation — checked
    /// for EVERY case so a new rail can't slip into the reconciler unnoticed.
    @Test func couldSettleStripeLinkIsOnlyCardAndStripe() {
        for method in PaymentMethod.allCases {
            let expected = (method == .card || method == .stripe)
            #expect(method.couldSettleStripeLink == expected)
        }
    }

    /// A mint that failed AFTER the backend retired the prior link leaves the invoice pointing at a
    /// link Stripe has already deactivated; the send flow forgets it so a later same-amount send
    /// re-mints instead of embedding a dead link. The mint counter must SURVIVE — it's what keeps the
    /// Stripe idempotency key unique, so resetting it would replay the dead link's cached response.
    @Test func clearingThePayLinkForgetsEverythingButTheMintCounter() {
        let inv = TS.invoice()
        inv.stripePaymentLinkId = "plink_dead"
        inv.stripePaymentLinkURL = "https://buy.stripe.com/dead"
        inv.stripePaymentLinkAccountId = "acct_old"
        inv.stripePaymentLinkAmountCents = 100_000
        inv.stripePaymentLinkMintedAt = .now
        inv.stripePayLinkStatus = .open
        inv.stripePayLinkMintCount = 3

        inv.clearStripePayLink()

        #expect(inv.stripePaymentLinkId == "")
        #expect(inv.stripePaymentLinkURL == "")
        #expect(inv.stripePaymentLinkAccountId == "")
        #expect(inv.stripePaymentLinkAmountCents == 0)
        #expect(inv.stripePaymentLinkMintedAt == nil)
        #expect(inv.stripePayLinkStatus == .none)
        #expect(inv.stripePayLinkMintCount == 3)
    }

    /// The account stamp starts empty, which counts as a MISMATCH — a link minted before we recorded
    /// its account can't be proven to belong to the account connected now, so the send flow re-mints.
    @Test func payLinkAccountStampDefaultsEmpty() {
        let inv = TS.invoice()
        #expect(inv.stripePaymentLinkAccountId == "")
        #expect(inv.stripePaymentLinkAccountId != "acct_current")
    }

    // MARK: - QA-fix fields (idempotency nonce, payment↔link reconciliation, ownership claim)

    @Test func qaFixFieldsDefault() {
        let inv = TS.invoice()
        #expect(inv.stripePayLinkMintCount == 0)         // idempotency nonce seed
        let payment = TS.pay(inv, 100)
        #expect(payment.stripePaymentLinkId == "")       // unstamped until recorded from a Stripe prompt
        let business = BusinessProfile()
        #expect(business.stripeAccountClaim == "")        // empty until first connected
    }
}
