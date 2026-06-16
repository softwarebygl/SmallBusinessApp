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

/// Default email subject/body when sharing a generated document, in the brand's plain voice.
/// (`ShareLink`'s subject/message pre-fill the email when the share target is Mail.)
enum DocumentShareText {
    static func body(_ line: String, from businessName: String) -> String {
        let name = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? line : "\(line)\n\nThank you,\n\(name)"
    }
}

// MARK: - Year-End Tax Report

/// Shows a document-style preview of the year's tax summary (the same figures sent to the
/// accountant), with an inline year selector and the share action in the navbar. Sharing sends a
/// receipts CSV plus the tax summary, scoped to the selected year. Mirrors the Generate-a-W-9 flow:
/// see exactly what you're sharing first, controls below, share from the top-trailing toolbar.
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
    /// Brand gold fixed to light, for use on the always-white preview "paper".
    private var paperGold: Color { GLColor.gold.render(in: .light) }
    private var businessName: String { businessProfiles.first?.businessName ?? "" }

    private var availableYears: [Int] {
        let years = StatsEngine.availableYears(invoices: invoices, estimates: estimates, receipts: receipts)
        let lastCompleted = Calendar.current.component(.year, from: .now) - 1
        return Array(Set(years + [lastCompleted, selectedYear])).sorted(by: >)
    }

    private var summary: StatsSummary {
        StatsEngine.summary(period: .year(selectedYear), invoices: invoices, estimates: estimates, receipts: receipts)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    summaryPreview
                    yearControl
                    Text("Sharing sends two files for \(String(selectedYear)) — this tax summary and a receipts CSV listing every expense. Hand them to your accountant or keep them for your records.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle("Year-End Tax Report")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                if !files.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(items: files,
                                  subject: Text("Year-End Tax Report — \(String(selectedYear))"),
                                  message: Text(DocumentShareText.body(
                                    "Attached are the \(String(selectedYear)) year-end records: a receipts CSV and a tax summary.",
                                    from: businessName))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .onAppear { regenerate() }
            .onChange(of: selectedYear) { _, _ in regenerate() }
        }
    }

    // MARK: - Preview "paper"

    /// A document-style card mirroring the exported tax summary, so the figures shared are visible
    /// before tapping Share. Always rendered on white (a "page"), like the W-9 preview.
    private var summaryPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if !businessName.isEmpty {
                    Text(businessName).font(.headline).foregroundStyle(.black)
                }
                Text("Tax Summary · \(String(selectedYear))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.5))
            }
            .padding(.bottom, 14)

            sectionHeader("Income")
            amountRow("Collected (cash received)", summary.collected)
            amountRow("Invoiced (billed)", summary.invoiced)
            amountRow("Sales tax (on invoices)", summary.salesTax)
            amountRow("Outstanding (unpaid)", summary.outstanding)

            sectionHeader("Expenses").padding(.top, 16)
            if summary.expensesByCategory.isEmpty {
                amountRow("No receipts recorded", 0, muted: true)
            } else {
                ForEach(summary.expensesByCategory) { category in
                    amountRow(LocalizedStringKey(category.category), category.amount)
                }
            }
            Divider().padding(.vertical, 7)
            amountRow("Total expenses", summary.expenses, emphasized: true)

            Divider().padding(.top, 14).padding(.bottom, 10)
            HStack {
                Text("Net (collected − expenses)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                Spacer(minLength: 8)
                Text(money(summary.net))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(summary.net >= 0 ? paperGold : .red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
        .shadow(radius: 4, y: 2)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(paperGold)
            .padding(.bottom, 4)
    }

    private func amountRow(_ label: LocalizedStringKey, _ value: Double,
                           emphasized: Bool = false, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(muted ? .black.opacity(0.4) : .black.opacity(0.75))
            Spacer(minLength: 8)
            if !muted {
                Text(money(value))
                    .font(emphasized ? .subheadline.weight(.semibold) : .subheadline.monospacedDigit())
                    .foregroundStyle(.black)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Year control

    /// The "edit" equivalent, styled like the W-9's action rows but with an inline year picker.
    private var yearControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tax year").font(.subheadline.weight(.semibold))
                Text("The year these records cover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("Tax year", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .tint(gold)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

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
    @Environment(\.modelContext) private var modelContext
    @Query private var userProfiles: [UserProfile]
    let profile: BusinessProfile

    @State private var pdfURL: URL?
    @State private var previewImage: UIImage?
    @State private var showingEdit = false
    @State private var includeSignature = false
    @State private var signatureUnlocked = false
    @State private var signatureImage: UIImage?
    @State private var showingSignatureEditor = false
    @State private var signatureTarget: UserProfile?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    /// The signature is the person's, so it lives on the UserProfile.
    private var hasUserSignature: Bool { userProfiles.first?.hasSignature ?? false }

    /// True once the user has opted in to signing and unlocked the signature with Face ID.
    private var signing: Bool { includeSignature && signatureUnlocked && signatureImage != nil }

    /// Opens the signature editor, creating the single UserProfile if the owner hasn't yet.
    private func editSignature() {
        let target = userProfiles.first ?? {
            let new = UserProfile()
            modelContext.insert(new)
            return new
        }()
        signatureTarget = target
        showingSignatureEditor = true
    }

    /// Recomputed whenever any W-9 input changes, so the preview/PDF refresh after editing.
    private var inputSignature: String {
        [profile.w9LegalName, profile.businessName, profile.w9TaxClassificationRaw,
         profile.w9LLCClassification, profile.w9OtherClassification, profile.w9TINTypeRaw,
         profile.secureTIN, profile.w9ExemptPayeeCode, profile.w9FATCACode,
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
                        ShareLink(item: pdfURL,
                                  subject: Text(profile.businessName.isEmpty ? "Form W-9" : "W-9 — \(profile.businessName)"),
                                  message: Text(DocumentShareText.body(
                                    "Attached is our completed Form W-9.", from: profile.businessName))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .onAppear { regenerate() }
            .onChange(of: inputSignature) { _, _ in regenerate() }
            .onChange(of: includeSignature) { _, _ in regenerate() }
            .onChange(of: showingSignatureEditor) { _, isShowing in
                // React when the signature editor closes. Adding a signature does NOT auto-enable the
                // toggle — the user opts in with Face ID via the toggle. If they were already unlocked
                // this session and changed the signature, refresh to the new one; removal resets.
                guard !isShowing else { return }
                if userProfiles.first?.signatureData == nil {
                    includeSignature = false
                    signatureUnlocked = false
                    signatureImage = nil
                } else if signatureUnlocked {
                    signatureImage = userProfiles.first?.signatureData.flatMap { UIImage(data: $0) }
                }
                regenerate()
            }
            .sheet(isPresented: $showingEdit) {
                MyCompanyFormScreen(profile: profile).glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingSignatureEditor) {
                if let signatureTarget {
                    SignatureEditorSheet(profile: signatureTarget).glAppearance(colorScheme)
                }
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
        if hasUserSignature {
            // Off by default; flipping it on prompts Face ID first (see signatureInclusion).
            Toggle("Include signature and date.", isOn: signatureInclusion)
                .tint(gold)
                .padding()
                .glCardBackground()

            DocActionRow(title: "Change signature",
                         subtitle: "Redraw, retype, or remove your saved signature.",
                         systemImage: "signature") { editSignature() }
        } else {
            DocActionRow(title: "Add a signature",
                         subtitle: "Sign and date your W-9 automatically.",
                         systemImage: "signature") { editSignature() }
        }
    }

    /// The toggle never flips itself on: a request to enable runs Face ID first and only turns on
    /// after it succeeds. Turning off is immediate and re-locks the signature.
    private var signatureInclusion: Binding<Bool> {
        Binding(
            get: { includeSignature },
            set: { wantsOn in
                if wantsOn {
                    Task { await enableSignature() }
                } else {
                    includeSignature = false
                    signatureUnlocked = false
                    signatureImage = nil
                    regenerate()
                }
            }
        )
    }

    private func enableSignature() async {
        guard hasUserSignature else { return }
        guard await BiometricGate.authenticate(
            reason: String(localized: "Unlock your saved signature to add it to your W-9.")) else { return }
        if let data = userProfiles.first?.signatureData { signatureImage = UIImage(data: data) }
        signatureUnlocked = true
        includeSignature = true
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
