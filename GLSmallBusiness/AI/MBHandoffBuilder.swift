//
//  MBHandoffBuilder.swift
//  GLSmallBusiness — AI
//
//  Turns a `.handoff` payload into the exact piece of UI the presenter shows — reusing the app's
//  own builders: `SendPreparer` for every compose sheet's content, the PDF renderers for the
//  documents, `ContractorPackagePDF` / `CompletionPackagePDF` for the packages, `W9PDF` and
//  `Form1099NECPDF` for the tax forms, and `StatsExport` / `EmployeePayExport` / `SubPayExport`
//  for the year-end files.
//
//  Every refusal is decided HERE, before anything is shown (law 45, law 4): no mail account, no
//  recipient, an incomplete business profile, a document that wouldn't render, a Face ID that
//  didn't pass. The model gets the reason and a way forward; the person gets a "Not done" row.
//

import Foundation
import SwiftData
import Contacts
import MessageUI
import UIKit
import VisionKit
import GoldLifeAI
import GoldLifeUI

@MainActor
enum MBHandoffBuilder {

    // MARK: - send

    static func send(_ handoff: GLAIHandoff, env: MBToolEnvironment) async -> MBHandoffStep<MBHandoffUI> {
        guard let store = env.context() else { return .answer(.failed(MBHandoffFailure.notAvailable)) }
        let args = MBArguments(json: handoff.payload)
        guard let documentRaw = args.string("document"), let document = MBSendDocument(rawValue: documentRaw),
              let channelRaw = args.string("channel"), let channel = MBSendChannel(rawValue: channelRaw),
              let id = args.string("id") else {
            return .answer(.failed(MBHandoffFailure.notAvailable))
        }
        let business = MBRecordLookup.businessProfile(in: store)
        // Law 45: nothing goes to a customer under a half-built business.
        guard business?.isComplete == true else {
            return .answer(.failed(MBHandoffFailure.profileIncomplete))
        }

        var content: ComposeContent
        var record: GLAIRecordRef?
        var title: LocalizedStringResource
        var detail: String?

        switch document {
        case .estimate:
            guard let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            guard let pdf = EstimatePDF.render(estimate, business: business) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            content = SendPreparer.estimate(estimate, business: business, pdfURL: pdf)
            record = MBWrite.ref(.estimate, id)
            title = MBWriteStrings.sentEstimate
            detail = estimate.number
        case .invoice:
            guard let invoice = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            // The pay link is minted (or reused) before the sheet opens — fail OPEN, exactly as the
            // invoice screen does: any problem sends without a Pay button, never not at all.
            if case .mint(let accountId) = SendPreparer.payLinkPlan(for: invoice, business: business) {
                _ = try? await SendPreparer.mintPayLink(for: invoice, accountId: accountId, in: store,
                                                        subscription: env.subscription())
            }
            guard let live = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store),
                  let pdf = InvoicePDF.render(live, business: business) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            content = SendPreparer.invoice(live, business: business, pdfURL: pdf)
            record = MBWrite.ref(.invoice, id)
            title = MBWriteStrings.sentInvoice
            detail = live.number
        case .changeOrder:
            guard let order = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            guard let pdf = ChangeOrderPDF.render(order, business: business) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            content = SendPreparer.changeOrder(order, business: business, pdfURL: pdf)
            record = MBWrite.ref(.changeOrder, id)
            title = MBWriteStrings.sentChangeOrder
            detail = order.number
        case .paymentReceipt:
            guard let payment = MBRecordLookup.record(.payment, id: id, as: InvoicePayment.self, in: store),
                  let invoice = payment.invoice else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            guard let pdf = PaymentReceiptPDF.render(invoice, payment: payment, business: business) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            content = SendPreparer.paymentReceipt(invoice, payment: payment, business: business, pdfURL: pdf)
            record = MBWrite.ref(.payment, id)
            title = MBWriteStrings.sentReceipt
            detail = invoice.number
        case .completionPackage:
            guard let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            // Building a document is the app doing work: a read-only app doesn't.
            guard !ReadOnlyGate.isReadOnly(env.subscription()) else {
                return .answer(.failed(MBHandoffFailure.readOnly(env)))
            }
            guard let pdf = CompletionPackagePDF.render(job: job, business: business) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            content = ComposeContent(
                emailRecipients: [job.customer?.email ?? ""],
                textRecipients: [job.customer?.phoneNumber ?? ""],
                subject: CompletionPackageMessage.subject(job: job, business: business),
                htmlBody: CompletionPackageMessage.body(job: job, business: business),
                plainBody: CompletionPackageMessage.body(job: job, business: business),
                pdfURL: pdf,
                messageAttachmentURLs: [pdf],
                shareURLs: [pdf])
            record = MBWrite.ref(.job, id)
            title = MBWriteStrings.sentPackage
            detail = job.displayTitle
        case .contractorPackage:
            guard let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store),
                  let profile = business else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            guard !ReadOnlyGate.isReadOnly(env.subscription()) else {
                return .answer(.failed(MBHandoffFailure.readOnly(env)))
            }
            switch await packageURL(customer, profile: profile, parts: args.strings("package_parts"),
                                    env: env) {
            case .answer(let outcome): return .answer(outcome)
            case .value(let pdf):
                content = ComposeContent(
                    emailRecipients: [customer.email],
                    textRecipients: [customer.phoneNumber],
                    subject: ContractorPackageMessage.subject(business: profile),
                    htmlBody: ContractorPackageMessage.htmlBody(business: profile),
                    plainBody: ContractorPackageMessage.body(business: profile),
                    pdfURL: pdf,
                    messageAttachmentURLs: [pdf],
                    shareURLs: [pdf])
                record = MBWrite.ref(.customer, id)
                title = MBWriteStrings.sentPackage
                detail = customer.listDisplayName
            }
        case .reviewRequest:
            guard let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store),
                  let profile = business else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            content = ComposeContent(
                emailRecipients: [customer.email],
                textRecipients: [customer.phoneNumber],
                subject: ReviewRequestMessage.subject(business: profile),
                htmlBody: ReviewRequestMessage.htmlBody(business: profile),
                plainBody: ReviewRequestMessage.plainBody(business: profile),
                pdfURL: nil,
                messageAttachmentURLs: [],
                shareURLs: [])
            record = MBWrite.ref(.customer, id)
            title = MBWriteStrings.sentReviewRequest
            detail = customer.listDisplayName
        }

        // The model may name other recipients INSTEAD of the customer's own ("send it to her
        // office manager, not her") — the manifest's own wording, and what this does: it replaces
        // both lists. The composer still shows every address before anything goes.
        let override = args.strings("recipients")
        if !override.isEmpty {
            content.emailRecipients = override
            content.textRecipients = override
        }

        switch channel {
        case .share:
            let urls = content.shareURLs
            guard !urls.isEmpty else { return .answer(.failed(MBHandoffFailure.documentFailed)) }
            return .value(.share(urls: urls,
                                   activity: GLAIActivity(kind: .sent, symbol: MBWriteSymbol.sent,
                                                          title: title, detail: detail, record: record)))
        case .email:
            guard MFMailComposeViewController.canSendMail() else {
                return .answer(.failed(MBHandoffFailure.noMail))
            }
            let recipients = content.emailRecipients.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !recipients.isEmpty else { return .answer(.failed(MBHandoffFailure.noRecipient)) }
            return .value(.mail(MBComposeContent(
                recipients: recipients, subject: content.subject, body: content.htmlBody, isHTML: true,
                preferredSendingEmail: business?.email, attachmentURL: content.pdfURL,
                extraAttachments: content.mailAttachments, record: record,
                activityTitle: title, activityDetail: detail, channel: "email")))
        case .text:
            guard MFMessageComposeViewController.canSendText() else {
                return .answer(.failed(MBHandoffFailure.noMessages))
            }
            let recipients = content.textRecipients.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !recipients.isEmpty else { return .answer(.failed(MBHandoffFailure.noRecipient)) }
            return .value(.message(MBComposeContent(
                recipients: recipients, subject: content.subject, body: content.plainBody, isHTML: false,
                preferredSendingEmail: nil, attachmentURL: nil,
                messageAttachmentURLs: content.messageAttachmentURLs, record: record,
                activityTitle: title, activityDetail: detail, channel: "text")))
        }
    }

    /// The contractor package, merged the way the Contractor Package sheet merges it. The W-9 (and
    /// its signature) print a full Tax ID, so they only go in after Face ID.
    private static func packageURL(_ customer: Customer, profile: BusinessProfile,
                                   parts: [String], env: MBToolEnvironment) async -> MBHandoffStep<URL> {
        guard let coi = customer.coiData else {
            return .answer(.failed(GLAIFailure(
                reason: "no_certificate",
                message: "This customer has no certificate of insurance on file, and the package is built around it. Offer pick_media with target customer_coi.",
                personReason: MBWriteStrings.packageNeedsCOI)))
        }
        // Default: everything on file except the W-9, which is opt-in (the sheet's own default is
        // the W-9 when it is complete; through the assistant the tax form is always asked for).
        let wanted = parts.isEmpty
            ? Set(["wc_certificate", "wc_exemption", "license", "extra_documents"])
            : Set(parts)
        var sources: [Data] = [coi]
        if wanted.contains("w9") {
            guard profile.w9IsComplete else {
                return .answer(.failed(GLAIFailure(
                    reason: "w9_incomplete",
                    message: "The W-9 details aren't filled in yet. Offer to open the business details so the person can finish them.",
                    personReason: MBWriteStrings.w9Incomplete)))
            }
            guard await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to include your W-9.")) else {
                return .answer(.failed(MBHandoffFailure.faceIDRefused))
            }
            // The signature is a second door: its own Face ID prompt and its own saved image,
            // exactly as the Contractor Package sheet's Sign toggle does it.
            var signature: UIImage?
            if wanted.contains("w9_signature") {
                switch await signatureImage(env: env) {
                case .answer(let outcome): return .answer(outcome)
                case .value(let image): signature = image
                }
            }
            if let url = W9PDF.render(profile, signatureImage: signature,
                                      signedDate: signature == nil ? nil : Date()),
               let data = try? Data(contentsOf: url) {
                sources.append(data)
            }
        } else if wanted.contains("w9_signature") {
            return .answer(.failed(GLAIFailure(
                reason: "invalid_arguments",
                message: "w9_signature only signs the W-9, so ask for w9 too.",
                personReason: MBWriteStrings.w9Incomplete, showsToPerson: false)))
        }
        if wanted.contains("wc_certificate"), let data = customer.wcCoiData { sources.append(data) }
        if wanted.contains("wc_exemption"), let data = profile.wcExemptionData { sources.append(data) }
        if wanted.contains("license"), let data = profile.licenseDocumentData { sources.append(data) }
        if wanted.contains("extra_documents") {
            sources.append(contentsOf: customer.sortedPackageDocuments.compactMap(\.data))
        }
        let safeName = customer.listDisplayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "Contractor-Package\(safeName.isEmpty ? "" : "-\(safeName)").pdf"
        guard let url = ContractorPackagePDF.merge(sources, fileName: fileName) else {
            return .answer(.failed(MBHandoffFailure.documentFailed))
        }
        return .value(url)
    }

    /// A stored document's name, made safe to hang off a directory: no path separators, no
    /// leading dots, nothing empty. (`SendPreparer` and `CompliancePDF.tempURL` share the shape.)
    static func safeFileName(_ name: String, fallback: String) -> String {
        SharedTempFiles.safeName(name, fallback: fallback)
    }

    /// The person's saved signature, behind its own Face ID prompt — the same two steps the
    /// Contractor Package sheet's Sign toggle takes (`enableSignature()`). The image never leaves
    /// this builder: it is drawn into the PDF and nothing about it is ever serialized for the
    /// model (contract §5 quarantine).
    private static func signatureImage(env: MBToolEnvironment) async -> MBHandoffStep<UIImage?> {
        guard env.context() != nil else { return .answer(.failed(MBHandoffFailure.notAvailable)) }
        guard let data = MBIdentity.shared.signatureData,
              let image = UIImage(data: data) else {
            return .answer(.failed(GLAIFailure(
                reason: "no_signature",
                message: "There's no saved signature yet. Offer to send the package without signing the W-9, or to open the customer so they can draw one.",
                personReason: MBWriteStrings.signatureNotSaved)))
        }
        guard await BiometricGate.authenticateInSession(
            reason: mbLoc("Unlock your saved signature to sign the W-9.")) else {
            return .answer(.failed(MBHandoffFailure.faceIDRefused))
        }
        return .value(image)
    }

    // MARK: - share_document

    static func share(_ handoff: GLAIHandoff, env: MBToolEnvironment) async -> MBHandoffStep<MBHandoffUI> {
        guard let store = env.context() else { return .answer(.failed(MBHandoffFailure.notAvailable)) }
        let args = MBArguments(json: handoff.payload)
        guard let raw = args.string("document"), let document = MBShareDocument(rawValue: raw) else {
            return .answer(.failed(MBHandoffFailure.notAvailable))
        }
        let id = args.string("id")
        let year = args.int("year") ?? env.calendar.component(.year, from: env.now())
        let business = MBRecordLookup.businessProfile(in: store)
        let activity = GLAIActivity(kind: .sent, symbol: MBWriteSymbol.document,
                                    title: MBWriteStrings.sharedDocument,
                                    detail: MBShareLabel.label(document), record: handoff.record)

        func files(_ urls: [URL]) -> MBHandoffStep<MBHandoffUI> {
            guard !urls.isEmpty else { return .answer(.failed(MBHandoffFailure.documentFailed)) }
            return .value(.share(urls: urls, activity: activity))
        }

        func stored(_ data: Data?, _ name: String, _ fallback: String) -> MBHandoffStep<MBHandoffUI> {
            guard let data else {
                return .answer(.failed(GLAIFailure(
                    reason: "not_on_file",
                    message: "There's nothing on file for that. Offer pick_media to add it.",
                    personReason: MBWriteStrings.documentNotOnFile)))
            }
            // The name is the person's own text on a stored document. Sanitized all the same, so
            // a "../" in it can never write outside the temp folder.
            guard let url = SharedTempFiles.write(data, named: name, fallback: fallback) else {
                return .answer(.failed(MBHandoffFailure.documentFailed))
            }
            return files([url])
        }

        switch document {
        case .w9:
            guard let profile = business, profile.w9IsComplete else {
                return .answer(.failed(GLAIFailure(
                    reason: "w9_incomplete",
                    message: "The W-9 details aren't filled in yet. Offer to open the business details.",
                    personReason: MBWriteStrings.w9Incomplete)))
            }
            guard await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to generate your W-9.")) else {
                return .answer(.failed(MBHandoffFailure.faceIDRefused))
            }
            return files([W9PDF.render(profile)].compactMap { $0 })
        case .form1099NEC:
            guard let id, let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store),
                  let profile = business else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            guard await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to generate this 1099-NEC.")) else {
                return .answer(.failed(MBHandoffFailure.faceIDRefused))
            }
            let amount = sub.totalPaid(year: year)
            return files([Form1099NECPDF.render(payer: profile, recipient: sub, amount: amount, year: year)]
                .compactMap { $0 })
        case .subcontractor1099Report:
            // Carries EVERY subcontractor's Tax ID off the device — the one in-session export the
            // owner kept a hard Face ID prompt on (SubcontractorsScreen's year-end export). Asking
            // for it is the same export as tapping for it, so it wears the same prompt.
            guard await BiometricGate.authenticate(reason: mbLoc("Unlock to export the year-end report.")) else {
                return .answer(.failed(MBHandoffFailure.faceIDRefused))
            }
            return files(SubPayExport.files(subcontractors: MBRecordLookup.all(Subcontractor.self, in: store),
                                            year: year, business: business))
        case .wageReport:
            return files(EmployeePayExport.files(employees: MBRecordLookup.all(Employee.self, in: store),
                                                 year: year, business: business))
        case .yearEndReport:
            return files(StatsExport.files(period: .year(year),
                                           invoices: MBRecordLookup.all(Invoice.self, in: store),
                                           estimates: MBRecordLookup.all(Estimate.self, in: store),
                                           receipts: MBRecordLookup.all(Receipt.self, in: store),
                                           business: business))
        case .complianceDocs:
            var urls: [URL] = []
            for (data, name, fallback) in [
                (business?.wcExemptionData, business?.wcExemptionName ?? "", "Workers-Comp-Exemption.pdf"),
                (business?.licenseDocumentData, business?.licenseDocumentName ?? "", "Contractor-License.pdf"),
                (business?.ownerReferenceCOIData, business?.ownerReferenceCOIName ?? "", "Reference-COI.pdf"),
            ] {
                guard let data else { continue }
                // Named by the person's own text: sanitized, protected, and a failed write is an
                // honest failure, never a share that quietly leaves a document out.
                guard let url = SharedTempFiles.write(data, named: name, fallback: fallback) else {
                    SharedTempFiles.remove(urls)
                    return .answer(.failed(MBHandoffFailure.documentFailed))
                }
                urls.append(url)
            }
            return files(urls)
        case .wcExemption:
            return stored(business?.wcExemptionData, business?.wcExemptionName ?? "", "Workers-Comp-Exemption.pdf")
        case .license:
            return stored(business?.licenseDocumentData, business?.licenseDocumentName ?? "", "Contractor-License.pdf")
        case .referenceCOI:
            return stored(business?.ownerReferenceCOIData, business?.ownerReferenceCOIName ?? "", "Reference-COI.pdf")
        case .customerCOI, .customerWCCOI:
            guard let id, let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return document == .customerCOI
                ? stored(customer.coiData, customer.coiName, "Certificate-of-Insurance.pdf")
                : stored(customer.wcCoiData, customer.wcCoiName, "Workers-Comp-Certificate.pdf")
        case .subcontractorCOI:
            guard let id, let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return stored(sub.coiData, sub.coiName, "Certificate-of-Insurance.pdf")
        case .subcontractorW9:
            // Tax class: only the subcontractor's own screen shows it, behind Face ID.
            return .answer(.failed(MBHandoffFailure.onlyOnScreen))
        case .packageDocument:
            guard let id, let doc = MBRecordLookup.record(.document, id: id, as: CustomerDocument.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return stored(doc.data, doc.name, "Document.pdf")
        case .jobDocument, .invoiceDocument:
            guard let id, let attachment = MBRecordLookup.record(.attachment, id: id, as: JobAttachment.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return stored(attachment.data, attachment.name, "Document.pdf")
        case .estimatePDF:
            guard let id, let estimate = MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return files([EstimatePDF.render(estimate, business: business)].compactMap { $0 })
        case .invoicePDF:
            guard let id, let invoice = MBRecordLookup.record(.invoice, id: id, as: Invoice.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return files([InvoicePDF.render(invoice, business: business)].compactMap { $0 })
        case .changeOrderPDF:
            guard let id, let order = MBRecordLookup.record(.changeOrder, id: id, as: ChangeOrder.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return files([ChangeOrderPDF.render(order, business: business)].compactMap { $0 })
        }
    }

    // MARK: - pick_media

    static func pick(_ handoff: GLAIHandoff, env: MBToolEnvironment) async -> MBHandoffStep<MBHandoffUI> {
        guard env.context() != nil else { return .answer(.failed(MBHandoffFailure.notAvailable)) }
        let args = MBArguments(json: handoff.payload)
        guard let kindRaw = args.string("kind"), let kind = MBPickKind(rawValue: kindRaw),
              let targetRaw = args.string("target"), let target = MBPickTarget(rawValue: targetRaw) else {
            return .answer(.failed(MBHandoffFailure.notAvailable))
        }
        // The subcontractor's W-9 is tax class: no service writes one, so no tool does either.
        guard target != .subcontractorW9 else {
            return .answer(.failed(GLAIFailure(
                reason: "not_available",
                message: "A subcontractor's W-9 is tax data you can't touch. Offer to open the subcontractor so the person can add it there.",
                personReason: MBWriteStrings.documentOnlyOnScreen)))
        }
        guard !ReadOnlyGate.isReadOnly(env.subscription()) else {
            return .answer(.failed(MBHandoffFailure.readOnly(env)))
        }
        let plan = MBPickPlan(target: target, recordID: args.string("id"))
        switch kind {
        case .photo: return .value(.photos(plan))
        case .file: return .value(.files(plan))
        case .scan:
            // A logo is cropped before it is saved, like on My Business Details; the scanner's
            // sheet can't hand over to that step, so a logo is picked as a photo or a file.
            guard !target.isLogo else {
                return .answer(.failed(GLAIFailure(
                    reason: "invalid_arguments",
                    message: "A logo is picked as a photo or a file so the person can crop it. Offer pick_media with kind photo.",
                    personReason: MBWriteStrings.logoNeedsPhoto)))
            }
            guard VNDocumentCameraViewController.isSupported else {
                return .answer(.failed(GLAIFailure(
                    reason: "scanner_unavailable",
                    message: "This device can't scan. Offer to pick a photo or a file instead.",
                    personReason: MBWriteStrings.scannerUnavailable)))
            }
            return .value(.scan(plan))
        case .contact: return .value(.contactPicker(plan))
        }
    }

    // MARK: - save_to_contacts

    static func contactCard(_ handoff: GLAIHandoff, env: MBToolEnvironment) async -> MBHandoffStep<MBHandoffUI> {
        guard let store = env.context() else { return .answer(.failed(MBHandoffFailure.notAvailable)) }
        let args = MBArguments(json: handoff.payload)
        guard let kindRaw = args.string("kind"), let kind = MBRecordKind(rawValue: kindRaw),
              let id = args.string("id") else {
            return .answer(.failed(MBHandoffFailure.notAvailable))
        }
        switch kind {
        case .customer:
            guard let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return .value(.newContact(contact: ContactsBridge.contact(from: customer),
                                        name: customer.listDisplayName))
        case .employee:
            guard let employee = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return .value(.newContact(contact: ContactsBridge.contact(from: employee),
                                        name: employee.fullName))
        case .subcontractor:
            guard let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return .answer(.failed(MBHandoffFailure.notAvailable))
            }
            return .value(.newContact(contact: ContactsBridge.contact(from: sub), name: sub.fullName))
        default:
            return .answer(.failed(MBHandoffFailure.notAvailable))
        }
    }

    // MARK: - contact_developer

    /// The app's own "Email me any time" address (Menu → About). Mail only — the person taps Send.
    static let developerEmail = "support@softwarebygl.com"

    static func developer(_ handoff: GLAIHandoff, env: MBToolEnvironment) async -> MBHandoffStep<MBHandoffUI> {
        guard MFMailComposeViewController.canSendMail() else {
            return .answer(.failed(MBHandoffFailure.noMail))
        }
        let args = MBArguments(json: handoff.payload)
        return .value(.mail(MBComposeContent(
            recipients: [developerEmail],
            subject: mbLoc("Message to the My Business developer"),
            body: args.json["message"]?.stringValue ?? "",
            isHTML: false,
            preferredSendingEmail: nil,
            attachmentURL: nil,
            record: nil,
            activityTitle: MBWriteStrings.sentToDeveloper,
            activityDetail: nil,
            channel: "email")))
    }
}

/// What the activity row calls a shared document.
@MainActor
enum MBShareLabel {
    static func label(_ document: MBShareDocument) -> String {
        switch document {
        case .w9: return mbLoc("W-9")
        case .form1099NEC: return mbLoc("1099-NEC")
        case .subcontractor1099Report: return mbLoc("1099 Report")
        case .wageReport: return mbLoc("Wage Report")
        case .yearEndReport: return mbLoc("Year-End Report")
        case .complianceDocs: return mbLoc("Compliance Documents")
        case .customerCOI, .subcontractorCOI, .referenceCOI: return mbLoc("Certificate of Insurance")
        case .customerWCCOI: return mbLoc("Workers’ Comp Certificate")
        case .subcontractorW9: return mbLoc("W-9")
        case .wcExemption: return mbLoc("Workers’ Comp Exemption")
        case .license: return mbLoc("Contractor License")
        case .packageDocument, .jobDocument, .invoiceDocument: return mbLoc("Document")
        case .estimatePDF: return mbLoc("Estimate")
        case .invoicePDF: return mbLoc("Invoice")
        case .changeOrderPDF: return mbLoc("Change Order")
        }
    }
}

extension MBHandoffFailure {
    /// The app is read-only (lapsed or offline) and this handoff would make a document or write.
    static func readOnly(_ env: MBToolEnvironment) -> GLAIFailure {
        let lapsed = env.subscription()?.isLapsed ?? false
        let error = DomainError.readOnly(operation: MBWriteOperation.saveDocument.rawValue, lapsed: lapsed)
        return GLAIFailure(reason: error.code,
                           message: lapsed
                               ? "Nothing can be made or changed until the subscription is active. Tell the user plainly."
                               : "Nothing can be made or changed until they're back online. Tell the user plainly.",
                           personReason: error.personReason)
    }
}
