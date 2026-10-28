//
//  SendPreparerTests.swift
//  GLSmallBusinessTests — Domain
//
//  What a send hands the compose sheet, and the Stripe pay-link rules moved out of
//  InvoiceDetailScreen.prepareSend — run against a fake backend, never the network.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

/// A stand-in Stripe backend. Test-only and used serially, hence the unchecked Sendable. Shared with
/// MoneyRoundingTests (the cents a pay link is minted for).
final class FakeStripe: PayLinkBackend, @unchecked Sendable {
    var canCharge = true
    var failMint = false
    /// What a mint throws instead of answering (the Worker's 400 / 409 answers), when set.
    var mintError: StripeBackendError?
    var statusCalls = 0
    var mints: [(amountCents: Int, key: String, supersedes: String?)] = []
    /// Every appInvoiceId a mint named, in order.
    var mintRefs: [String] = []
    /// The Worker's stored pay status for the invoice ("none" | "open" | "paid") and what was paid.
    var payStatus = "none"
    var amountPaidCents: Int?
    var payStatusCalls = 0
    /// What the connect-status read throws instead of answering, when set.
    var connectStatusError: StripeBackendError?
    /// What the pay-status read throws instead of answering, when set.
    var payStatusError: StripeBackendError?

    private struct Failure: Error {}

    func connectStatus() async throws -> StripeConnectStatus {
        statusCalls += 1
        if let connectStatusError { throw connectStatusError }
        let json = #"{"chargesEnabled":\#(canCharge),"payoutsEnabled":true,"detailsSubmitted":true,"currentlyDueCount":0}"#
        return try JSONDecoder().decode(StripeConnectStatus.self, from: Data(json.utf8))
    }

    func createPaymentLink(appInvoiceId: String, amountCents: Int, currency: String, description: String,
                           idempotencyKey: String, supersedesLinkId: String?) async throws -> StripePayLinkResponse {
        mints.append((amountCents, idempotencyKey, supersedesLinkId))
        mintRefs.append(appInvoiceId)
        if failMint { throw Failure() }
        if let mintError { throw mintError }
        let json = #"{"url":"https://pay.example/\#(mints.count)","paymentLinkId":"plink_\#(mints.count)"}"#
        return try JSONDecoder().decode(StripePayLinkResponse.self, from: Data(json.utf8))
    }

    func payLinkStatus(appInvoiceId: String) async throws -> StripePayLinkStatusResponse {
        payStatusCalls += 1
        if let payStatusError { throw payStatusError }
        let paid = amountPaidCents.map { #","amountPaidCents":\#($0)"# } ?? ""
        let json = #"{"status":"\#(payStatus)"\#(paid)}"#
        return try JSONDecoder().decode(StripePayLinkStatusResponse.self, from: Data(json.utf8))
    }
}

@MainActor
@Suite(.serialized)
struct SendPreparerTests {

    private func world(chargesEnabled: Bool = true) throws -> (ModelContext, BusinessProfile, Invoice) {
        let context = try DomainFixtures.context()
        let profile = BusinessProfile()
        profile.businessName = "Gold Standard Tile"
        profile.stripeConnectedAccountId = "acct_1"
        profile.stripeChargesEnabled = chargesEnabled
        context.insert(profile)
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(number: "INV-0009", status: .sent, lines: [(1000, false)], in: context)
        invoice.customer = customer
        invoice.includePayLink = true
        context.saveChanges()
        return (context, profile, invoice)
    }

    private func environment(_ backend: FakeStripe, linked: Bool = true, configured: Bool = true) -> PayLinkEnvironment {
        PayLinkEnvironment(isConfigured: configured, deviceLinked: linked, backend: backend)
    }

    // MARK: The instant decision

    @Test func planDecidesWithoutTheNetworkWhenItCan() throws {
        let (_, profile, invoice) = try world()
        let stripe = FakeStripe()
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe, configured: false))
                == .decided(.ready))
        #expect(SendPreparer.payLinkPlan(for: invoice, business: nil, environment: environment(stripe)) == .decided(.ready))
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe, linked: false))
                == .decided(.deviceUnlinked))
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe))
                == .mint(accountId: "acct_1"))

        profile.stripeChargesEnabled = false
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe))
                == .decided(.unavailable), "wants a Pay button the account can't take — say so")
        invoice.includePayLink = false
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe))
                == .decided(.ready), "didn't want one — nothing to say")
        #expect(stripe.statusCalls == 0)
    }

    // MARK: Mint / reuse

    @Test func mintsOnceReusesForTheSameAmountAndRetiresOnAChange() async throws {
        let (context, profile, invoice) = try world()
        let stripe = FakeStripe()

        let first = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(first == .ready)
        #expect(invoice.stripePaymentLinkId == "plink_1" && invoice.stripePaymentLinkAmountCents == 100_000)
        #expect(invoice.stripePaymentLinkAccountId == "acct_1" && invoice.stripePayLinkStatus == .open)
        #expect(invoice.stripePaymentLinkMintedAt != nil && !invoice.stripeAppInvoiceId.isEmpty)
        #expect(!context.hasChanges, "the stored link is saved, not left to autosave")
        #expect(SendPreparer.currentPayLinkURL(for: invoice, business: profile) == "https://pay.example/1")
        #expect(SendPreparer.invoice(invoice, business: profile, pdfURL: nil).htmlBody.contains("https://pay.example/1"))

        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(stripe.mints.count == 1, "same account, same amount, not paid — reused")

        invoice.amountDueNow = 250
        context.saveChanges()
        #expect(SendPreparer.currentPayLinkURL(for: invoice, business: profile) == nil, "a stale amount is never sent")
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(stripe.mints.count == 2)
        #expect(stripe.mints[1].amountCents == 25_000 && stripe.mints[1].supersedes == "plink_1")
        #expect(stripe.mints[1].key.hasSuffix("-25000-2"), "a fresh mint count keeps the idempotency key unique")
        #expect(invoice.stripePaymentLinkId == "plink_2")
    }

    @Test func failsOpen() async throws {
        let (context, _, invoice) = try world()
        let stripe = FakeStripe()
        stripe.canCharge = false
        let cannotCharge = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(cannotCharge == .unavailable && stripe.mints.isEmpty)

        // A mint that fails AFTER retiring the stored link forgets it, so it is never re-sent.
        stripe.canCharge = true
        invoice.stripePaymentLinkId = "plink_old"
        invoice.stripePaymentLinkURL = "https://pay.example/old"
        invoice.stripePaymentLinkAccountId = "acct_other"
        invoice.stripePaymentLinkAmountCents = 100_000
        context.saveChanges()
        stripe.failMint = true
        let failed = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(failed == .linkFailed, "a failed mint says Stripe couldn't make the link, not that the account can't take cards (F81)")
        #expect(invoice.stripePaymentLinkId.isEmpty && invoice.stripePaymentLinkURL.isEmpty)
        #expect(!context.hasChanges)

        // Nothing to pay: no link, nothing to say.
        TS.pay(invoice, 1000, in: context)
        context.saveChanges()
        let paid = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(paid == .ready && stripe.mints.count == 1)
    }

    @Test func mintingIsAWriteTheGateRefuses() async throws {
        let (context, _, invoice) = try world()
        let stripe = FakeStripe()
        let refusal: DomainError? = await DomainState.lapsed.runAsync {
            do {
                _ = try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context,
                                                       environment: environment(stripe))
                return nil
            } catch { return error as? DomainError }
        }
        #expect(refusal == .readOnly(operation: "mintPayLink", lapsed: true))
        #expect(stripe.statusCalls == 0 && stripe.mints.isEmpty)
    }

    // MARK: Compose content

    @Test func composeContentForEachDocument() throws {
        let (context, profile, invoice) = try world()
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("probe.pdf")
        context.insert(JobAttachment(kind: .photo, name: "Before", data: Data([1]), invoice: invoice))
        context.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([2]), invoice: invoice))
        context.saveChanges()

        let inv = SendPreparer.invoice(invoice, business: profile, pdfURL: pdf)
        #expect(inv.emailRecipients == ["marcus@reedgc.com"] && inv.textRecipients == ["(850) 555-0193"])
        #expect(inv.shareURLs.first == pdf && inv.shareURLs.count == 3)
        #expect(inv.shareURLs.map(\.lastPathComponent).contains("Before.jpg"))
        #expect(inv.mailAttachments.map(\.fileName).sorted() == ["Before.jpg", "Permit.pdf"])
        #expect(inv.payLinkURL == nil, "no link minted yet — and composing never mints")
        #expect(!inv.subject.isEmpty && !inv.plainBody.isEmpty)

        let estimate = TS.estimate(in: context)
        estimate.customer = invoice.customer
        let est = SendPreparer.estimate(estimate, business: profile, pdfURL: pdf)
        #expect(est.emailRecipients == ["marcus@reedgc.com"] && est.messageAttachmentURLs.last == pdf)

        let order = TS.changeOrder(invoice, in: context)
        let co = SendPreparer.changeOrder(order, business: profile, pdfURL: pdf)
        #expect(co.textRecipients == ["(850) 555-0193"] && co.messageAttachmentURLs == [pdf])

        let payment = TS.pay(invoice, 100, in: context)
        let receipt = SendPreparer.paymentReceipt(invoice, payment: payment, business: profile, pdfURL: nil)
        #expect(receipt.messageAttachmentURLs.isEmpty && receipt.pdfURL == nil)
    }

    // MARK: Attachment files (audit 2026-10-03 F13)

    /// Every photo picked before 3.3.0 was named "Photo", and each one was written to
    /// tmp/Photo.jpg — so Messages and the share sheet got three copies of ONE photo. Three
    /// photos must give three files holding three different photos.
    @Test func threePhotosGiveThreeDistinctFiles() throws {
        let (context, profile, invoice) = try world()
        for byte: UInt8 in [1, 2, 3] {
            context.insert(JobAttachment(kind: .photo, name: "Photo", data: Data([0xFF, 0xD8, 0xFF, byte]),
                                         invoice: invoice))
        }
        context.saveChanges()

        let content = SendPreparer.invoice(invoice, business: profile, pdfURL: nil)
        defer { SendPreparer.discard(content) }
        let urls = content.shareURLs
        #expect(urls.count == 3)
        #expect(Set(urls).count == 3, "three different files, not one path three times")
        let bytes = urls.compactMap { try? Data(contentsOf: $0) }
        #expect(bytes.count == 3 && Set(bytes).count == 3, "each file holds its own photo")
        #expect(Set(urls.map(\.lastPathComponent)) == ["Photo.jpg", "Photo 2.jpg", "Photo 3.jpg"])
        #expect(Set(content.mailAttachments.map(\.fileName)) == ["Photo.jpg", "Photo 2.jpg", "Photo 3.jpg"],
                "Mail names them the same way")
        #expect(Set(content.messageAttachmentURLs).isSuperset(of: urls), "Messages gets the same three files")
    }

    /// Each send writes into a fresh folder of its own, so a second send can't overwrite the
    /// first's files while its sheet is still open, and a stored name can't write outside it.
    @Test func eachSendWritesIntoItsOwnFolder() throws {
        let (context, profile, invoice) = try world()
        context.insert(JobAttachment(kind: .document, name: "../escape.pdf", data: Data([1]), invoice: invoice))
        context.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([2]), invoice: invoice))
        context.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([3]), invoice: invoice))
        context.saveChanges()

        let first = SendPreparer.invoice(invoice, business: profile, pdfURL: nil)
        let second = SendPreparer.invoice(invoice, business: profile, pdfURL: nil)
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for url in first.shareURLs + second.shareURLs {
            let folder = url.deletingLastPathComponent().standardizedFileURL
            #expect(folder.path != tmp, "never loose in tmp: \(url.path)")
            #expect(folder.deletingLastPathComponent().standardizedFileURL.path == tmp,
                    "one level down, in the send's own folder: \(url.path)")
        }
        #expect(Set(first.shareURLs).isDisjoint(with: Set(second.shareURLs)),
                "a second send never overwrites the first's files")
        #expect(Set(first.shareURLs.map(\.lastPathComponent)).count == 3, "same-named documents get their own names")

        // Closing the sheet removes exactly that send's files; the other send's stay.
        let firstFolder = try #require(first.sendFolder)
        SendPreparer.discard(first)
        #expect(!FileManager.default.fileExists(atPath: firstFolder.path))
        #expect(second.shareURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        SendPreparer.discard(second)
    }

    /// Names are made safe and unique without the filesystem.
    @Test func safeUniqueNames() {
        #expect(SendFiles.safeName("../escape.pdf", fallback: "Document.pdf") == "-escape.pdf")
        #expect(SendFiles.safeName("  ", fallback: "Document.pdf") == "Document.pdf")
        #expect(SendFiles.safeName("..", fallback: "Photo") == "Photo")
        #expect(SendFiles.safeName("a/b:c", fallback: "x") == "a-b-c")
        #expect(SendFiles.unique("Photo.jpg", taken: []) == "Photo.jpg")
        #expect(SendFiles.unique("Photo.jpg", taken: ["photo.jpg"]) == "Photo 2.jpg")
        #expect(SendFiles.unique("Photo.jpg", taken: ["photo.jpg", "photo 2.jpg"]) == "Photo 3.jpg")
        #expect(SendFiles.unique("README", taken: ["readme"]) == "README 2")
    }

    /// A send folder is the only thing discard ever removes.
    @Test func discardTouchesOnlySendFolders() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        SendFiles.discard(other)
        #expect(FileManager.default.fileExists(atPath: other.path))
        let folder = try #require(SendFiles.makeFolder())
        SendFiles.discard(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Over the card limit (audit 2026-10-03 F81)

    /// A balance over $50,000 used to fail at the Worker and show "your Stripe account can't take card
    /// payments" — false, and it sent the owner to reconnect Stripe for nothing. It is decided before
    /// any Stripe call, ahead of the device check, so the reason given is the true one.
    @Test func overTheCardLimitSaysSoBeforeAnyStripeCall() async throws {
        let (context, profile, invoice) = try world()
        let line = try #require(invoice.groups?.first?.lineItems?.first)
        line.unitPrice = 50_000.01
        context.saveChanges()
        let stripe = FakeStripe()
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe))
                == .decided(.overLimit))
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe, linked: false))
                == .decided(.overLimit), "the limit is the true reason, whatever this device's link")
        let outcome = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(outcome == .overLimit)
        #expect(stripe.mints.isEmpty, "nothing is minted over the limit")

        // Exactly $50,000.00 still gets its Pay button.
        line.unitPrice = 50_000
        context.saveChanges()
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: environment(stripe))
                == .mint(accountId: "acct_1"))
        let atLimit = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(atLimit == .ready && stripe.mints.last?.amountCents == 5_000_000)
    }

    /// The Worker's 400 amount_too_large is the same answer, not "can't take cards", and since the
    /// Worker refuses before retiring anything, the stored link is kept.
    @Test func workerAmountTooLargeIsTheSameAnswer() async throws {
        #expect(StripeBackendClient.error(forStatus: 400, body: Data(#"{"error":"amount_too_large","maxCents":5000000}"#.utf8))
                == .amountTooLarge)
        #expect(StripeBackendClient.error(forStatus: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)) == .http(400))
        let (context, _, invoice) = try world()
        let stripe = FakeStripe()
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        invoice.amountDueNow = 250
        context.saveChanges()
        stripe.mintError = .amountTooLarge
        let outcome = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(outcome == .overLimit)
        #expect(invoice.stripePaymentLinkId == "plink_1", "nothing was retired, so nothing is forgotten")
    }

    // MARK: A paid link is never re-minted (audit 2026-10-03 F14)

    /// The customer paid the link, the owner tapped "Not now" (or the poll never ran), then edited the
    /// invoice and sent again. HEAD minted a new link, which reset the Worker's paid record and handed
    /// the customer a second live Pay button. Now the send reads the status first, mints nothing, and
    /// hands back what Stripe collected so the screen asks to record it.
    @Test func aPaidLinkIsRecordedFirstAndNothingIsMinted() async throws {
        let (context, profile, invoice) = try world()
        let stripe = FakeStripe()
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        stripe.payStatus = "paid"
        stripe.amountPaidCents = 100_000

        // Same amount: HEAD reused the paid link. Changed amount: HEAD minted a second one.
        for amountDueNow in [0.0, 250.0] {
            invoice.amountDueNow = amountDueNow
            context.saveChanges()
            let outcome = try await DomainState.subscribed.runAsync {
                try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
            }
            #expect(outcome == .alreadyPaid(amountCents: 100_000))
            #expect(stripe.mints.count == 1, "no new link while Stripe's payment isn't recorded")
            #expect(invoice.stripePaymentLinkId == "plink_1" && invoice.stripePayLinkStatus == .paid)
            #expect(SendPreparer.currentPayLinkURL(for: invoice, business: profile) == nil, "a paid link is never sent")
        }
    }

    /// Once the payment is recorded (the paid prompt's Record payment), the next send mints only for
    /// what is still owed, under a fresh Stripe reference: the paid record stays paid, and the Worker,
    /// which never re-mints a paid reference, can make the new link.
    @Test func afterRecordingItMintsOnlyTheRemainingBalance() async throws {
        let (context, _, invoice) = try world()
        invoice.amountDueNow = 400          // a $400 deposit on a $1,000 invoice
        context.saveChanges()
        let stripe = FakeStripe()
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        let firstRef = invoice.stripeAppInvoiceId
        #expect(stripe.mints.first?.amountCents == 40_000)
        stripe.payStatus = "paid"
        stripe.amountPaidCents = 40_000
        #expect(!SendPreparer.payLinkIsRecorded(invoice))
        _ = try DomainState.subscribed.run {
            try InvoiceService.recordPayment(on: invoice, amount: 400, method: .stripe, stripeLinkId: "plink_1",
                                             origin: .screen, in: context)
        }
        #expect(SendPreparer.payLinkIsRecorded(invoice))

        let outcome = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(outcome == .ready)
        #expect(stripe.mints.count == 2 && stripe.mints[1].amountCents == 60_000, "only what is still owed")
        #expect(stripe.mints[1].supersedes == nil, "the paid link is not retired again")
        #expect(stripe.mintRefs[1] != firstRef && invoice.stripeAppInvoiceId == stripe.mintRefs[1],
                "a fresh reference, so the paid record stays paid")
        #expect(invoice.stripePaymentLinkId == "plink_2" && invoice.stripePayLinkStatus == .open)
        #expect(!context.hasChanges)
    }

    /// The payment can land between the status read and the mint: the Worker's 409 already_paid is the
    /// same answer, and since it retired nothing, the stored link is kept.
    @Test func workerAlreadyPaidIsTheSameAnswer() async throws {
        #expect(StripeBackendClient.error(forStatus: 409, body: Data(#"{"error":"already_paid","amountCents":25000,"paidAt":1}"#.utf8))
                == .alreadyPaid(amountCents: 25_000))
        let (context, _, invoice) = try world()
        let stripe = FakeStripe()
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        invoice.amountDueNow = 250
        context.saveChanges()
        stripe.payStatus = "open"
        stripe.mintError = .alreadyPaid(amountCents: 100_000)
        let outcome = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(outcome == .alreadyPaid(amountCents: 100_000))
        #expect(invoice.stripePaymentLinkId == "plink_1" && invoice.stripePayLinkStatus == .paid)
    }

    /// A lost binding (a revoked token, a claim that no longer holds) is fixed by reconnecting, never
    /// by retrying: whichever Stripe read hits it, the answer is "reconnect", not "try again later".
    @Test func aLostBindingSaysReconnectNotRetry() async throws {
        let lost: [StripeBackendError] = [.claimRejected, .http(401), .http(403), .accountMismatch]
        for error in lost {
            // The connect-status read refuses.
            let (context, _, invoice) = try world()
            let stripe = FakeStripe()
            stripe.connectStatusError = error
            let first = try await DomainState.subscribed.runAsync {
                try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
            }
            #expect(first == .deviceUnlinked, "\(error) on the status read")
            #expect(stripe.mints.isEmpty)

            // The pay-status read refuses, for an invoice that has been to Stripe before.
            stripe.connectStatusError = nil
            _ = try await DomainState.subscribed.runAsync {
                try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
            }
            #expect(stripe.mints.count == 1)
            stripe.payStatusError = error
            let second = try await DomainState.subscribed.runAsync {
                try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
            }
            #expect(second == .deviceUnlinked, "\(error) on the pay-status read")
            #expect(stripe.mints.count == 1, "nothing minted")
        }
        // Any other Stripe failure is still "try again".
        let (context, _, invoice) = try world()
        let stripe = FakeStripe()
        stripe.connectStatusError = .http(500)
        let other = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment(stripe))
        }
        #expect(other == .linkFailed)
    }

    // MARK: Description (audit 2026-10-03 F147)

    /// The Stripe pay page's line item follows the app language, like the invoice it pays.
    @Test func payLinkDescriptionFollowsTheAppLanguage() throws {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        let (_, _, invoice) = try world()
        invoice.jobTitle = "Cocina"
        MBLocalization.shared.language = .es
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Factura INV-0009 — Cocina")
        invoice.jobTitle = ""
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Factura INV-0009")
        invoice.number = ""
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Factura")
        MBLocalization.shared.language = .en
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Invoice")
    }

    @Test func payLinkDescriptionNamesTheInvoice() throws {
        let (_, _, invoice) = try world()
        invoice.jobTitle = "Kitchen"
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Invoice INV-0009 — Kitchen")
        invoice.jobTitle = " "
        #expect(SendPreparer.payLinkDescription(for: invoice) == "Invoice INV-0009")
    }
}
