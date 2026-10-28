//
//  CompanyDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  The Documents hub and the document-generation sheets it presents. Documents live in their own
//  Menu destination (peer to My Company); My Company holds the reusable data they draw from.

import SwiftUI
import GoldLifeUI
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
        let gold = GLTheme.accentFill
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.glCaption.weight(.semibold))
                    .foregroundStyle(GLTheme.textTertiary)
            }
            .padding(GLLayout.rowContentPadding)
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
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private var gold: Color { GLTheme.accentFill }
    /// Brand gold fixed to light, for use on the always-white preview "paper".
    private var paperGold: Color { GLTheme.paperAccent }
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
        ScrollView {
            VStack(spacing: 20) {
                summaryPreview
                yearControl
                Text("Sharing sends two files for \(String(selectedYear)) — this tax summary and a receipts CSV listing every expense. Hand them to your accountant or keep them for your records.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background {
            GLTheme.background.ignoresSafeArea()
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .navigationTitle(GLScript.padded(mbLoc("Year-End Tax Report")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Year-End Tax Report"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if !files.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    MBShareLinkItems(items: files,
                                     subject: Text("Year-End Tax Report — \(String(selectedYear))"),
                                     message: Text(DocumentShareText.body(
                                        "Attached are the \(String(selectedYear)) year-end records: a receipts CSV and a tax summary.",
                                        from: businessName)),
                                     operation: .exportStats,
                                     refused: $readOnlyRefusal) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .onAppear { regenerate() }
        .onChange(of: selectedYear) { _, _ in regenerate() }
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

            // Processor fees are deducted from net, so when they exist the preview must show them —
            // otherwise the displayed figures don't add up. Mirrors the exported summary exactly.
            if summary.processingFees > 0 {
                sectionHeader("Processing fees").padding(.top, 16)
                amountRow("Payment processing fees (deductible)", summary.processingFees)
            }

            Divider().padding(.top, 14).padding(.bottom, 10)
            HStack {
                Text(netLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                Spacer(minLength: 8)
                Text(money(summary.net))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(summary.net >= 0 ? paperGold : GLTheme.statusCritical)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.1)))
        .shadow(radius: 4, y: 2)
    }

    /// Matches the exported summary's label: fees only appear in the formula when they exist.
    private var netLabel: LocalizedStringKey {
        summary.processingFees > 0 ? "Net (collected − expenses − fees)" : "Net (collected − expenses)"
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
                    .foregroundStyle(GLTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Picker("Tax year", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .tint(gold)
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    private func money(_ value: Double) -> String { value.formatted(.money) }

    /// Deliberately NOT gated on the lapse, even though this writes files.
    ///
    /// It runs from `.onAppear`, so a refusal here would throw an alert at someone the moment they
    /// opened the screen — for something they never asked for. It also feeds the share toolbar's
    /// visibility, so an empty `files` would make the share button VANISH, which is the
    /// disappearing-control defect the whole feature exists to avoid. The export is refused where
    /// the person actually asks for it: the share row (`MBShareLinkItems`, `.exportStats`), which
    /// stays on screen and explains itself. Nothing leaves the app either way — these are temp
    /// files the share sheet reads.
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
    /// The signature is the person's, so it lives in their Gold Life ID (law 48a).
    private let identity = MBIdentity.shared
    let profile: BusinessProfile

    @State private var pdfURL: URL?
    @State private var previewImage: UIImage?
    @State private var showingEdit = false
    @State private var includeSignature = false
    @State private var signatureUnlocked = false
    @State private var signatureImage: UIImage?
    @State private var showingSignatureEditor = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private var gold: Color { GLTheme.accentFill }

    /// Whether the person has a saved signature in their Gold Life ID.
    private var hasUserSignature: Bool { identity.signatureData != nil }

    /// True once the user has opted in to signing and unlocked the signature with Face ID.
    private var signing: Bool { includeSignature && signatureUnlocked && signatureImage != nil }

    /// Opens the signature editor (it saves into the Gold Life ID).
    private func editSignature() {
        // The person tapped this, and the only thing the editor it opens can do is WRITE a
        // signature — so the refusal belongs here, out loud, rather than three taps later on the
        // editor's Save. The editor saves into the Gold Life ID; no local row is created.
        guard ReadOnlyGate.allows(.saveSignature, into: $readOnlyRefusal) else { return }
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
        ScrollView {
            VStack(spacing: 20) {
                if profile.w9IsComplete {
                    completeContent
                } else {
                    incompleteContent
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background {
            GLTheme.background.ignoresSafeArea()
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .navigationTitle(GLScript.padded(mbLoc("Generate a W-9")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Generate a W-9"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if let pdfURL {
                ToolbarItem(placement: .topBarTrailing) {
                    MBShareLink(item: pdfURL,
                                subject: Text(profile.businessName.isEmpty ? "Form W-9" : "W-9 — \(profile.businessName)"),
                                message: Text(DocumentShareText.body(
                                    "Attached is our completed Form W-9.", from: profile.businessName)),
                                operation: .generateW9,
                                refused: $readOnlyRefusal) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .onAppear { regenerate() }
        // The generated PDF carries the full TIN — delete it as soon as the screen is done with it.
        // (Pushing "Update tax details" also fires this; onAppear regenerates on the way back.)
        .onDisappear { W9PDF.cleanUp() }
        .onChange(of: inputSignature) { _, _ in regenerate() }
        .onChange(of: includeSignature) { _, _ in regenerate() }
        .onChange(of: showingSignatureEditor) { _, isShowing in
            // React when the signature editor closes. Adding a signature does NOT auto-enable the
            // toggle — the user opts in with Face ID via the toggle. If they were already unlocked
            // this session and changed the signature, refresh to the new one; removal resets.
            guard !isShowing else { return }
            if identity.signatureData == nil {
                includeSignature = false
                signatureUnlocked = false
                signatureImage = nil
            } else if signatureUnlocked {
                signatureImage = identity.signatureData.flatMap { UIImage(data: $0) }
            }
            regenerate()
        }
        .navigationDestination(isPresented: $showingEdit) {
            MyCompanyFormScreen(profile: profile)
        }
        .sheet(isPresented: $showingSignatureEditor) {
            SignatureEditorSheet().glAppearance(colorScheme)
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.1)))
                .shadow(radius: 4, y: 2)

            DocActionRow(title: "Update tax details",
                         subtitle: "Name, classification, and Tax ID.",
                         systemImage: "square.and.pencil") { showingEdit = true }

            signatureControls

            if signing {
                Text("Signed with your saved signature, dated today. Review before sending.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Review the details. Print or send the W-9, then sign and date it by hand before giving it to the requester.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            // Details are complete but the document didn't build — show a clear retry instead of a
            // blank screen with print/send instructions and nothing to share.
            DocumentGenerationError { regenerate() }
            DocActionRow(title: "Update tax details",
                         subtitle: "Name, classification, and Tax ID.",
                         systemImage: "square.and.pencil") { showingEdit = true }
        }
    }

    @ViewBuilder
    private var signatureControls: some View {
        if hasUserSignature {
            // Off by default; flipping it on prompts Face ID first (see signatureInclusion).
            Toggle("Include signature and date.", isOn: signatureInclusion)
                .tint(gold)
                .padding(GLLayout.rowContentPadding)
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
        guard await BiometricGate.authenticateInSession(
            reason: mbLoc("Unlock your saved signature to add it to your W-9.")) else { return }
        if let data = identity.signatureData { signatureImage = UIImage(data: data) }
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
            Text("Your W-9 already uses the business name and address from My Business Details. To complete it, just add:")
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)
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
            .padding(GLLayout.rowContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()

            Button {
                showingEdit = true
            } label: {
                Text("Add tax details")
                    .font(.headline)
                    .foregroundStyle(GLTheme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(GLLayout.rowContentPadding)
                    .glCardBackground()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 32)
    }

    private func regenerate() {
        guard profile.w9IsComplete else {
            W9PDF.cleanUp()   // details went incomplete — drop any TIN-bearing file left on disk
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
