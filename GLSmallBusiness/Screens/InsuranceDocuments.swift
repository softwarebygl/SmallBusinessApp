//
//  InsuranceDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Manually-uploaded compliance certificates (PDF or image) — general liability insurance, workers'
//  comp insurance, and a workers' comp exemption. Uploaded, managed, and shared from the Business
//  screen's "Insurance & Exemptions" row (ComplianceDocsManagerSheet).

import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

// MARK: - Certificate kinds

/// The compliance certificates, each backed by a pair of `BusinessProfile` properties.
enum ComplianceKind: String, CaseIterable, Identifiable {
    case proofOfInsurance   // displayed as "General Liability Insurance"
    case wcInsurance
    case wcExemption
    case license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proofOfInsurance: return String(localized: "General Liability Insurance")
        case .wcInsurance: return String(localized: "Workers' Comp Insurance")
        case .wcExemption: return String(localized: "Workers' Comp Exemption")
        case .license: return String(localized: "Contractor License")
        }
    }

    var systemImage: String {
        switch self {
        case .proofOfInsurance: return "checkmark.shield"
        case .wcInsurance: return "cross.case"
        case .wcExemption: return "shield.lefthalf.filled"
        case .license: return "person.text.rectangle"
        }
    }

    var fallbackFileName: String {
        switch self {
        case .proofOfInsurance: return "General-Liability-Insurance.pdf"
        case .wcInsurance: return "Workers-Comp-Insurance.pdf"
        case .wcExemption: return "Workers-Comp-Exemption.pdf"
        case .license: return "Contractor-License.pdf"
        }
    }

    func data(_ profile: BusinessProfile) -> Data? {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceData
        case .wcInsurance: return profile.wcInsuranceData
        case .wcExemption: return profile.wcExemptionData
        case .license: return profile.licenseDocumentData
        }
    }

    func fileName(_ profile: BusinessProfile) -> String {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceName
        case .wcInsurance: return profile.wcInsuranceName
        case .wcExemption: return profile.wcExemptionName
        case .license: return profile.licenseDocumentName
        }
    }

    func store(_ profile: BusinessProfile, data: Data?, name: String) {
        switch self {
        case .proofOfInsurance:
            profile.proofOfInsuranceData = data
            profile.proofOfInsuranceName = name
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
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), !data.isEmpty {
                    kind.store(profile, data: data, name: url.lastPathComponent)
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
        if kind.data(profile) != nil {
            NavigationLink {
                ComplianceDocDetailScreen(kind: kind, profile: profile)
            } label: {
                cardLabel(kind, uploaded: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                importTarget = kind
                showingImporter = true
            } label: {
                cardLabel(kind, uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func cardLabel(_ kind: ComplianceKind, uploaded: Bool) -> some View {
        let name = kind.fileName(profile)
        return HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.subheadline.weight(.semibold))
                Text(uploaded ? (name.isEmpty ? "Uploaded" : name) : "Tap to upload (PDF or image)")
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

/// View one uploaded certificate, mirroring the Generate-a-W-9 flow: the file itself fills the
/// screen (scrollable / zoomable), Share sits in the navbar, and replace / remove are at the bottom.
struct ComplianceDocDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let kind: ComplianceKind
    let profile: BusinessProfile

    @State private var showingImporter = false
    @State private var confirmRemove = false
    @State private var uploadFailed = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var data: Data? { kind.data(profile) }
    private var displayName: String {
        let name = kind.fileName(profile)
        return name.isEmpty ? kind.fallbackFileName : name
    }
    private var shareURL: URL? {
        data.flatMap { CompliancePDF.tempURL($0, name: kind.fileName(profile), fallback: kind.fallbackFileName) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let data {
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
                ContentUnavailableView("No file", systemImage: "doc", description: Text("This certificate hasn't been uploaded yet."))
                Spacer()
            }

            DocActionRow(title: "Replace file",
                         subtitle: "Upload a new PDF or image.",
                         systemImage: "arrow.up.doc") { showingImporter = true }

            Button(role: .destructive) { confirmRemove = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove document").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text("Delete this certificate from your records.")
                            .font(.caption).foregroundStyle(.secondary)
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
        .navigationTitle(kind.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL,
                              subject: Text(profile.businessName.isEmpty ? kind.title : "\(kind.title) — \(profile.businessName)"),
                              message: Text(DocumentShareText.body(
                                "Attached is our \(kind.title).", from: profile.businessName))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                kind.store(profile, data: data, name: url.lastPathComponent)
            } else {
                uploadFailed = true
            }
        }
        .confirmationDialog("Remove this certificate?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                kind.store(profile, data: nil, name: "")
                dismiss()
            }
        }
        .alert("Couldn't read that file", isPresented: $uploadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file couldn't be opened. Try a different file, or export it as a PDF first.")
        }
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
