//
//  ShareSupport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import MessageUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Apple's share sheet (`UIActivityViewController`) presented imperatively — for when a share must be
/// gated behind something (e.g. Face ID) rather than offered as a declarative `ShareLink`. Used for
/// the subcontractor year-end export, whose CSV carries full Tax IDs.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// Called when the person finishes or closes the share sheet, so the sheet hosting it can close.
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let onComplete {
            controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The subject and message that ride along with shared files (what `ShareLink(subject:message:)` sends).
final class ShareMessageItem: NSObject, UIActivityItemSource {
    let message: String
    let subject: String

    init(message: String, subject: String) {
        self.message = message
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        message
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        message.isEmpty ? nil : message
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject
    }
}

/// The files one share hands the share sheet, and the send folder to remove when it closes.
struct PreparedShare: Identifiable {
    let id = UUID()
    var urls: [URL]
    var folder: URL? = nil
}

/// A Share button whose files are written when it is TAPPED — never while the screen draws
/// (§4B #12: a `ShareLink` needs its files up front, so screens wrote every attachment on each
/// render) — shown in Apple's share sheet and removed when the sheet closes. A lapsed app refuses
/// at the tap, like `MBShareLink`; a share that wrote nothing says so instead of opening empty.
struct MBPreparedShareButton<Label: View>: View {
    var subject: String = ""
    var message: String = ""
    var operation: MBWriteOperation = .sendDocument
    var failureTitle: LocalizedStringKey = "Couldn’t create the document — try again"
    @Binding var refused: MBWriteOperation?
    /// Builds the share at the tap; nil or no files shows `failureTitle`.
    let prepare: () -> PreparedShare?
    @ViewBuilder var label: () -> Label

    @State private var prepared: PreparedShare?
    @State private var folderToDiscard: URL?
    @State private var failed = false

    var body: some View {
        Button {
            guard ReadOnlyGate.allows(operation, into: $refused) else { return }
            guard let share = prepare(), !share.urls.isEmpty else {
                failed = true
                return
            }
            SendFiles.discard(folderToDiscard)
            folderToDiscard = share.folder
            prepared = share
        } label: {
            label()
        }
        .sheet(item: $prepared, onDismiss: {
            SendFiles.discard(folderToDiscard)
            folderToDiscard = nil
        }) { share in
            ActivityView(items: activityItems(share)) { prepared = nil }
                .presentationDetents([.medium, .large])
        }
        .alert(failureTitle, isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func activityItems(_ share: PreparedShare) -> [Any] {
        let text: [Any] = subject.isEmpty && message.isEmpty
            ? [] : [ShareMessageItem(message: message, subject: subject)]
        return text + share.urls
    }
}
#endif

/// What actually happened when the Mail / Messages sheet closed, so the screen can tell the user
/// (a closed compose sheet looks the same whether it sent, failed, or was cancelled — and a
/// contractor must never *think* a document went out when it didn't). Mapping is pure so it's tested.
enum SendOutcome: Equatable {
    case sent
    case cancelled
    case failed

    init(mailResult: MFMailComposeResult, error: Error?) {
        if error != nil { self = .failed; return }
        switch mailResult {
        case .sent: self = .sent
        case .failed: self = .failed
        case .cancelled, .saved: self = .cancelled   // saved-to-drafts wasn't actually sent
        @unknown default: self = .cancelled
        }
    }

    init(messageResult: MessageComposeResult) {
        switch messageResult {
        case .sent: self = .sent
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        @unknown default: self = .cancelled
        }
    }
}

/// A binary file attachment (proof photo, permit doc, or scan) attached to an outbound email.
struct MailAttachment {
    let data: Data
    let mimeType: String
    let fileName: String
}

// MARK: - Can this device compose?

/// The one answer to "can this device open the Mail / Messages composer right now?" (§4B #34).
/// A button's `.disabled(…)` reads it when the screen last drew, which can be stale (a Mail
/// account removed while the app was in the background), so the tap asks again through `check`,
/// and `MailComposeView` / `MessageComposeView` ask once more before they build a controller.
enum ComposeCapability {
    enum Channel: Int, Identifiable {
        case mail, text
        var id: Int { rawValue }
    }

    /// What the device says now.
    static func canSend(_ channel: Channel) -> Bool {
        switch channel {
        case .mail: MFMailComposeViewController.canSendMail()
        case .text: MFMessageComposeViewController.canSendText()
        }
    }

    /// The tap's re-check: true to go ahead; false records the channel in `unavailable`, which
    /// `.composeUnavailableAlert` turns into one plain sentence. `available` is a test seam.
    static func check(_ channel: Channel, into unavailable: Binding<Channel?>,
                      available: Bool? = nil) -> Bool {
        if available ?? canSend(channel) { return true }
        unavailable.wrappedValue = channel
        return false
    }

    /// The sentence a person sees when the device can't compose.
    static func unavailableMessage(_ channel: Channel) -> String {
        switch channel {
        case .mail: mbLoc("There’s no email account set up on this iPhone.")
        case .text: mbLoc("This iPhone can’t send text messages.")
        }
    }

    static func systemImage(_ channel: Channel) -> String {
        channel == .mail ? "envelope" : "message"
    }
}

extension View {
    /// The alert `ComposeCapability.check` raises when the device can't compose.
    func composeUnavailableAlert(_ channel: Binding<ComposeCapability.Channel?>) -> some View {
        alert(channel.wrappedValue.map { ComposeCapability.unavailableMessage($0) } ?? "",
              isPresented: Binding(get: { channel.wrappedValue != nil },
                                   set: { if !$0 { channel.wrappedValue = nil } })) {
            Button("OK", role: .cancel) { channel.wrappedValue = nil }
        }
    }

    /// One alert for every document whose PDF couldn't be made when the person tapped send.
    func pdfFailureAlert(_ isPresented: Binding<Bool>) -> some View {
        alert("Couldn’t create the PDF. Try again.", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// What a compose sheet shows instead of a controller the device can't present.
private struct ComposeUnavailableView: View {
    let channel: ComposeCapability.Channel
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(ComposeCapability.unavailableMessage(channel), systemImage: ComposeCapability.systemImage(channel))
        } actions: {
            Button("OK", action: onClose)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
    }
}

/// Apple's Mail compose sheet, pre-filled with recipient/subject/body and a PDF attachment — or,
/// when this device can't send mail, a plain message (never a controller it can't present).
/// Note: `MFMailComposeViewController.canSendMail()` is false on the Simulator.
struct MailComposeView: View {
    let recipients: [String]
    let subject: String
    let messageBody: String
    let isHTML: Bool
    let preferredSendingEmail: String?
    let attachmentURL: URL?
    let additionalAttachments: [MailAttachment]
    let onFinish: (SendOutcome) -> Void

    /// Decided once, when the sheet opens.
    @State private var canSend = ComposeCapability.canSend(.mail)

    init(recipients: [String], subject: String, body: String, isHTML: Bool = false,
         preferredSendingEmail: String? = nil, attachmentURL: URL?,
         additionalAttachments: [MailAttachment] = [], onFinish: @escaping (SendOutcome) -> Void) {
        self.recipients = recipients
        self.subject = subject
        self.messageBody = body
        self.isHTML = isHTML
        self.preferredSendingEmail = preferredSendingEmail
        self.attachmentURL = attachmentURL
        self.additionalAttachments = additionalAttachments
        self.onFinish = onFinish
    }

    var body: some View {
        if canSend {
            MailComposeController(recipients: recipients, subject: subject, body: messageBody, isHTML: isHTML,
                                  preferredSendingEmail: preferredSendingEmail, attachmentURL: attachmentURL,
                                  additionalAttachments: additionalAttachments, onFinish: onFinish)
        } else {
            ComposeUnavailableView(channel: .mail) { onFinish(.cancelled) }
        }
    }
}

private struct MailComposeController: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let isHTML: Bool
    let preferredSendingEmail: String?
    let attachmentURL: URL?
    let additionalAttachments: [MailAttachment]
    let onFinish: (SendOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        if let preferredSendingEmail, !preferredSendingEmail.isEmpty {
            controller.setPreferredSendingEmailAddress(preferredSendingEmail)
        }
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: isHTML)
        if let url = attachmentURL, let data = try? Data(contentsOf: url) {
            controller.addAttachmentData(data, mimeType: "application/pdf", fileName: url.lastPathComponent)
        }
        for item in additionalAttachments {
            controller.addAttachmentData(item.data, mimeType: item.mimeType, fileName: item.fileName)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (SendOutcome) -> Void
        init(onFinish: @escaping (SendOutcome) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(SendOutcome(mailResult: result, error: error))
        }
    }
}

/// Apple's Messages compose sheet, pre-filled with recipient/body and a PDF attachment — or, when
/// this device can't send texts, a plain message (never a controller it can't present).
/// Note: `MFMessageComposeViewController.canSendText()` is false on the Simulator.
struct MessageComposeView: View {
    let recipients: [String]
    let messageBody: String
    /// Attachments shown in order — typically the brand logo image followed by the estimate PDF.
    let attachmentURLs: [URL]
    let onFinish: (SendOutcome) -> Void

    /// Decided once, when the sheet opens.
    @State private var canSend = ComposeCapability.canSend(.text)

    init(recipients: [String], body: String, attachmentURLs: [URL],
         onFinish: @escaping (SendOutcome) -> Void) {
        self.recipients = recipients
        self.messageBody = body
        self.attachmentURLs = attachmentURLs
        self.onFinish = onFinish
    }

    var body: some View {
        if canSend {
            MessageComposeController(recipients: recipients, body: messageBody, attachmentURLs: attachmentURLs,
                                     onFinish: onFinish)
        } else {
            ComposeUnavailableView(channel: .text) { onFinish(.cancelled) }
        }
    }
}

private struct MessageComposeController: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let attachmentURLs: [URL]
    let onFinish: (SendOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = recipients
        controller.body = body
        for url in attachmentURLs {
            controller.addAttachmentURL(url, withAlternateFilename: url.lastPathComponent)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (SendOutcome) -> Void
        init(onFinish: @escaping (SendOutcome) -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(SendOutcome(messageResult: result))
        }
    }
}
