//
//  InsuranceDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Manually-uploaded compliance certificates (PDF or image) — workers' comp insurance, a workers'
//  comp exemption, and the contractor license. Uploaded, managed, and shared from the Business
//  screen's "Insurance & Licensing" row (ComplianceDocsManagerSheet). These are the general documents
//  that are the same for every customer; the per-customer General Liability COI lives on the Customer.
//  The sheet also offers an optional, owner-only reference COI (a spare blank form) kept purely for the
//  owner's records — never shared with customers or bundled into a package.

import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

// MARK: - Certificate kinds

/// The general compliance certificates, each backed by a pair of `BusinessProfile` properties. These
/// are the same for every customer; the per-customer General Liability COI is stored on the Customer.
enum ComplianceKind: String, CaseIterable, Identifiable {
    case wcInsurance
    case wcExemption
    case license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wcInsurance: return String(localized: "Workers' Comp Insurance")
        case .wcExemption: return String(localized: "Workers' Comp Exemption")
        case .license: return String(localized: "Contractor License")
        }
    }

    var systemImage: String {
        switch self {
        case .wcInsurance: return "cross.case"
        case .wcExemption: return "shield.lefthalf.filled"
        case .license: return "person.text.rectangle"
        }
    }

    var fallbackFileName: String {
        switch self {
        case .wcInsurance: return "Workers-Comp-Insurance.pdf"
        case .wcExemption: return "Workers-Comp-Exemption.pdf"
        case .license: return "Contractor-License.pdf"
        }
    }

    func data(_ profile: BusinessProfile) -> Data? {
        switch self {
        case .wcInsurance: return profile.wcInsuranceData
        case .wcExemption: return profile.wcExemptionData
        case .license: return profile.licenseDocumentData
        }
    }

    func fileName(_ profile: BusinessProfile) -> String {
        switch self {
        case .wcInsurance: return profile.wcInsuranceName
        case .wcExemption: return profile.wcExemptionName
        case .license: return profile.licenseDocumentName
        }
    }

    func store(_ profile: BusinessProfile, data: Data?, name: String) {
        switch self {
        case .wcInsurance:
            profile.wcInsuranceData = data
            profile.wcInsuranceName = name
        case .wcExemption:
            profile.wcExemptionData = data
            profile.wcExemptionName = name
        case .license:
            profile.licenseDocumentData = data
            profile.licenseDocumentName = name
        }
    }
}

enum CompliancePDF {
    /// Writes a certificate to a temp file for sharing; returns its URL.
    static func tempURL(_ data: Data, name: String, fallback: String) -> URL? {
        let fileName = name.isEmpty ? fallback : name
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do { try data.write(to: url); return url } catch { return nil }
    }
}

// MARK: - My Company: upload / manage

/// Upload, replace, or remove the certificate PDFs. Lives on the My Company side; changes commit
/// immediately to the profile (and sync via CloudKit), so the sheet just closes with an X.
struct ComplianceDocsManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let profile: BusinessProfile

    /// `importTarget` (which slot is being filled) is kept separate from `showingImporter` (the
    /// presentation flag) on purpose: if the two shared one state, dismissing the importer could
    /// clear the target before the completion handler reads it — and the upload would silently no-op.
    @State private var importTarget: ComplianceKind?
    @State private var showingImporter = false
    @State private var showingReferenceImporter = false
    @State private var uploadFailed = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var shareURLs: [URL] {
        ComplianceKind.allCases.compactMap { kind in
            guard let data = kind.data(profile) else { return nil }
            return CompliancePDF.tempURL(data, name: kind.fileName(profile), fallback: kind.fallbackFileName)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ComplianceKind.allCases) { card($0) }
                    Text("Upload each document once (PDF or image). Tap one to view, share, or replace it — or use the button above to share them all. Stored privately in your iCloud account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    referenceCOISection
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Insurance & Licensing")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                if !shareURLs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(items: shareURLs,
                                  subject: Text(profile.businessName.isEmpty ? "Insurance & Licensing" : "Insurance & Licensing — \(profile.businessName)"),
                                  message: Text(DocumentShareText.body(
                                    "Attached are our current insurance, exemption, and license documents.", from: profile.businessName))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
                guard let kind = importTarget else { return }
                importTarget = nil
                guard case .success(let url) = result else { return }
                if let data = url.readSecurityScoped() {
                    kind.store(profile, data: data, name: url.lastPathComponent)
                } else {
                    uploadFailed = true
                }
            }
            .fileImporter(isPresented: $showingReferenceImporter, allowedContentTypes: [.pdf, .image]) { result in
                guard case .success(let url) = result else { return }
                if let data = url.readSecurityScoped() {
                    profile.ownerReferenceCOIData = data
                    profile.ownerReferenceCOIName = url.lastPathComponent
                } else {
                    uploadFailed = true
                }
            }
            .alert("Couldn't read that file", isPresented: $uploadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That file couldn't be opened. Try a different file, or export it as a PDF first.")
            }
        }
    }

    /// Uploaded slots push a detail screen (view / share / replace / remove); empty slots upload.
    @ViewBuilder
    private func card(_ kind: ComplianceKind) -> some View {
        let name = kind.fileName(profile)
        let subtitle = kind.data(profile) != nil
            ? (name.isEmpty ? "Uploaded" : name)
            : "Tap to upload (PDF or image)"
        if kind.data(profile) != nil {
            NavigationLink {
                ComplianceDocDetailScreen(kind: kind, profile: profile)
            } label: {
                cardLabel(title: kind.title, systemImage: kind.systemImage, subtitle: subtitle, uploaded: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                importTarget = kind
                showingImporter = true
            } label: {
                cardLabel(title: kind.title, systemImage: kind.systemImage, subtitle: subtitle, uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    /// Optional, owner-only reference COI — a spare blank form kept for the owner's own records. It is
    /// intentionally NOT a `ComplianceKind`, which keeps it out of the "share all" bundle and the
    /// Contractor Package, so it never reaches a customer. The per-customer COI is unaffected.
    @ViewBuilder
    private var referenceCOISection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("For your own reference")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                InfoButton(text: "Optional. A spare, blank Certificate of Insurance kept only for your own records — it's never sent to customers or added to a package.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            referenceCOICard
        }
    }

    @ViewBuilder
    private var referenceCOICard: some View {
        if profile.ownerReferenceCOIData != nil {
            NavigationLink {
                DocumentDetailScreen(slot: DocumentSlot(
                    title: String(localized: "Certificate of Insurance"),
                    data: profile.ownerReferenceCOIData,
                    name: profile.ownerReferenceCOIName,
                    fallbackFileName: "Certificate-of-Insurance.pdf",
                    businessName: profile.businessName,
                    removeTitle: "Remove document",
                    removeSubtitle: "Delete this reference copy from your records.",
                    store: { profile.ownerReferenceCOIData = $0; profile.ownerReferenceCOIName = $1 }
                ))
            } label: {
                cardLabel(title: String(localized: "Certificate of Insurance"),
                          systemImage: "doc.text",
                          subtitle: profile.ownerReferenceCOIName.isEmpty ? "Uploaded" : profile.ownerReferenceCOIName,
                          uploaded: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                showingReferenceImporter = true
            } label: {
                cardLabel(title: String(localized: "Certificate of Insurance"),
                          systemImage: "doc.text",
                          subtitle: "Tap to upload (PDF or image)",
                          uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func cardLabel(title: String, systemImage: String, subtitle: String, uploaded: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if uploaded {
                Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.up.doc").font(.footnote.weight(.semibold)).foregroundStyle(gold)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }
}

// MARK: - Certificate detail

/// View one uploaded compliance certificate (workers'-comp insurance/exemption or the license). A thin
/// wrapper over the shared `DocumentDetailScreen`, backed by the BusinessProfile through `ComplianceKind`.
struct ComplianceDocDetailScreen: View {
    let kind: ComplianceKind
    let profile: BusinessProfile

    var body: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: kind.title,
            data: kind.data(profile),
            name: kind.fileName(profile),
            fallbackFileName: kind.fallbackFileName,
            businessName: profile.businessName,
            removeTitle: "Remove document",
            removeSubtitle: "Delete this certificate from your records.",
            store: { kind.store(profile, data: $0, name: $1) }
        ))
    }
}

/// Renders the actual certificate — a scrollable, zoomable PDF, or the uploaded image.
struct CertificatePreview: View {
    let data: Data

    var body: some View {
        if let document = PDFDocument(data: data) {
            CertificatePDFView(document: document)
        } else if let image = UIImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
            .background(Color.white)
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark")
                .background(Color.white)
        }
    }
}

/// PDFKit-backed view so multi-page certificates can be scrolled and pinch-zoomed in place.
struct CertificatePDFView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .white
        view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
