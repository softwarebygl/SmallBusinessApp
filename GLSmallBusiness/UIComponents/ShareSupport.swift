//
//  ShareSupport.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import MessageUI

/// Apple's Mail compose sheet, pre-filled with recipient/subject/body and a PDF attachment.
/// Note: `MFMailComposeViewController.canSendMail()` is false on the Simulator.
struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    var isHTML: Bool = false
    let attachmentURL: URL?
    let onFinish: () -> Void

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
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
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
    let onFinish: () -> Void

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
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
