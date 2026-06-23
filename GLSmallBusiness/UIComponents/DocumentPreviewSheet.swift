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
                    ContentUnavailableView("Couldn't open the document", systemImage: "doc.questionmark")
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
