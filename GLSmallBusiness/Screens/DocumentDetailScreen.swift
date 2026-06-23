//
//  DocumentDetailScreen.swift
//  GLSmallBusiness
//
//  One reusable screen for viewing a single uploaded document (PDF or image) — the file fills the
//  screen (scrollable / zoomable), Share sits in the navbar, and replace / remove are at the bottom.
//  Mirrors the Generate-a-W-9 flow. Both the business compliance certificates (backed by
//  BusinessProfile via ComplianceKind) and a customer's General Liability COI (backed by Customer)
//  present this screen, each supplying a `DocumentSlot` that says where to read/write the bytes and
//  what copy to show.
//

import SwiftUI
import UniformTypeIdentifiers

/// Describes one uploadable document for `DocumentDetailScreen`: its current bytes and filename, the
/// names used for sharing, the document-specific copy, and how to store a replacement or removal.
struct DocumentSlot {
    /// Navigation title and the base of the share subject, e.g. "Certificate of Insurance".
    let title: String
    let data: Data?
    let name: String
    let fallbackFileName: String
    /// Signs the share message; empty when no business name is on file.
    let businessName: String
    let removeTitle: LocalizedStringKey
    let removeSubtitle: LocalizedStringKey
    /// Persists a replacement (`data`, `name`) or a removal (`nil`, `""`).
    let store: (_ data: Data?, _ name: String) -> Void
}

struct DocumentDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let slot: DocumentSlot

    @State private var showingImporter = false
    @State private var confirmRemove = false
    @State private var uploadFailed = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var displayName: String {
        slot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? slot.fallbackFileName : slot.name
    }
    private var shareURL: URL? {
        slot.data.flatMap { CompliancePDF.tempURL($0, name: slot.name, fallback: slot.fallbackFileName) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let data = slot.data {
                CertificatePreview(data: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.12)))
                Text(displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Spacer()
                ContentUnavailableView("No file", systemImage: "doc",
                                       description: Text("This document hasn't been uploaded yet."))
                Spacer()
            }

            DocActionRow(title: "Replace file",
                         subtitle: "Upload a new PDF or image.",
                         systemImage: "arrow.up.doc") { showingImporter = true }

            Button(role: .destructive) { confirmRemove = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.removeTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text(slot.removeSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .glCardBackground()
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle(slot.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL,
                              subject: Text(slot.businessName.isEmpty ? slot.title : "\(slot.title) — \(slot.businessName)"),
                              message: Text(DocumentShareText.body(
                                "Attached is our \(slot.title).", from: slot.businessName))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            if let data = url.readSecurityScoped() {
                slot.store(data, url.lastPathComponent)
            } else {
                uploadFailed = true
            }
        }
        .confirmationDialog("Remove this document?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                slot.store(nil, "")
                dismiss()
            }
        }
        .alert("Couldn’t read that file", isPresented: $uploadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file couldn’t be opened. Try a different file, or export it as a PDF first.")
        }
    }
}
