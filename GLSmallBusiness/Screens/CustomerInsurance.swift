//
//  CustomerInsurance.swift
//  GLSmallBusiness
//
//  A customer's General Liability Certificate of Insurance. Unlike the workers'-comp and license
//  documents (which are general and live on the business), a COI names its certificate holder, so each
//  customer has their own — issued by the insurer with that customer listed — uploaded and managed
//  here, then sent as-is in their Contractor Package.
//
//  This screen mirrors the compliance-doc detail / Generate-a-W-9 flow: the file fills the screen
//  (scrollable / zoomable), Share sits in the navbar, and replace / remove are at the bottom.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct CustomerCOIDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    let customer: Customer

    @State private var showingImporter = false
    @State private var confirmRemove = false
    @State private var uploadFailed = false

    private let fallbackFileName = "Certificate-of-Insurance.pdf"
    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var businessName: String { profiles.first?.businessName ?? "" }
    private var displayName: String {
        let name = customer.coiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallbackFileName : name
    }
    private var shareURL: URL? {
        customer.coiData.flatMap {
            CompliancePDF.tempURL($0, name: customer.coiName, fallback: fallbackFileName)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let data = customer.coiData {
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
                ContentUnavailableView("No certificate", systemImage: "doc",
                                       description: Text("This customer's COI hasn't been uploaded yet."))
                Spacer()
            }

            DocActionRow(title: "Replace file",
                         subtitle: "Upload a new PDF or image.",
                         systemImage: "arrow.up.doc") { showingImporter = true }

            Button(role: .destructive) { confirmRemove = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.title3).frame(width: 28).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove certificate").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text("Delete this customer's COI from your records.")
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
        .navigationTitle("Certificate of Insurance")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL,
                              subject: Text(businessName.isEmpty ? "Certificate of Insurance" : "Certificate of Insurance — \(businessName)"),
                              message: Text(DocumentShareText.body(
                                "Attached is our Certificate of Insurance.", from: businessName))) {
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
                customer.coiData = data
                customer.coiName = url.lastPathComponent
            } else {
                uploadFailed = true
            }
        }
        .confirmationDialog("Remove this certificate?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                customer.coiData = nil
                customer.coiName = ""
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
