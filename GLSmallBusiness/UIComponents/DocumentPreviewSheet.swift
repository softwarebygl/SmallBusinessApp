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
import GoldLifeUI
import PDFKit

/// Friendly placeholder shown when a document couldn't be built (e.g. the device is critically low
/// on storage) — never an infinite spinner. The Try Again re-runs generation.
struct DocumentGenerationError: View {
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t create this document", systemImage: "doc.questionmark")
        } description: {
            Text("This usually means your device is low on storage. Free up some space and try again.")
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

struct DocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    // Resolved via `mbLoc` below — a LocalizedStringKey title leaves UIKit's cached
    // bar text stale after an in-app language switch. Interpolated call sites
    // ("Invoice \(number)") extract the same "%@" format keys either way.
    var title: String.LocalizationValue = "Preview"
    var subject: String = ""
    var message: String = ""
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    var body: some View {
        NavigationStack {
            Group {
                if let document = PDFDocument(url: url) {
                    CertificatePDFView(document: document)
                } else {
                    ContentUnavailableView {
                        Label("Couldn’t open this document", systemImage: "doc.questionmark")
                    } description: {
                        Text("This usually means your device is low on storage. Free up some space, then try again in a moment.")
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(GLScript.padded(mbLoc(title)))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc(title))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    MBShareLink(item: url, subject: Text(subject), message: Text(message),
                                refused: $readOnlyRefusal) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .readOnlyRefusalAlert($readOnlyRefusal)
        }
    }
}
