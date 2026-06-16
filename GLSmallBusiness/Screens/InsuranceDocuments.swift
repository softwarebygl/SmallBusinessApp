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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proofOfInsurance: return String(localized: "General Liability Insurance")
        case .wcInsurance: return String(localized: "Workers' Comp Insurance")
        case .wcExemption: return String(localized: "Workers' Comp Exemption")
        }
    }

    var systemImage: String {
        switch self {
        case .proofOfInsurance: return "checkmark.shield"
        case .wcInsurance: return "cross.case"
        case .wcExemption: return "shield.lefthalf.filled"
        }
    }

    var fallbackFileName: String {
        switch self {
        case .proofOfInsurance: return "General-Liability-Insurance.pdf"
        case .wcInsurance: return "Workers-Comp-Insurance.pdf"
        case .wcExemption: return "Workers-Comp-Exemption.pdf"
        }
    }

    func data(_ profile: BusinessProfile) -> Data? {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceData
        case .wcInsurance: return profile.wcInsuranceData
        case .wcExemption: return profile.wcExemptionData
        }
    }

    func fileName(_ profile: BusinessProfile) -> String {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceName
        case .wcInsurance: return profile.wcInsuranceName
        case .wcExemption: return profile.wcExemptionName
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
    @State private var actionKind: ComplianceKind?
    @State private var shareItem: ShareItem?
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
                    Text("Upload each certificate once (PDF or image). Share them with the requester using the button above. Stored privately in your iCloud account.")
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
            .navigationTitle("Insurance & Exemptions")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                if !shareURLs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(items: shareURLs,
                                  subject: Text(profile.businessName.isEmpty ? "Insurance & Exemptions" : "Insurance & Exemptions — \(profile.businessName)"),
                                  message: Text(DocumentShareText.body(
                                    "Attached are our current insurance and exemption certificates.", from: profile.businessName))) {
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
            .confirmationDialog(actionKind?.title ?? "",
                                isPresented: actionDialogBinding,
                                titleVisibility: .visible,
                                presenting: actionKind) { kind in
                Button("Share") {
                    if let data = kind.data(profile),
                       let url = CompliancePDF.tempURL(data, name: kind.fileName(profile), fallback: kind.fallbackFileName) {
                        shareItem = ShareItem(url: url)
                    }
                }
                // Let the dialog finish dismissing before presenting the file importer.
                Button("Replace file") { DispatchQueue.main.async { importTarget = kind; showingImporter = true } }
                Button("Remove", role: .destructive) { kind.store(profile, data: nil, name: "") }
            }
            .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
            .alert("Couldn't read that file", isPresented: $uploadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That file couldn't be opened. Try a different file, or export it as a PDF first.")
            }
        }
    }

    private var actionDialogBinding: Binding<Bool> {
        Binding(get: { actionKind != nil }, set: { if !$0 { actionKind = nil } })
    }

    /// The whole row is the button: tap to upload when empty, or to replace/remove when filled.
    private func card(_ kind: ComplianceKind) -> some View {
        let uploaded = kind.data(profile) != nil
        let name = kind.fileName(profile)
        return Button {
            if uploaded { actionKind = kind } else { importTarget = kind; showingImporter = true }
        } label: {
            HStack(spacing: 12) {
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
        .buttonStyle(.plain)
    }
}

// MARK: - Per-file share

/// Wraps a single certificate URL for `.sheet(item:)` presentation.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Presents the system share sheet (UIActivityViewController) for one uploaded certificate.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
