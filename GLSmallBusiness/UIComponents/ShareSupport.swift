//
//  ShareSupport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import MessageUI

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

/// Apple's Mail compose sheet, pre-filled with recipient/subject/body and a PDF attachment.
/// Note: `MFMailComposeViewController.canSendMail()` is false on the Simulator.
struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    var isHTML: Bool = false
    let attachmentURL: URL?
    let onFinish: (SendOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: isHTML)
        if let url = attachmentURL, let data = try? Data(contentsOf: url) {
            controller.addAttachmentData(data, mimeType: "application/pdf", fileName: url.lastPathComponent)
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

/// Apple's Messages compose sheet, pre-filled with recipient/body and a PDF attachment.
/// Note: `MFMessageComposeViewController.canSendText()` is false on the Simulator.
struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    /// Attachments shown in order — typically the brand logo image followed by the estimate PDF.
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
