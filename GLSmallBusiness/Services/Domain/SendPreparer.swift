//
//  SendPreparer.swift
//  GLSmallBusiness
//
//  Everything a send needs BEFORE the Mail / Messages / share sheet opens, for an estimate, an
//  invoice, a change order and a payment receipt: recipients, subject, bodies, attachments, and —
//  for an invoice — a current Stripe "Pay this invoice" link, minted or reused. No UI: the screens
//  (and later the assistant's `send` tool) present the compose sheets themselves, behind their own
//  `canSendMail` / `canSendText` guards, and a person always taps Send.
//
//  The pay-link rules moved here unchanged from InvoiceDetailScreen.prepareSend. Fail OPEN: any
//  problem means the invoice goes out without a Pay button, never that it doesn't go out.
//

import Foundation
import SwiftData

/// What one compose or share sheet is filled with.
struct ComposeContent {
    /// The customer's current email, falling back to the snapshot on the document.
    var emailRecipients: [String]
    /// The customer's current mobile, falling back to the snapshot.
    var textRecipients: [String]
    var subject: String
    var htmlBody: String
    var plainBody: String
    /// Mail: the document PDF.
    var pdfURL: URL?
    /// Mail: every other attachment (an invoice's photos and documents).
    var mailAttachments: [MailAttachment] = []
    /// Messages: every file, in the order the screen sends them.
    var messageAttachmentURLs: [URL]
    /// Share sheet: the files.
    var shareURLs: [URL]
    /// The pay link written into the invoice bodies, when there is a current one.
    var payLinkURL: String?
    /// This send's own temporary folder (an invoice's photos and documents), removed with
    /// `SendPreparer.discard` when the compose or share sheet closes. nil when nothing was written.
    var sendFolder: URL? = nil
}

/// The files one send writes: a fresh folder under tmp per send, so two sends never share a path
/// and closing the sheet removes exactly that send's files. Names are made safe and de-duplicated
/// ("Photo.jpg", "Photo 2.jpg") — every picked photo was once called "Photo", and each one was
/// written to tmp/Photo.jpg, so Messages and the share sheet got one photo several times (F13).
nonisolated enum SendFiles {
    static let folderPrefix = "send-"

    /// A new, empty folder for one send, or nil when it can't be made.
    static func makeFolder(in base: URL = FileManager.default.temporaryDirectory) -> URL? {
        let folder = base.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// Removes a send's folder and everything in it. Only ever a folder `makeFolder` made.
    static func discard(_ folder: URL?) {
        guard let folder, folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A stored name made safe to use as one file name: no path separators, no leading dots
    /// (never "..", never hidden), no control characters, not overlong. Empty → `fallback`.
    static func safeName(_ name: String, fallback: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return scalar
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let base = String((cleaned as NSString).deletingPathExtension.prefix(110))
            cleaned = ext.isEmpty ? base : base + "." + ext
        }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// `fileName`, or "Name 2.ext", "Name 3.ext"… when it is already taken (case-insensitively).
    static func unique(_ fileName: String, taken: Set<String>) -> String {
        guard taken.contains(fileName.lowercased()) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// One file each, in order, named safely and uniquely: what an invoice sends besides its PDF.
    struct Item {
        let fileName: String
        let data: Data
        let mimeType: String
    }

    /// Writes `items` into `folder`; the URLs of the files that were written.
    static func write(_ items: [Item], into folder: URL) -> [URL] {
        items.compactMap { item in
            let url = folder.appendingPathComponent(item.fileName, isDirectory: false)
            do {
                try item.data.write(to: url)
                return url
            } catch {
                return nil
            }
        }
    }
}

/// The Stripe calls a pay-link send makes — a seam so the rules can be tested without the network.
nonisolated protocol PayLinkBackend: Sendable {
    func connectStatus() async throws -> StripeConnectStatus
    func createPaymentLink(appInvoiceId: String, amountCents: Int, currency: String,
                           description: String, idempotencyKey: String,
                           supersedesLinkId: String?) async throws -> StripePayLinkResponse
    func payLinkStatus(appInvoiceId: String) async throws -> StripePayLinkStatusResponse
}

extension StripeBackendClient: PayLinkBackend {}

/// Where a pay-link send runs: the app's Stripe configuration, this device's link, and the backend.
nonisolated struct PayLinkEnvironment {
    var isConfigured: Bool
    /// The signed-in Gold Life ID holds a Stripe install token on this device (it was linked in Get
    /// Paid by Card).
    var deviceLinked: Bool
    var backend: any PayLinkBackend
    /// The Stripe account that token is bound to ("" = not known). nil only in test seams that don't
    /// model it; `.live` always sets it (audit 2026-10-03 F2).
    var linkedAccountId: String? = nil
    /// A pre-3.3.0 token is waiting to be proven for this account: the mint step settles it first.
    var legacyPending: Bool = false
    /// Runs right before a mint: settles a pending pre-3.3.0 token, then answers whether this device's
    /// token is bound to `accountId` under the same signed-in account. nil only in test seams.
    var confirmLink: (@Sendable (_ accountId: String) async -> Bool)? = nil

    static var live: PayLinkEnvironment { device(scope: StripeInstallTokenStore.signedInScope) }

    /// The environment for `scope`'s token (`service`, `isCurrent` and `legacyCheck` are injectable so
    /// a test runs the real rules without the Keychain's shared items or the network).
    static func device(scope: String?,
                       service: String = StripeInstallTokenStore.service,
                       isConfigured: Bool = StripeConfig.isConfigured,
                       backend: any PayLinkBackend = StripeBackendClient.shared,
                       isCurrent: @escaping @Sendable (String) -> Bool = { $0 == StripeInstallTokenStore.signedInScope },
                       legacyCheck: @escaping @Sendable (String, String) async -> StripeInstallTokenStore.LegacyCheck
                           = { token, expected in
                               await StripeBackendClient.shared.checkLegacyToken(token, expectedAccountId: expected)
                           }) -> PayLinkEnvironment {
        let entry = StripeInstallTokenStore.load(for: scope, service: service)
        let legacyPending = entry == nil && scope != nil && !StripeInstallTokenStore.readLegacy(service: service).isEmpty
        return PayLinkEnvironment(
            isConfigured: isConfigured,
            deviceLinked: entry != nil,
            backend: backend,
            linkedAccountId: entry?.boundAccountId ?? "",
            legacyPending: legacyPending,
            confirmLink: { accountId in
                _ = await StripeInstallTokenStore.migrateLegacy(scope: scope, profileAccountId: accountId,
                                                                service: service, isCurrent: isCurrent,
                                                                verify: legacyCheck)
                guard let scope, isCurrent(scope) else { return false }
                return StripeInstallTokenStore.load(for: scope, service: service)?.boundAccountId == accountId
            })
    }
}

/// How a send goes out, pay-link-wise.
enum PayLinkOutcome: Equatable {
    /// Send now — with the current link if the invoice carries one, else without (nothing to say).
    case ready
    /// This device isn't linked to Stripe for this business (no token for the signed-in Gold Life ID,
    /// or one bound to a different Stripe account): send without a Pay button, and say "reconnect".
    case deviceUnlinked
    /// The invoice wants a Pay button but the account can't take cards: send without one, and say so.
    case unavailable
    /// Stripe couldn't be reached or couldn't make the link (no signal, a server error): send without
    /// a Pay button, and say that — never that the account can't take cards (audit F81).
    case linkFailed
    /// The amount asked for is over what one pay link can charge (`StripeConfig.maxPayLinkCents`):
    /// ask whether to send without a Pay button (audit F81).
    case overLimit
    /// Stripe reports the invoice's link was already paid and no payment on the invoice records it
    /// yet: nothing was minted, and the owner is asked to record it first (audit F14).
    case alreadyPaid(amountCents: Int)
    /// The invoice was deleted while the link was being made: send nothing.
    case vanished
}

/// The first, instant decision: whether a network call is needed at all.
enum PayLinkPlan: Equatable {
    case decided(PayLinkOutcome)
    /// Ask Stripe, then mint or reuse a link, under this connected account.
    case mint(accountId: String)
}

@MainActor
enum SendPreparer {

    // MARK: Compose content

    static func estimate(_ estimate: Estimate, business: BusinessProfile?, pdfURL: URL?) -> ComposeContent {
        ComposeContent(
            emailRecipients: [estimate.recipientEmail],
            textRecipients: [estimate.recipientPhone],
            subject: EstimateMessage.subject(estimate: estimate, business: business),
            htmlBody: EstimateMessage.htmlBody(estimate: estimate, business: business),
            plainBody: EstimateMessage.plainBody(estimate: estimate, business: business),
            pdfURL: pdfURL,
            // Logo first (renders as an inline image), then the estimate PDF.
            messageAttachmentURLs: [EstimateMessage.logoAttachmentURL(business: business), pdfURL].compactMap { $0 },
            shareURLs: [pdfURL].compactMap { $0 })
    }

    /// The invoice's PDF plus its photos and documents; the bodies carry the current pay link only
    /// (`currentPayLinkURL` — this never mints; `mintPayLink` does, before the sheet opens).
    /// Writes the photos and documents into a new folder of their own, so build it when the person
    /// taps Email, Text or Share — never while a screen draws — and `discard` it when the sheet closes.
    static func invoice(_ invoice: Invoice, business: BusinessProfile?, pdfURL: URL?) -> ComposeContent {
        let payURL = currentPayLinkURL(for: invoice, business: business)
        let files = invoiceFiles(invoice, pdfURL: pdfURL)
        return ComposeContent(
            emailRecipients: [invoice.recipientEmail],
            textRecipients: [invoice.recipientPhone],
            subject: InvoiceMessage.subject(invoice: invoice, business: business),
            htmlBody: InvoiceMessage.htmlBody(invoice: invoice, business: business, payLinkURL: payURL),
            plainBody: InvoiceMessage.plainBody(invoice: invoice, business: business, payLinkURL: payURL),
            pdfURL: pdfURL,
            mailAttachments: invoiceMailAttachments(invoice),
            messageAttachmentURLs: ([EstimateMessage.logoAttachmentURL(business: business)] + files.urls).compactMap { $0 },
            shareURLs: files.urls,
            payLinkURL: payURL,
            sendFolder: files.folder)
    }

    /// Sent to the change order's customer.
    static func changeOrder(_ changeOrder: ChangeOrder, business: BusinessProfile?, pdfURL: URL?) -> ComposeContent {
        ComposeContent(
            emailRecipients: [changeOrder.recipientEmail],
            textRecipients: [changeOrder.recipientPhone],
            subject: ChangeOrderMessage.subject(changeOrder, business: business),
            htmlBody: ChangeOrderMessage.htmlBody(changeOrder, business: business),
            plainBody: ChangeOrderMessage.plainBody(changeOrder, business: business),
            pdfURL: pdfURL,
            messageAttachmentURLs: [pdfURL].compactMap { $0 },
            shareURLs: [pdfURL].compactMap { $0 })
    }

    /// Sent to the contract's customer with the contract PDF attached.
    static func contract(_ contract: Contract, business: BusinessProfile?, pdfURL: URL?) -> ComposeContent {
        ComposeContent(
            emailRecipients: [contract.recipientEmail],
            textRecipients: [contract.recipientPhone],
            subject: ContractMessage.subject(contract, business: business),
            htmlBody: ContractMessage.htmlBody(contract: contract, business: business),
            plainBody: ContractMessage.plainBody(contract: contract, business: business),
            pdfURL: pdfURL,
            messageAttachmentURLs: [EstimateMessage.logoAttachmentURL(business: business), pdfURL].compactMap { $0 },
            shareURLs: [pdfURL].compactMap { $0 })
    }

    static func paymentReceipt(_ invoice: Invoice, payment: InvoicePayment, business: BusinessProfile?,
                               pdfURL: URL?) -> ComposeContent {
        ComposeContent(
            emailRecipients: [invoice.recipientEmail],
            textRecipients: [invoice.recipientPhone],
            subject: PaymentReceiptMessage.subject(invoice: invoice, business: business),
            htmlBody: PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: business),
            plainBody: PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: business),
            pdfURL: pdfURL,
            messageAttachmentURLs: [pdfURL].compactMap { $0 },
            shareURLs: [pdfURL].compactMap { $0 })
    }

    // MARK: Invoice attachments

    /// Removes the temporary files a send wrote (its own folder only; the PDF stays).
    static func discard(_ content: ComposeContent?) {
        SendFiles.discard(content?.sendFolder)
    }

    /// The invoice PDF, then its photos and documents written into a new folder for this send
    /// (Messages and the share sheet take files, not data). `folder` is nil when nothing was written.
    static func invoiceFiles(_ invoice: Invoice, pdfURL: URL?) -> (urls: [URL], folder: URL?) {
        let items = invoiceAttachmentItems(invoice)
        var urls: [URL] = []
        if let pdfURL { urls.append(pdfURL) }
        guard !items.isEmpty, let folder = SendFiles.makeFolder() else { return (urls, nil) }
        urls += SendFiles.write(items, into: folder)
        return (urls, folder)
    }

    /// The invoice's photos and documents as Mail attachments (the PDF goes separately), named
    /// exactly as the files Messages and the share sheet get.
    static func invoiceMailAttachments(_ invoice: Invoice) -> [MailAttachment] {
        invoiceAttachmentItems(invoice).map { MailAttachment(data: $0.data, mimeType: $0.mimeType, fileName: $0.fileName) }
    }

    /// Photos, then documents, each with a safe file name no other attachment on this send has.
    static func invoiceAttachmentItems(_ invoice: Invoice) -> [SendFiles.Item] {
        var taken: Set<String> = []
        var items: [SendFiles.Item] = []
        func add(_ fileName: String, _ data: Data, _ mime: String) {
            let name = SendFiles.unique(fileName, taken: taken)
            taken.insert(name.lowercased())
            items.append(SendFiles.Item(fileName: name, data: data, mimeType: mime))
        }
        for photo in invoice.photos {
            guard let data = photo.data else { continue }
            let name = SendFiles.safeName(photo.name, fallback: "Photo")
            let lower = name.lowercased()
            add(lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ? name : "\(name).jpg", data, "image/jpeg")
        }
        for doc in invoice.documents {
            guard let data = doc.data else { continue }
            let name = SendFiles.safeName(doc.name, fallback: "Document.pdf")
            let lower = name.lowercased()
            let isImage = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
            add(name, data, isImage ? "image/jpeg" : "application/pdf")
        }
        return items
    }

    // MARK: Pay link

    /// The pay link to embed in THIS send, or nil. Only when the invoice is set to carry a link, the
    /// stored link was minted under the account the business is connected to NOW, it matches the
    /// current amount, and it hasn't been paid — a stale, foreign or turned-off link is never sent.
    static func currentPayLinkURL(for invoice: Invoice, business: BusinessProfile?) -> String? {
        guard invoice.shouldIncludePayLink(business) else { return nil }
        let amountCents = DomainMoney.wholeCents(invoice.currentAmountDue)
        guard !invoice.stripePaymentLinkAccountId.isEmpty,
              invoice.stripePaymentLinkAccountId == business?.stripeConnectedAccountId else { return nil }
        guard !invoice.stripePaymentLinkURL.isEmpty,
              invoice.stripePaymentLinkAmountCents == amountCents,
              invoice.stripePayLinkStatus != .paid else { return nil }
        return invoice.stripePaymentLinkURL
    }

    /// True once a recorded payment carries this invoice's current pay-link id — the reconciliation guard.
    /// Gating on this (instead of the display-status cache) means a deferred/dismissed "Record payment?"
    /// prompt re-fires on the next open, and a once-recorded link never re-prompts or double-counts.
    /// The invoice screen's pay-status poll and the send's paid check (`mintPayLink`) both read it.
    static func payLinkIsRecorded(_ invoice: Invoice) -> Bool {
        let linkId = invoice.stripePaymentLinkId
        guard !linkId.isEmpty else { return false }
        let payments = invoice.liveRows(invoice.payments)
        // Primary gate: a payment stamped with this link id (the in-app Stripe-prompt path).
        if payments.contains(where: { $0.stripePaymentLinkId == linkId }) { return true }
        // Fallback: the owner recorded the Stripe payment by hand via the normal "Record payment"
        // menu, so it carries NO link id. Treat an UNSTAMPED card-method payment for this link's exact
        // amount as the same reconciliation — otherwise a deposit/milestone link (paid in full at
        // Stripe but leaving the invoice's balance > 0) would re-fire the "record it?" prompt.
        // Only unstamped (empty link id) payments count: a payment already attributed to a PRIOR link
        // must never satisfy THIS link, or a second milestone of the same dollar amount would be
        // silently treated as already-recorded and its payment dropped. For the same reason, an
        // unstamped payment only counts when it was recorded on/after the day THIS link was minted —
        // a hand-recorded payment from a prior same-amount milestone must not swallow this one. When
        // in doubt (legacy link, no mint date) we err toward RE-PROMPTING (the prompt is dismissible)
        // over silently dropping a real payment.
        let linkCents = invoice.stripePaymentLinkAmountCents
        guard linkCents > 0 else { return false }
        let mintedFloor = invoice.stripePaymentLinkMintedAt.map { Calendar.current.startOfDay(for: $0) }
        return payments.contains { payment in
            payment.method.couldSettleStripeLink
                && payment.stripePaymentLinkId.isEmpty
                && DomainMoney.wholeCents(payment.amount) == linkCents
                && (mintedFloor.map { payment.date >= $0 } ?? true)   // nil = legacy link minted pre-stamping
        }
    }

    /// A short, customer-facing label for the Stripe line item (the only invoice text Stripe sees).
    static func payLinkDescription(for invoice: Invoice) -> String {
        let number = invoice.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = invoice.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // In the app's language, like the invoice it pays (audit F147).
        switch (number.isEmpty, job.isEmpty) {
        case (false, false): return mbLoc("Invoice \(number) — \(job)")
        case (false, true): return mbLoc("Invoice \(number)")
        case (true, false): return job
        case (true, true): return mbLoc("Invoice")
        }
    }

    /// Whether this send needs Stripe at all, decided without the network.
    static func payLinkPlan(for invoice: Invoice, business: BusinessProfile?,
                            environment: PayLinkEnvironment = .live) -> PayLinkPlan {
        guard environment.isConfigured,
              let accountId = business?.stripeConnectedAccountId, !accountId.isEmpty else {
            return .decided(.ready)
        }
        guard invoice.shouldIncludePayLink(business) else {
            // The invoice WANTS a Pay button but the connected account can't charge (the synced
            // "charges enabled" flag is off) — say so rather than let the button vanish silently.
            return .decided(invoice.includePayLink ? .unavailable : .ready)
        }
        // Over what one pay link can charge: the true reason, whatever this device's link (F81).
        if DomainMoney.wholeCents(invoice.currentAmountDue) > StripeConfig.maxPayLinkCents {
            return .decided(.overLimit)
        }
        // A pre-3.3.0 token is settled (moved, deleted, or kept for later) by the mint step, which then decides.
        if environment.legacyPending { return .mint(accountId: accountId) }
        // Connected business, but THIS device holds no install token: minting would only fail.
        guard environment.deviceLinked else { return .decided(.deviceUnlinked) }
        // The token is bound to a different Stripe account than the one this business names (another
        // Gold Life ID's, or an old binding): minting would put this customer's money in that account
        // (audit 2026-10-03 F2). Send without a Pay button and say "reconnect".
        if let linked = environment.linkedAccountId, linked != accountId { return .decided(.deviceUnlinked) }
        return .mint(accountId: accountId)
    }

    /// Asks Stripe whether the account can charge and whether this invoice's link was already paid,
    /// then reuses the stored link (same account, same amount, not paid) or mints a new one that
    /// retires it, and stores the link on the invoice. A paid link is never re-minted (audit F14):
    /// until a payment on the invoice records it, the answer is `.alreadyPaid` and nothing is minted;
    /// once one does, the new link asks only for what is still owed, under a fresh Stripe reference.
    /// Throws only the write gates (read-only, or the invoice already gone); everything Stripe-side
    /// fails open (the invoice goes out without a Pay button, and the outcome says why).
    static func mintPayLink(for invoice: Invoice, accountId: String, in context: ModelContext,
                            environment: PayLinkEnvironment = .live,
                            subscription: SubscriptionManager? = nil) async throws -> PayLinkOutcome {
        try DomainGate.requireWritable(.mintPayLink, subscription)
        try DomainGate.requireLive(invoice, .mintPayLink)
        // The last word before any Stripe call: this device's token must be bound to THIS business's
        // account (F2). Checked again here, after any await, so nothing mints into another account.
        if let confirmLink = environment.confirmLink, !(await confirmLink(accountId)) {
            return isLive(invoice) ? .deviceUnlinked : .vanished
        }
        // Hoisted out of the `do` so the catch knows whether the backend already retired the
        // stored link on our behalf.
        var retiredPriorLink = false
        do {
            // Authoritative gate (not the possibly-stale synced flag): can the account still charge?
            let status = try await environment.backend.connectStatus()
            // The invoice can be cascade-deleted from another device mid-flight.
            guard isLive(invoice) else { return .vanished }
            // The amount the invoice, PDF and email show, in whole cents (law 60) — never the binary
            // value × 100, which could charge a cent the customer was not shown.
            let amountCents = DomainMoney.wholeCents(invoice.currentAmountDue)
            // A $0 invoice has nothing to pay, so a missing Pay button isn't worth a notice.
            guard amountCents > 0 else { return .ready }
            guard amountCents <= StripeConfig.maxPayLinkCents else { return .overLimit }
            guard status.canCharge else { return .unavailable }

            // Was this invoice's link already paid? Only an invoice that has been to Stripe before can be.
            let hadReference = !invoice.stripeAppInvoiceId.isEmpty
            var ref = invoice.ensureStripeAppInvoiceId()
            if hadReference {
                let pay = try await environment.backend.payLinkStatus(appInvoiceId: ref)
                guard isLive(invoice) else { return .vanished }
                if pay.isPaid {
                    if payLinkIsRecorded(invoice) {
                        // The payment is on the invoice. The Worker never re-mints a paid reference
                        // (it is the record of that payment), so what is still owed gets a fresh one;
                        // the paid link is already off at Stripe, so there is nothing to retire.
                        invoice.clearStripePayLink()
                        invoice.stripeAppInvoiceId = ""
                        ref = invoice.ensureStripeAppInvoiceId()
                    } else {
                        // Not recorded yet ("Not now", or a poll that never ran): mint nothing, and
                        // hand back what Stripe collected so the owner can record it first.
                        invoice.stripePayLinkStatus = .paid
                        context.saveChanges()
                        return .alreadyPaid(amountCents: pay.amountPaidCents ?? invoice.stripePaymentLinkAmountCents)
                    }
                }
            }
            // Reuse the stored link when it belongs to THIS connected account, the amount is
            // unchanged, and it isn't already paid. An unstamped or foreign link falls through to a
            // fresh mint, which stamps it.
            if !invoice.stripePaymentLinkId.isEmpty,
               invoice.stripePaymentLinkAccountId == accountId,
               invoice.stripePaymentLinkAmountCents == amountCents,
               invoice.stripePayLinkStatus != .paid {
                context.saveChanges()
                return .ready
            }
            // Amount changed (or first send): mint a new link, retiring any prior one. A fresh mint
            // count makes the idempotency key unique, so returning to an earlier amount can't replay
            // (and re-embed) an already-deactivated link.
            let prior = invoice.stripePaymentLinkId.isEmpty ? nil : invoice.stripePaymentLinkId
            retiredPriorLink = prior != nil
            invoice.stripePayLinkMintCount += 1
            let link = try await environment.backend.createPaymentLink(
                appInvoiceId: ref,
                amountCents: amountCents,
                currency: "usd",
                description: payLinkDescription(for: invoice),
                idempotencyKey: "\(accountId)-\(ref)-\(amountCents)-\(invoice.stripePayLinkMintCount)",
                supersedesLinkId: prior)
            guard isLive(invoice) else { return .vanished }
            invoice.stripePaymentLinkId = link.paymentLinkId
            invoice.stripePaymentLinkURL = link.url
            invoice.stripePaymentLinkAccountId = accountId
            invoice.stripePaymentLinkAmountCents = amountCents
            invoice.stripePaymentLinkMintedAt = .now
            invoice.stripePayLinkStatus = .open
            context.saveChanges()
            return .ready
        } catch StripeBackendError.amountTooLarge {
            // The Worker refused before retiring anything: the stored link stands (F81).
            guard isLive(invoice) else { return .vanished }
            context.saveChanges()
            return .overLimit
        } catch StripeBackendError.alreadyPaid(let paidCents) {
            // The payment landed between the status read and the mint. The Worker retired and minted
            // nothing, so the stored link (the paid one) stands (F14).
            guard isLive(invoice) else { return .vanished }
            invoice.stripePayLinkStatus = .paid
            context.saveChanges()
            return .alreadyPaid(amountCents: paidCents ?? invoice.stripePaymentLinkAmountCents)
        } catch let error as StripeBackendError where error.isBindingLost {
            // A revoked token or a claim that no longer holds (401/403, invalid_claim, account_mismatch)
            // on any of the Stripe calls: only reconnecting fixes it, so say "reconnect", not "try again".
            guard isLive(invoice) else { return .vanished }
            if retiredPriorLink { invoice.clearStripePayLink() }
            context.saveChanges()
            return .deviceUnlinked
        } catch {
            guard isLive(invoice) else { return .vanished }
            // The backend deactivates the prior link BEFORE it creates the new one, so a mint that
            // got that far leaves us pointing at a link Stripe has already killed. Forget it, or a
            // later send at the same amount would take the reuse branch and embed a dead link.
            if retiredPriorLink { invoice.clearStripePayLink() }
            context.saveChanges()
            return .linkFailed
        }
    }

    private static func isLive(_ model: any PersistentModel) -> Bool {
        model.modelContext != nil && !model.isDeleted
    }
}
