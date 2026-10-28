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
import GoldLifeUI
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
    /// When this document lapses. Supply it for anything a GC can reject as out of
    /// date — COIs, the workers' comp exemption, the contractor licence. Nil means
    /// the slot has no expiry concept (a W-9 does not expire), and the row is not
    /// rendered at all. Added 2026-09-01: expiry was not modelled anywhere, so an
    /// expired certificate still drew a gold seal and still went out in a package.
    var expiresOn: Binding<Date?>? = nil
}

struct DocumentDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let slot: DocumentSlot

    @State private var showingImporter = false
    @State private var confirmRemove = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private var gold: Color { GLTheme.accentFill }
    private var displayName: String {
        slot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? slot.fallbackFileName : slot.name
    }
    /// The file, written for this share only when Share is tapped (never while the screen draws).
    private func preparedShare() -> PreparedShare? {
        guard let data = slot.data else { return nil }
        return CompliancePDF.preparedShare([(data: data, name: slot.name, fallback: slot.fallbackFileName,
                                             slot: "document")])
    }

    var body: some View {
        VStack(spacing: 14) {
            if let data = slot.data {
                CertificatePreview(data: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.black.opacity(0.12)))
                Text(displayName)
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Spacer()
                ContentUnavailableView("No file", systemImage: "doc",
                                       description: Text("This document hasn’t been uploaded yet."))
                Spacer()
            }

            // The expiry, editable right where the file is. Optional-by-slot so a
            // document that cannot expire never grows a meaningless date.
            if slot.data != nil, let expires = slot.expiresOn {
                DocumentExpiryRow(expiresOn: gated(expires))
            }

            DocActionRow(title: "Replace file",
                         subtitle: "Upload a new PDF or image.",
                         systemImage: "arrow.up.doc") { showingImporter = true }

            Button(role: .destructive) { confirmRemove = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.removeTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text(slot.removeSubtitle).font(.caption).foregroundStyle(GLTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding(GLLayout.rowContentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glCardBackground()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background { GLTheme.background.ignoresSafeArea() }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .navigationTitle(GLScript.padded(slot.title))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(slot.title)), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if slot.data != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    MBPreparedShareButton(
                        subject: slot.businessName.isEmpty ? slot.title : "\(slot.title) — \(slot.businessName)",
                        message: DocumentShareText.body("Attached is our \(slot.title).", from: slot.businessName),
                        refused: $readOnlyRefusal,
                        prepare: preparedShare) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .tint(gold)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            // The two `slot.store` calls in this view are the single write choke point for EVERY
            // document detail screen in the app (job attachments, customer package extras,
            // compliance certificates, the reference COI) — gating them here covers all of them.
            guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
            // Size-checked first, then read off the main thread (F124).
            Task {
                switch await FileImport.read(url) {
                case .success(let data): slot.store(data, url.lastPathComponent)
                case .failure(let failure): importFailure = failure
                }
            }
        }
        .alert("Remove this document?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                guard ReadOnlyGate.allows(.deleteDocument, into: $readOnlyRefusal) else { return }
                slot.store(nil, "")
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImportFailureAlert($importFailure)
    }
}


extension DocumentDetailScreen {
    /// The expiry is a write like the file itself, so it is refused like one while read-only —
    /// until 2026-09-21 it was the one document write with no gate at all. Refused, the binding
    /// keeps its old value, so the toggle and date snap back under the alert.
    fileprivate func gated(_ expiresOn: Binding<Date?>) -> Binding<Date?> {
        Binding(get: { expiresOn.wrappedValue },
                set: { newValue in
                    guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
                    expiresOn.wrappedValue = newValue
                })
    }
}

/// The "good through" row on a certificate. Kept out of DocumentDetailScreen's body
/// so the optional-date dance (set / clear) lives in one place.
private struct DocumentExpiryRow: View {
    @Binding var expiresOn: Date?
    @State private var draft = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { expiresOn != nil },
                set: { on in expiresOn = on ? draft : nil }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set an expiry date").font(.subheadline.weight(.semibold))
                    Text("So this stops reading as current once it lapses.")
                        .font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
            }
            if let current = expiresOn {
                DatePicker("Good through",
                           selection: Binding(get: { current }, set: { expiresOn = $0; draft = $0 }),
                           displayedComponents: .date)
                if let caption = GLCertificateStatus.caption(current) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(GLCertificateStatus.isExpired(current) ? GLTheme.statusCritical
                                         : (GLCertificateStatus.isExpiringSoon(current) ? GLTheme.statusAttention
                                            : GLTheme.textSecondary))
                }
            }
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
        .onAppear { if let e = expiresOn { draft = e } }
    }
}
