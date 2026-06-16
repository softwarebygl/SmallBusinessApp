//
//  CompanyDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  The Documents hub and the document-generation sheets it presents. Documents live in their own
//  Menu destination (peer to My Company); My Company holds the reusable data they draw from.

import SwiftUI
import SwiftData

/// The in-sheet action card (icon · title · subtitle · chevron) used inside document sheets — e.g.
/// "Update tax details", "Add a signature", "Add documents". Matches the signature/Documents rows.
struct DocActionRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let gold = GLColor.gold.render(in: colorScheme)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Documents hub

/// A single home for generating and sending business documents: the year-end accountant export, the
/// W-9, the insurance / WC-exemption certificates, and — as it's added — a combined compliance-packet
/// email. Each reads from the company details saved in My Company.
struct DocumentsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    @State private var activeDocument: ActiveDocument?

    private enum ActiveDocument: String, Identifiable {
        case taxReport, w9, insurance
        var id: String { rawValue }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                row("Year-End Tax Report",
                    subtitle: "Receipts CSV + tax summary for your accountant",
                    systemImage: "doc.text") { activeDocument = .taxReport }
                row("Generate a W-9",
                    subtitle: "Official IRS Form W-9, filled and ready to share",
                    systemImage: "doc.plaintext") { activeDocument = .w9 }
                row("Insurance & WC Exemption",
                    subtitle: "Share your proof of insurance or workers' comp exemption",
                    systemImage: "checkmark.shield") { activeDocument = .insurance }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if profiles.isEmpty { modelContext.insert(BusinessProfile()) } }
        .sheet(item: $activeDocument) { document in
            switch document {
            case .taxReport:
                YearEndTaxReportSheet().glAppearance(colorScheme)
            case .w9:
                if let profile = profiles.first {
                    W9DocumentSheet(profile: profile).glAppearance(colorScheme)
                }
            case .insurance:
                if let profile = profiles.first {
                    InsuranceDocumentsSheet(profile: profile).glAppearance(colorScheme)
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey,
                     systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Year-End Tax Report

/// Presents an inline year picker (defaulted to the last completed year) and shares the same
/// accountant export — a receipts CSV plus a tax summary — scoped to that year.
struct YearEndTaxReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var invoices: [Invoice]
    @Query private var estimates: [Estimate]
    @Query private var receipts: [Receipt]
    @Query private var businessProfiles: [BusinessProfile]

    /// Last completed year: if today is in 2026, this defaults to 2025.
    @State private var selectedYear: Int = Calendar.current.component(.year, from: .now) - 1
    @State private var files: [URL] = []

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var availableYears: [Int] {
        let years = StatsEngine.availableYears(invoices: invoices, estimates: estimates, receipts: receipts)
        let lastCompleted = Calendar.current.component(.year, from: .now) - 1
        return Array(Set(years + [lastCompleted, selectedYear])).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tax year", selection: $selectedYear) {
                        ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .tint(gold)
                } footer: {
                    Text("Defaults to the last completed year. Includes a receipts CSV and a tax summary — income collected, sales tax, expenses by category, and net — for the selected year.")
                        .textCase(nil)
                }

                Section {
                    ShareLink(items: files) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(gold)
                    }
                    .disabled(files.isEmpty)
                }
            }
            .glFormBackground()
            .navigationTitle("Year-End Tax Report")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
            .onAppear { regenerate() }
            .onChange(of: selectedYear) { _, _ in regenerate() }
        }
    }

    private func regenerate() {
        files = StatsExport.files(
            period: .year(selectedYear),
            invoices: invoices,
            estimates: estimates,
            receipts: receipts,
            business: businessProfiles.first
        )
    }
}

// MARK: - W-9

/// Renders a W-9 from the company's saved tax details, shows a preview, and shares the PDF.
/// When the required details are missing it routes the user to the My Company edit form to add them.
struct W9DocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let profile: BusinessProfile

    @State private var pdfURL: URL?
    @State private var previewImage: UIImage?
    @State private var showingEdit = false
    @State private var includeSignature = true
    @State private var signatureUnlocked = false
    @State private var signatureImage: UIImage?
    @State private var showingSignatureEditor = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    /// True once the user has opted in to signing and unlocked the signature with Face ID.
    private var signing: Bool { includeSignature && signatureUnlocked && signatureImage != nil }

    /// Recomputed whenever any W-9 input changes, so the preview/PDF refresh after editing.
    private var inputSignature: String {
        [profile.w9LegalName, profile.businessName, profile.w9TaxClassificationRaw,
         profile.w9LLCClassification, profile.w9OtherClassification, profile.w9TINTypeRaw,
         profile.w9TIN, profile.w9ExemptPayeeCode, profile.w9FATCACode,
         profile.address.street1, profile.address.street2 ?? "", profile.address.city,
         profile.address.state, profile.address.postalCode].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if profile.w9IsComplete {
                        completeContent
                    } else {
                        incompleteContent
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle("Generate a W-9")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                if let pdfURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: pdfURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .onAppear { regenerate() }
            .onChange(of: inputSignature) { _, _ in regenerate() }
            .onChange(of: includeSignature) { _, _ in regenerate() }
            .onChange(of: profile.hasSignature) { _, hasSignature in
                // A signature just created in this session is applied right away — the user clearly
                // has device access, so no separate Face ID prompt is needed this time.
                if hasSignature {
                    if let data = profile.signatureData { signatureImage = UIImage(data: data) }
                    signatureUnlocked = true
                    includeSignature = true
                    regenerate()
                }
            }
            .sheet(isPresented: $showingEdit) {
                MyCompanyFormScreen(profile: profile).glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingSignatureEditor) {
                SignatureEditorSheet(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    @ViewBuilder
    private var completeContent: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
                .shadow(radius: 4, y: 2)
        }

        DocActionRow(title: "Update tax details",
                     subtitle: "Name, classification, and Tax ID.",
                     systemImage: "square.and.pencil") { showingEdit = true }

        signatureControls

        if signing {
            Text("Signed with your saved signature, dated today. Review before sending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Review the details. Print or send the W-9, then sign and date it by hand before giving it to the requester.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var signatureControls: some View {
        if profile.hasSignature {
            VStack(spacing: 10) {
                Toggle("Export with Signature and Date", isOn: $includeSignature)
                    .tint(gold)
                if includeSignature && !signatureUnlocked {
                    Button {
                        Task { await unlockSignature() }
                    } label: {
                        Label("Unlock signature with Face ID", systemImage: "faceid")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(gold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .glCardBackground()
        } else {
            DocActionRow(title: "Add a signature",
                         subtitle: "Sign and date your W-9 automatically.",
                         systemImage: "signature") { showingSignatureEditor = true }
        }
    }

    private func unlockSignature() async {
        guard await BiometricGate.authenticate(reason: String(localized: "Unlock your saved signature.")) else { return }
        if let data = profile.signatureData { signatureImage = UIImage(data: data) }
        signatureUnlocked = true
        regenerate()
    }

    private var incompleteContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 44))
                .foregroundStyle(gold)
            Text("Finish your W-9")
                .font(.title3.weight(.semibold))
            Text("Your W-9 already uses the business name and address from My Company. To complete it, just add:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(profile.w9MissingRequirements, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.system(size: 7))
                            .foregroundStyle(gold)
                        Text(item)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()

            Button {
                showingEdit = true
            } label: {
                Text("Add tax details")
                    .font(.headline)
                    .foregroundStyle(gold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .glCardBackground()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 32)
    }

    private func regenerate() {
        guard profile.w9IsComplete else {
            pdfURL = nil
            previewImage = nil
            return
        }
        let signature = signing ? signatureImage : nil
        let date = signing ? Date() : nil
        let url = W9PDF.render(profile, signatureImage: signature, signedDate: date)
        pdfURL = url
        previewImage = url.flatMap { W9PDF.pageImage(from: $0) }
    }
}
