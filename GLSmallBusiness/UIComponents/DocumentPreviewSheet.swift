//
//  DocumentPreviewSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  The single "see exactly what you're sharing" flow, reused everywhere a document can be shared
//  (estimate, invoice, change order, payment receipt, contractor package, W-9, 1099-NEC). Opens the
//  generated PDF in the shared zoomable PDFKit viewer with Share in the navbar — so the Preview
//  action looks and behaves identically on every screen.
//

import SwiftUI
import PDFKit

/// Friendly placeholder shown when a document couldn't be built (e.g. the device is critically low
/// on storage) — never an infinite spinner. The Try Again re-runs generation.
struct DocumentGenerationError: View {
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t create this document", systemImage: "doc.questionmark")
        } description: {
            Text("Please try again. If it keeps happening, make sure your device has some free storage space.")
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

struct DocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var title: LocalizedStringKey = "Preview"
    var subject: String = ""
    var message: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if let document = PDFDocument(url: url) {
                    CertificatePDFView(document: document)
                } else {
                    ContentUnavailableView {
                        Label("Couldn’t open this document", systemImage: "doc.questionmark")
                    } description: {
                        Text("Please try again in a moment. If it keeps happening, make sure your device has some free storage space.")
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(subject), message: Text(message)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
