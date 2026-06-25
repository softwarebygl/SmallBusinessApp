//
//  ContractorPackage.swift
//  GLSmallBusiness
//
//  One button per customer that assembles everything a GC asks a contractor for — the customer's
//  Certificate of Liability Insurance, a W-9, workers'-comp insurance or exemption, and a license —
//  into a single shareable PDF. Mirrors the Generate-a-W-9 flow: see the documents before sharing,
//  with the controls below and Share in the navbar.
//
//  The COI is THIS customer's certificate, issued by the insurer with the customer named as the
//  holder, so it's included exactly as uploaded — nothing is stamped or altered. If the customer has
//  no COI on file yet, the sheet leads with an upload step before anything can be shared. Everything
//  else (W-9, workers'-comp, license) is general and pulled from the business profile.
//

import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContractorPackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query private var userProfiles: [UserProfile]
    let customer: Customer
    let profile: BusinessProfile

    @State private var includeW9: Bool
    @State private var includeWCInsurance: Bool
    @State private var includeWCExemption: Bool
    @State private var includeLicense: Bool

    // W-9 signing — opt-in, mirroring the standalone W-9 sheet: off by default, Face ID unlocks the
    // saved signature, and it's the person's signature so it lives on the UserProfile.
    @State private var signW9 = false
    @State private var signatureUnlocked = false
    @State private var signatureImage: UIImage?
    @State private var showingSignatureEditor = false
    @State private var signatureTarget: UserProfile?

    @State private var packageURL: URL?

    @State private var showingDocuments = false
    @State private var showingW9Edit = false
    @State private var showingPreview = false
    @State private var showingCOIImporter = false
    @State private var coiUploadFailed = false

    init(customer: Customer, profile: BusinessProfile) {
        self.customer = customer
        self.profile = profile
        _includeW9 = State(initialValue: profile.w9IsComplete)
        _includeWCInsurance = State(initialValue: profile.hasWCInsurance)
        _includeWCExemption = State(initialValue: profile.hasWCExemption)
        _includeLicense = State(initialValue: profile.hasLicenseDocument)
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var canShare: Bool { customer.hasCOI && packageURL != nil }
    private var hasUserSignature: Bool { userProfiles.first?.hasSignature ?? false }
    /// True once the user opted in to signing and unlocked the signature with Face ID.
    private var signingW9: Bool { signW9 && signatureUnlocked && signatureImage != nil }

    /// Everything the generated PDF depends on, in one Equatable value, so a single `onChange`
    /// rebuilds the package. `coi` flips when the customer's certificate is uploaded or removed.
    private struct RegenKey: Equatable {
        var coi: Bool
        var w9: Bool; var sign: Bool; var wcIns: Bool; var wcExe: Bool; var license: Bool
    }
    private var regenKey: RegenKey {
        RegenKey(coi: customer.hasCOI, w9: includeW9, sign: signingW9,
                 wcIns: includeWCInsurance, wcExe: includeWCExemption, license: includeLicense)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if customer.hasCOI {
                    readyContent
                } else {
                    noCOIContent
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle("Contractor Package")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if canShare, let packageURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: packageURL,
                              subject: Text(ContractorPackageMessage.subject(business: profile)),
                              message: Text(ContractorPackageMessage.body(business: profile))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .onAppear { regenerate() }
        .onChange(of: regenKey) { _, _ in regenerate() }
        .onChange(of: showingSignatureEditor) { _, isShowing in
            // When the signature editor closes: removal resets signing; a change refreshes the
            // image if already unlocked. Adding a signature never auto-enables signing.
            guard !isShowing else { return }
            if userProfiles.first?.signatureData == nil {
                signW9 = false; signatureUnlocked = false; signatureImage = nil
            } else if signatureUnlocked {
                signatureImage = userProfiles.first?.signatureData.flatMap { UIImage(data: $0) }
            }
            regenerate()
        }
        .fileImporter(isPresented: $showingCOIImporter, allowedContentTypes: [.pdf, .image]) { result in
            importCOI(result)
        }
        .alert("Couldn’t read that file", isPresented: $coiUploadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file couldn’t be opened. Try a different file, or export it as a PDF first.")
        }
        .navigationDestination(isPresented: $showingDocuments) {
            ComplianceDocsManagerSheet(profile: profile)
        }
        .onChange(of: showingDocuments) { _, isPresented in
            if !isPresented { refreshAvailability() }
        }
        .navigationDestination(isPresented: $showingW9Edit) {
            MyCompanyFormScreen(profile: profile)
        }
        .onChange(of: showingW9Edit) { _, isPresented in
            if !isPresented { refreshAvailability() }
        }
        .sheet(isPresented: $showingSignatureEditor) {
            if let signatureTarget {
                SignatureEditorSheet(profile: signatureTarget).glAppearance(colorScheme)
            }
        }
        .sheet(isPresented: $showingPreview) {
            if let packageURL {
                DocumentPreviewSheet(url: packageURL,
                                     title: "Package preview",
                                     subject: ContractorPackageMessage.subject(business: profile),
                                     message: ContractorPackageMessage.body(business: profile))
                    .glAppearance(colorScheme)
            }
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyContent: some View {
        includedCard
        if packageURL != nil {
            Button { showingPreview = true } label: {
                Label("Preview full package", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(gold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .glCardBackground()
            }
            .buttonStyle(.plain)
        }
        Text("Review the package above, then tap Share to send everything as one PDF.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var includedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("In this package", systemImage: "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gold)

            includedRow(systemImage: "checkmark.shield", title: "Certificate of Insurance",
                        subtitle: coiSubtitle, required: true)
            Button { showingCOIImporter = true } label: {
                Label("Replace COI", systemImage: "arrow.up.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(gold)
            }
            .buttonStyle(.plain)
            .padding(.leading, 40)

            Divider()

            if profile.w9IsComplete {
                includedToggle(systemImage: "doc.plaintext", title: "W-9",
                               subtitle: "Generated from your tax details.", isOn: $includeW9)
                if includeW9 { w9SignatureControl }
            } else {
                missingRow(systemImage: "doc.plaintext", title: "W-9",
                           subtitle: "Finish your tax details to include it.") { showingW9Edit = true }
            }

            if profile.hasWCInsurance {
                includedToggle(systemImage: "cross.case", title: "Workers' Comp Insurance",
                               subtitle: nil, isOn: $includeWCInsurance)
            }
            if profile.hasWCExemption {
                includedToggle(systemImage: "shield.lefthalf.filled", title: "Workers' Comp Exemption",
                               subtitle: nil, isOn: $includeWCExemption)
            }
            if profile.hasLicenseDocument {
                includedToggle(systemImage: "person.text.rectangle", title: "Contractor License",
                               subtitle: nil, isOn: $includeLicense)
            }

            Divider()
            Button { showingDocuments = true } label: {
                Label("Manage insurance & licensing", systemImage: "tray.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(gold)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    private var coiSubtitle: LocalizedStringKey {
        let name = customer.coiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? "Issued to \(customer.listDisplayName), sent as provided."
            : "\(name) — sent as provided."
    }

    /// Opt-in W-9 signing, shown indented under the W-9 row. Mirrors the standalone W-9 sheet.
    @ViewBuilder
    private var w9SignatureControl: some View {
        Group {
            if hasUserSignature {
                Toggle(isOn: signatureInclusion) {
                    signatureLabel("Sign the W-9", "Add your saved signature and today's date.")
                }
                .tint(gold)
            } else {
                Button { editSignature() } label: {
                    HStack(spacing: 12) {
                        signatureLabel("Add a signature", "Sign the bundled W-9 automatically.")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
    }

    private func signatureLabel(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "signature").font(.title3).frame(width: 28).foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Enabling runs Face ID first and only turns on after it succeeds; disabling re-locks the signature.
    private var signatureInclusion: Binding<Bool> {
        Binding(
            get: { signW9 },
            set: { wantsOn in
                if wantsOn {
                    Task { await enableSignature() }
                } else {
                    signW9 = false; signatureUnlocked = false; signatureImage = nil
                    regenerate()
                }
            }
        )
    }

    private func enableSignature() async {
        guard hasUserSignature else { return }
        guard await BiometricGate.authenticate(
            reason: String(localized: "Unlock your saved signature to sign the W-9.")) else { return }
        if let data = userProfiles.first?.signatureData { signatureImage = UIImage(data: data) }
        signatureUnlocked = true
        signW9 = true
        regenerate()
    }

    private func editSignature() {
        let target = userProfiles.first ?? {
            let new = UserProfile()
            modelContext.insert(new)
            return new
        }()
        signatureTarget = target
        showingSignatureEditor = true
    }

    private func includedRow(systemImage: String, title: LocalizedStringKey,
                             subtitle: LocalizedStringKey?, required: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
        }
    }

    private func includedToggle(systemImage: String, title: LocalizedStringKey,
                                subtitle: LocalizedStringKey?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(gold)
        }
    }

    private func missingRow(systemImage: String, title: LocalizedStringKey,
                            subtitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - No COI yet

    private var noCOIContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(gold)
            Text("Add this customer's COI")
                .font(.title3.weight(.semibold))
            Text("The package is built around the Certificate of Liability Insurance your insurer issued with \(customer.listDisplayName) named as the certificate holder. Upload it once, here, and you can send their full package.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showingCOIImporter = true } label: {
                Text("Upload COI")
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

    // MARK: - Generation

    private func refreshAvailability() {
        includeWCInsurance = profile.hasWCInsurance
        includeWCExemption = profile.hasWCExemption
        includeLicense = profile.hasLicenseDocument
        if profile.w9IsComplete { includeW9 = true }
        regenerate()
    }

    private func importCOI(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        if let data = url.readSecurityScoped() {
            // Mutating the tracked @Model persists via the context's autosave — matching how the rest
            // of the app writes model data (e.g. profileImageData, ComplianceKind.store).
            customer.coiData = data
            customer.coiName = url.lastPathComponent
            regenerate()
        } else {
            coiUploadFailed = true
        }
    }

    private func packageSources() -> [Data] {
        var sources: [Data] = []
        // The customer's COI goes in exactly as uploaded — it already names them as the holder.
        if let coi = customer.coiData { sources.append(coi) }
        if includeW9, profile.w9IsComplete,
           let url = W9PDF.render(profile,
                                  signatureImage: signingW9 ? signatureImage : nil,
                                  signedDate: signingW9 ? Date() : nil),
           let data = try? Data(contentsOf: url) {
            sources.append(data)
        }
        if includeWCInsurance, let data = profile.wcInsuranceData { sources.append(data) }
        if includeWCExemption, let data = profile.wcExemptionData { sources.append(data) }
        if includeLicense, let data = profile.licenseDocumentData { sources.append(data) }
        return sources
    }

    private func regenerate() {
        guard customer.hasCOI else { packageURL = nil; return }
        let safeCustomer = customer.listDisplayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "Contractor-Package\(safeCustomer.isEmpty ? "" : "-\(safeCustomer)").pdf"
        packageURL = ContractorPackagePDF.merge(packageSources(), fileName: fileName)
    }
}

// MARK: - Full package preview

/// Shows the assembled package PDF (COI + W-9 + workers'-comp + license) so the whole thing can be
