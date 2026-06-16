//
//  InsuranceDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Manually-uploaded compliance certificates — a proof of insurance (COI) and a workers' comp
//  exemption. Uploaded/managed in My Company; shared from the Documents hub. Mirrors the W-9 flow:
//  if nothing's uploaded yet, the share sheet routes the user to the My Company upload screen.

import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

// MARK: - Certificate kinds

/// The two compliance certificates, each backed by a pair of `BusinessProfile` properties.
enum ComplianceKind: String, CaseIterable, Identifiable {
    case proofOfInsurance
    case wcExemption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proofOfInsurance: return String(localized: "Proof of Insurance")
        case .wcExemption: return String(localized: "Workers' Comp Exemption")
        }
    }

    var systemImage: String {
        switch self {
        case .proofOfInsurance: return "checkmark.shield"
        case .wcExemption: return "shield.lefthalf.filled"
        }
    }

    var fallbackFileName: String {
        switch self {
        case .proofOfInsurance: return "Proof-of-Insurance.pdf"
        case .wcExemption: return "Workers-Comp-Exemption.pdf"
        }
    }

    func data(_ profile: BusinessProfile) -> Data? {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceData
        case .wcExemption: return profile.wcExemptionData
        }
    }

    func fileName(_ profile: BusinessProfile) -> String {
        switch self {
        case .proofOfInsurance: return profile.proofOfInsuranceName
        case .wcExemption: return profile.wcExemptionName
        }
    }

    func store(_ profile: BusinessProfile, data: Data?, name: String) {
        switch self {
        case .proofOfInsurance:
            profile.proofOfInsuranceData = data
            profile.proofOfInsuranceName = name
        case .wcExemption:
            profile.wcExemptionData = data
            profile.wcExemptionName = name
        }
    }
}

enum CompliancePDF {
    /// Renders page 1 of an uploaded certificate to an image for in-app preview.
    static func firstPageImage(_ data: Data, scale: CGFloat = 2) -> UIImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: box.size, format: format).image { rc in
            let cg = rc.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: box.size))
            cg.translateBy(x: 0, y: box.size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }

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

    @State private var importing: ComplianceKind?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ComplianceKind.allCases) { card($0) }
                    Text("Upload your certificate PDFs once here, then share them anytime from Documents. Stored privately in your iCloud account.")
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
            .navigationTitle("Insurance & WC Exemption")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
            }
            .fileImporter(isPresented: importingBinding, allowedContentTypes: [.pdf]) { result in
                guard let kind = importing, case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    kind.store(profile, data: data, name: url.lastPathComponent)
                }
            }
        }
    }

    private var importingBinding: Binding<Bool> {
        Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })
    }

    private func card(_ kind: ComplianceKind) -> some View {
        let uploaded = kind.data(profile) != nil
        let name = kind.fileName(profile)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.subheadline.weight(.semibold))
                    Text(uploaded ? (name.isEmpty ? "PDF uploaded" : name) : "Not added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if uploaded {
                    Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                }
            }
            HStack(spacing: 16) {
                Button { importing = kind } label: {
                    Label(uploaded ? "Replace" : "Upload PDF", systemImage: "arrow.up.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(gold)
                }
                .buttonStyle(.plain)
                if uploaded {
                    Spacer()
                    Button(role: .destructive) {
                        kind.store(profile, data: nil, name: "")
                    } label: {
                        Text("Remove").font(.subheadline).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }
}

// MARK: - Documents: preview & share

/// Previews the uploaded certificate(s) and shares them; routes to the My Company uploader when none
/// exist yet (same pattern as the W-9 sheet's "Add tax details").
struct InsuranceDocumentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let profile: BusinessProfile

    @State private var showingManager = false

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
                VStack(spacing: 20) {
                    if profile.hasComplianceDocuments {
                        ForEach(ComplianceKind.allCases) { kind in
                            if let data = kind.data(profile) { preview(kind, data) }
                        }
                        DocActionRow(title: "Update documents",
                                     subtitle: "Upload or replace your certificates.",
                                     systemImage: "square.and.pencil") { showingManager = true }
                        Text("Review, then share with the requester. Add or replace certificates anytime.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        incompleteContent
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Insurance & WC Exemption")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                if !shareURLs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(items: shareURLs) { Image(systemName: "square.and.arrow.up") }
                            .tint(gold)
                    }
                }
            }
            .sheet(isPresented: $showingManager) {
                ComplianceDocsManagerSheet(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    private func preview(_ kind: ComplianceKind, _ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage).foregroundStyle(gold)
                Text(kind.title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            if let image = CompliancePDF.firstPageImage(data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
                    .shadow(radius: 4, y: 2)
            } else {
                Label(kind.fileName(profile).isEmpty ? "PDF" : kind.fileName(profile), systemImage: "doc.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .glCardBackground()
            }
        }
    }

    private var incompleteContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44))
                .foregroundStyle(gold)
            Text("Add your certificates")
                .font(.title3.weight(.semibold))
            Text("Upload your proof of insurance and/or workers' comp exemption to share them with a requester.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            DocActionRow(title: "Add documents",
                         subtitle: "Upload your certificate PDFs.",
                         systemImage: "arrow.up.doc") { showingManager = true }
        }
        .padding(.top, 32)
    }
}
