//
//  ContractorPackage.swift
//  GLSmallBusiness
//
//  One button per customer that assembles everything a GC asks a contractor for — the customer's
//  Certificate of Liability Insurance, a W-9, workers'-comp insurance or exemption, and a license —
//  into a single shareable PDF. Mirrors the Generate-a-W-9 flow: see the documents before sharing,
//  with the controls below and Share in the navbar.
//
//  The General Liability COI is THIS customer's certificate, issued by the insurer with the customer
//  named as the holder, so it's included exactly as uploaded — nothing is stamped or altered. If the
//  customer has no COI on file yet, the sheet leads with an upload step before anything can be
//  shared. The Workers' Comp certificate is holder-named the same way, so it's per-customer too
//  (`Customer.wcCoiData`) — optional, uploaded here, never a gate. Everything else (W-9, workers'-comp
//  exemption, license) is general and pulled from the business profile.
//
//  GCs sometimes ask for extras beyond the standard set (an OSHA card, a signed vendor agreement, …),
//  so the package also carries per-customer additional documents (`CustomerDocument`) — uploaded
//  here, each with its own include toggle, merged after the standard documents in upload order.
//

import SwiftUI
import GoldLifeUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers
import MessageUI

struct ContractorPackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    /// The signature is the person's, so it lives in their Gold Life ID (law 48a).
    private let identity = MBIdentity.shared
    @Query private var allCustomers: [Customer]
    let customer: Customer
    let profile: BusinessProfile

    /// False once this customer is deleted out from under the view (e.g. on another device) —
    /// without it, "Upload COI" would write onto the deleted model and the upload silently vanish.
    private var stillExists: Bool {
        allCustomers.contains { $0.persistentModelID == customer.persistentModelID }
    }

    @State private var includeW9: Bool
    @State private var includeWCCOI: Bool
    @State private var includeWCExemption: Bool
    @State private var includeLicense: Bool

    // The bundled W-9 prints the owner's full SSN/EIN, so — like "Generate a W-9" and the
    // 1099-NEC — nothing TIN-bearing is rendered until Face ID succeeds. Until then the package
    // is built without the W-9.
    @State private var tinUnlocked = false

    // W-9 signing — opt-in, mirroring the standalone W-9 sheet: off by default, Face ID unlocks the
    // saved signature, and it's the person's signature so it lives in their Gold Life ID.
    @State private var signW9 = false
    @State private var signatureUnlocked = false
    @State private var signatureImage: UIImage?
    @State private var showingSignatureEditor = false

    @State private var packageURL: URL?

    @State private var showingDocuments = false
    @State private var showingW9Edit = false
    @State private var showingPreview = false
    /// The Mail composer for the package — the ONE sender that used to have no
    /// email path of its own, so it could carry neither the logo nor the
    /// signature block (share-sheet text is plain).
    @State private var showingMail = false
    @State private var showingProfilePrompt = false

    /// Which slot the shared file importer fills. The COI and the package extras share ONE
    /// `.fileImporter` — SwiftUI silently presents only the last of several stacked `.fileImporter`
    /// modifiers on the same view (the ComplianceDocsManagerSheet lesson). Kept separate from
    /// `showingImporter` so dismissing the importer can't clear the target before the completion
    /// handler reads it.
    private enum ImportTarget {
        case coi
        case wcCoi
        case extraDocument
    }
    @State private var importTarget: ImportTarget?
    @State private var showingImporter = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?

    /// The per-customer extra whose detail (view / share / replace / remove) is pushed.
    @State private var selectedExtra: CustomerDocument?

    init(customer: Customer, profile: BusinessProfile) {
        self.customer = customer
        self.profile = profile
        _includeW9 = State(initialValue: profile.w9IsComplete)
        _includeWCCOI = State(initialValue: customer.hasWCCOI)
        _includeWCExemption = State(initialValue: profile.hasWCExemption)
        _includeLicense = State(initialValue: profile.hasLicenseDocument)
    }

    private var gold: Color { GLTheme.accentFill }
    private var canShare: Bool { customer.hasCOI && packageURL != nil }

    /// A business name plus at least one way to be reached — the bar for putting this document in
    /// front of a customer. `BusinessProfile.isComplete` owns the rule; this is just the read.
    private var profileIsComplete: Bool { profile.isComplete }

    /// Whether the toolbar's share control holds more than one row, so it is a Menu. With a
    /// complete profile and no way to email the package (no customer email, or no Mail account),
    /// the only row would be "Share package…", and law 51 promotes a one-item menu to the action
    /// itself (audit 2026-10-03 F128). An incomplete profile keeps the menu: its setup row
    /// replaces Email, beside Share.
    static func shareNeedsMenu(profileIsComplete: Bool, customerEmail: String, canSendMail: Bool) -> Bool {
        !profileIsComplete || (!customerEmail.isEmpty && canSendMail)
    }

    /// "Share package…": a row in the share menu, or the toolbar button itself (icon only) when
    /// it is the only action.
    private func packageShareLink(_ url: URL) -> some View {
        MBShareLink(item: url,
                    subject: Text(ContractorPackageMessage.subject(business: profile)),
                    message: Text(ContractorPackageMessage.body(business: profile)),
                    operation: .generateContractorPackage,
                    refused: $readOnlyRefusal) {
            Label("Share package…", systemImage: "square.and.arrow.up")
        }
    }
    private var hasUserSignature: Bool { identity.signatureData != nil }
    /// True once the user opted in to signing and unlocked the signature with Face ID.
    private var signingW9: Bool { signW9 && signatureUnlocked && signatureImage != nil }

    /// The per-customer extras, oldest first — the order they're merged into the package.
    private var extraDocuments: [CustomerDocument] { customer.sortedPackageDocuments }

    /// Extras toggled OFF for this package. Ephemeral, like the standard-document toggles: every
    /// open starts with everything on file included.
    @State private var excludedExtras: Set<PersistentIdentifier> = []
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    /// The extras that will actually be merged, in order.
    private var includedExtras: [CustomerDocument] {
        extraDocuments.filter { !excludedExtras.contains($0.persistentModelID) }
    }

    /// Include/exclude toggle for one extra — mirrors the workers'-comp/license toggles.
    private func extraInclusion(_ doc: CustomerDocument) -> Binding<Bool> {
        Binding(
            get: { !excludedExtras.contains(doc.persistentModelID) },
            set: { wantsOn in
                if wantsOn {
                    excludedExtras.remove(doc.persistentModelID)
                } else {
                    excludedExtras.insert(doc.persistentModelID)
                }
            }
        )
    }

    /// Everything the generated PDF depends on, in one Equatable value, so a single `onChange`
    /// rebuilds the package. `coi` flips when the customer's certificate is uploaded or removed;
    /// `extras` changes when a per-customer additional document is added, removed, or toggled (a
    /// replace keeps the id, so the extra-detail screen regenerates on pop instead — see
    /// `selectedExtra`).
    private struct RegenKey: Equatable {
        var coi: Bool
        var wcCoi: Bool
        var w9: Bool; var sign: Bool; var wcIns: Bool; var wcExe: Bool; var license: Bool
        var extras: [PersistentIdentifier]
    }
    private var regenKey: RegenKey {
        RegenKey(coi: customer.hasCOI, wcCoi: customer.hasWCCOI, w9: includeW9, sign: signingW9,
                 wcIns: includeWCCOI, wcExe: includeWCExemption, license: includeLicense,
                 extras: includedExtras.map(\.persistentModelID))
    }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Contractor Package"), noun: "this customer") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                if customer.hasCOI {
                    readyContent
                } else {
                    noCOIContent
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Contractor Package")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Contractor Package"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if canShare, let packageURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if Self.shareNeedsMenu(profileIsComplete: profileIsComplete,
                                               customerEmail: customer.email,
                                               canSendMail: MFMailComposeViewController.canSendMail()) {
                            Menu {
                                // The SEND row is gated on the PROFILE, not on the assembled PDF. A blank
                                // letterhead renders perfectly well, so a package existing proves nothing
                                // about whether it is fit to put in front of a GC — and this is the packet
                                // that introduces the business. Share stays open either way (the deliberate
                                // don't-dead-end call): it hands the file to another app on this device, it
                                // doesn't put it on the wire. Matches EstimateDetailScreen exactly.
                                //
                                // Email FIRST: it is the one path that carries the logo
                                // and signature (HTML), matching every other document
                                // sender in the app. The share sheet stays for AirDrop,
                                // Messages and third-party apps, which are plain text.
                                if profileIsComplete {
                                    if !customer.email.isEmpty && MFMailComposeViewController.canSendMail() {
                                        Button {
                                            if ReadOnlyGate.allows(.sendDocument, into: $readOnlyRefusal) {
                                                showingMail = true
                                            }
                                        } label: { Label("Email package", systemImage: "envelope") }
                                    }
                                } else {
                                    // One tappable row instead of Email — never a dead control, and it
                                    // names the fix (the alert it opens says exactly which fields).
                                    Button { showingProfilePrompt = true } label: {
                                        Label("Set up business profile to send", systemImage: "exclamationmark.circle")
                                    }
                                }
                                packageShareLink(packageURL)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        } else {
                            // One action, so the action itself (law 51): no one-item menu.
                            packageShareLink(packageURL)
                                .labelStyle(.iconOnly)
                        }
                    }
                    .tint(gold)
                    // The DeletedRecordView overlay only covers the content area — the nav bar
                    // stays tappable, so don't share a deleted customer's package.
                    .disabled(!stillExists)
                }
            }
        }
        .onAppear {
            regenerate()   // the W-9 is excluded from packageSources() until Face ID unlocks it
            if includeW9 && !tinUnlocked {
                Task { await unlockW9OnAppear() }
            }
        }
        .onDisappear { ContractorPackagePDF.cleanUp() }   // packages can embed the full-TIN W-9
        .onChange(of: regenKey) { _, _ in regenerate() }
        .onChange(of: showingSignatureEditor) { _, isShowing in
            // When the signature editor closes: removal resets signing; a change refreshes the
            // image if already unlocked. Adding a signature never auto-enables signing.
            guard !isShowing else { return }
            if identity.signatureData == nil {
                signW9 = false; signatureUnlocked = false; signatureImage = nil
            } else if signatureUnlocked {
                signatureImage = identity.signatureData.flatMap { UIImage(data: $0) }
            }
            regenerate()
        }
        // One importer for both slots. Two stacked `.fileImporter`s would leave one dead.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            importFile(result)
        }
        .fileImportFailureAlert($importFailure)
        .alert("Complete your business profile", isPresented: $showingProfilePrompt) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your business name and a phone or email in Menu → My Business Details so they appear on your documents.")
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
        .navigationDestination(item: $selectedExtra) { doc in
            CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName)
        }
        // Regenerate on pop — a replace keeps the doc's id, so RegenKey alone wouldn't catch it.
        .onChange(of: selectedExtra) { _, selected in
            if selected == nil { regenerate() }
        }
        .sheet(isPresented: $showingSignatureEditor) {
            SignatureEditorSheet().glAppearance(colorScheme)
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
        .sheet(isPresented: $showingMail) {
            MailComposeView(
                recipients: [customer.email],
                subject: ContractorPackageMessage.subject(business: profile),
                body: ContractorPackageMessage.htmlBody(business: profile),
                isHTML: true,
                attachmentURL: packageURL
            ) { _ in showingMail = false }
            .ignoresSafeArea()
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
                    .foregroundStyle(GLTheme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(GLLayout.rowContentPadding)
                    .glCardBackground()
            }
            .buttonStyle(.plain)
        } else {
            // Assembly failed even though a certificate is on file — an upload whose
            // bytes are neither a PDF nor a readable image passes `hasCOI` (which only
            // asks whether bytes exist) but merges to nothing. Without this the screen
            // showed the full ready state with no Preview, no Share, and a footnote
            // telling the owner to tap a Share button that wasn't there. Same
            // treatment the W-9, invoice, change-order and 1099 sheets already give
            // this case.
            DocumentGenerationError { regenerate() }
        }
        // Only promise a Share button when there is one.
        if packageURL != nil {
            Text("Review the package above, then tap Share to send everything as one PDF.")
                .font(.footnote)
                .foregroundStyle(GLTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var includedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("In this package", systemImage: "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GLTheme.accentText)

            includedRow(systemImage: "checkmark.shield", title: "Certificate of Insurance",
                        subtitle: coiSubtitle, required: true)
            Button { importTarget = .coi; showingImporter = true } label: {
                Label("Replace COI", systemImage: "arrow.up.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GLTheme.accentText)
                    .frame(minHeight: 44)   // law 16: a full 44 pt target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 40)

            Divider()

            if profile.w9IsComplete {
                includedToggle(systemImage: "doc.plaintext", title: "W-9",
                               subtitle: "Generated from your tax details.", isOn: w9Inclusion)
                if includeW9 { w9SignatureControl }
            } else {
                missingRow(systemImage: "doc.plaintext", title: "W-9",
                           subtitle: "Finish your tax details to include it.") { showingW9Edit = true }
            }

            // The Workers' Comp certificate is insurer-issued naming this customer as the holder —
            // per-customer like the General Liability COI above, but optional (never a gate).
            if customer.hasWCCOI {
                includedToggle(systemImage: "cross.case", title: "Workers’ Comp Insurance",
                               subtitle: wcCoiSubtitle, isOn: $includeWCCOI)
                Button { importTarget = .wcCoi; showingImporter = true } label: {
                    Label("Replace certificate", systemImage: "arrow.up.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GLTheme.accentText)
                        .frame(minHeight: 44)   // law 16: a full 44 pt target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 40)
            } else {
                uploadRow(systemImage: "cross.case", title: "Workers’ Comp Insurance",
                          subtitle: "Upload this customer’s certificate to include it.") {
                    importTarget = .wcCoi
                    showingImporter = true
                }
            }
            if profile.hasWCExemption {
                includedToggle(systemImage: "shield.lefthalf.filled", title: "Workers’ Comp Exemption",
                               subtitle: nil, isOn: $includeWCExemption)
            }
            if profile.hasLicenseDocument {
                includedToggle(systemImage: "person.text.rectangle", title: "Contractor License",
                               subtitle: nil, isOn: $includeLicense)
            }

            ForEach(extraDocuments) { extraDocRow($0) }

            Divider()
            Button { importTarget = .extraDocument; showingImporter = true } label: {
                Label("Add another document", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GLTheme.accentText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { showingDocuments = true } label: {
                Label("Manage insurance & licensing", systemImage: "tray.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GLTheme.accentText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    private var coiSubtitle: LocalizedStringKey {
        uploadedSubtitle(name: customer.coiName, data: customer.coiData, expiresOn: customer.coiExpiresOn)
    }

    private var wcCoiSubtitle: LocalizedStringKey {
        uploadedSubtitle(name: customer.wcCoiName, data: customer.wcCoiData, expiresOn: customer.wcCoiExpiresOn)
    }

    /// Subtitle for an uploaded certificate. A file whose bytes are neither a PDF nor a
    /// readable image is skipped when the package is assembled — and skipped SILENTLY,
    /// because the package still builds out of whatever else is included. The row is the
    /// only place the owner can find out before sending a package that is missing the
    /// certificate it exists to carry.
    private func uploadedSubtitle(name: String, data: Data?, expiresOn: Date? = nil) -> LocalizedStringKey {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // AN EXPIRED CERTIFICATE IS THE ONE THING THIS SCREEN MUST NOT SEND QUIETLY.
        // The package goes to a general contractor, who rejects a lapsed certificate on
        // sight — and before expiry was modelled at all, this row happily said "sent as
        // provided" about a document that expired months ago. Said first, before the
        // readability check, because an expired file is a problem even when it opens fine.
        if GLCertificateStatus.isExpired(expiresOn) {
            return trimmed.isEmpty
                ? "This certificate has expired. Send it and your customer will likely reject it — upload a current one first."
                : "\(trimmed) — EXPIRED. Send it and your customer will likely reject it; upload a current one first."
        }
        guard let data, CompliancePDF.looksReadable(data) else {
            return trimmed.isEmpty
                ? "This isn’t a PDF or a photo we can open, so it won’t be included. Replace it to send it."
                : "\(trimmed) — not a PDF or a photo we can open, so it won’t be included. Replace it to send it."
        }
        if GLCertificateStatus.isExpiringSoon(expiresOn), let when = GLCertificateStatus.caption(expiresOn) {
            return trimmed.isEmpty ? "\(when) — still valid, but renew it soon."
                                   : "\(trimmed) — \(when), still valid but renew it soon."
        }
        return trimmed.isEmpty
            ? "Issued to \(customer.listDisplayName), sent as provided."
            : "\(trimmed) — sent as provided."
    }

    /// Opt-in W-9 signing, shown indented under the W-9 row. Mirrors the standalone W-9 sheet.
    @ViewBuilder
    private var w9SignatureControl: some View {
        Group {
            if hasUserSignature {
                Toggle(isOn: signatureInclusion) {
                    signatureLabel("Sign the W-9", "Add your saved signature and today’s date.")
                }
                .tint(gold)
            } else {
                Button { editSignature() } label: {
                    HStack(spacing: 12) {
                        signatureLabel("Add a signature", "Sign the bundled W-9 automatically.")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                            .accessibilityHidden(true)
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
        }
    }

    /// Enabling runs Face ID first (the W-9 carries the full SSN/EIN) and only turns on after it
    /// succeeds; disabling just drops the W-9 from the package. Mirrors the signature toggle below.
    private var w9Inclusion: Binding<Bool> {
        Binding(
            get: { includeW9 },
            set: { wantsOn in
                if wantsOn {
                    Task { await enableW9() }
                } else {
                    includeW9 = false
                }
            }
        )
    }

    private func enableW9() async {
        guard profile.w9IsComplete else { return }
        if !tinUnlocked {
            guard await BiometricGate.authenticateInSession(
                reason: mbLoc("Unlock to include your W-9.")) else { return }
            tinUnlocked = true
        }
        includeW9 = true
        regenerate()
    }

    /// The W-9 defaults to included, so entering the screen prompts for Face ID once; declining
    /// flips the toggle off (visibly) — turning it back on re-prompts.
    private func unlockW9OnAppear() async {
        if await BiometricGate.authenticateInSession(
            reason: mbLoc("Unlock to include your W-9.")) {
            tinUnlocked = true
        } else {
            includeW9 = false
        }
        regenerate()
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
        guard await BiometricGate.authenticateInSession(
            reason: mbLoc("Unlock your saved signature to sign the W-9.")) else { return }
        if let data = identity.signatureData { signatureImage = UIImage(data: data) }
        signatureUnlocked = true
        signW9 = true
        regenerate()
    }

    private func editSignature() {
        // The person tapped this, and the only thing the editor it opens can do is WRITE a
        // signature — so the refusal belongs here, out loud, rather than three taps later on the
        // editor's Save. The editor saves into the Gold Life ID; no local row is created.
        guard ReadOnlyGate.allows(.saveSignature, into: $readOnlyRefusal) else { return }
        showingSignatureEditor = true
    }

    private func includedRow(systemImage: String, title: LocalizedStringKey,
                             subtitle: LocalizedStringKey?, required: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                .accessibilityHidden(true)
        }
        // One element: the title, the note, then "Included" (what the seal shows).
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Included"))
    }

    private func includedToggle(systemImage: String, title: LocalizedStringKey,
                                subtitle: LocalizedStringKey?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary) }
            }
            Spacer(minLength: 8)
            // Named by the row's title, so VoiceOver says "W-9, switch, on" (it said only
            // "switch, on": audit 2026-10-03 F55). The label stays hidden on screen.
            Toggle(isOn: isOn) { Text(title) }.labelsHidden().tint(gold)
        }
    }

    /// One per-customer extra. The include toggle mirrors the workers'-comp/license rows; the label
    /// area is tappable and pushes view / share / replace / remove.
    private func extraDocRow(_ doc: CustomerDocument) -> some View {
        HStack(spacing: 12) {
            Button { selectedExtra = doc } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperclip").font(.title3).frame(width: 28).foregroundStyle(gold)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name.isEmpty ? mbLoc("Document") : doc.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Tap to view, replace, or remove.")
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Toggle(isOn: extraInclusion(doc)) {
                Text(verbatim: doc.name.isEmpty ? mbLoc("Document") : doc.name)
            }
            .labelsHidden()
            .tint(gold)
        }
    }

    private func missingRow(systemImage: String, title: LocalizedStringKey,
                            subtitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(GLTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.textSecondary)
                    Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
    }

    /// Like `missingRow`, but the action uploads a file here (arrow, not chevron) instead of pushing
    /// a screen. Used for the optional per-customer Workers' Comp certificate.
    private func uploadRow(systemImage: String, title: LocalizedStringKey,
                           subtitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).frame(width: 28).foregroundStyle(GLTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.textSecondary)
                    Text(subtitle).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.doc").font(.footnote.weight(.semibold)).foregroundStyle(gold)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - No COI yet

    private var noCOIContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(gold)
                .accessibilityHidden(true)
            Text("Add this customer’s COI")
                .font(.title3.weight(.semibold))
            Text("The package is built around the Certificate of Liability Insurance your insurer issued with \(customer.listDisplayName) named as the certificate holder. Upload it once, here, and you can send their full package.")
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { importTarget = .coi; showingImporter = true } label: {
                Text("Upload COI")
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

    // MARK: - Generation

    private func refreshAvailability() {
        includeWCCOI = customer.hasWCCOI
        includeWCExemption = profile.hasWCExemption
        includeLicense = profile.hasLicenseDocument
        // Auto-include the W-9 only once Face ID has unlocked it; otherwise leave the toggle off
        // and let the user opt in (which prompts for Face ID via w9Inclusion).
        if profile.w9IsComplete, tinUnlocked { includeW9 = true }
        regenerate()
    }

    private func importFile(_ result: Result<URL, Error>) {
        let target = importTarget
        importTarget = nil
        guard case .success(let url) = result else { return }
        // The customer can be deleted (on another device) while the file picker is up — don't
        // write the upload onto the deleted model, where it would silently vanish on next sync.
        guard stillExists else { return }
        guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
        // Size-checked first, then read off the main thread (F124).
        Task {
            switch await FileImport.read(url) {
            case .success(let data): store(data, name: url.lastPathComponent, as: target)
            case .failure(let failure): importFailure = failure
            }
        }
    }

    private func store(_ data: Data, name: String, as target: ImportTarget?) {
        // The customer may have been deleted while the file was read.
        guard stillExists else { return }
        // DocumentService stores and saves — the same path as the certificate screens.
        do {
            switch target {
            case .coi:
                try DocumentService.set(.customerCertificate(customer, .generalLiability), data: data,
                                        name: name, in: modelContext)
            case .wcCoi:
                try DocumentService.set(.customerCertificate(customer, .workersComp), data: data,
                                        name: name, in: modelContext)
                includeWCCOI = true   // just uploaded for this package, so include it
            case .extraDocument:
                try DocumentService.addPackageExtra(data, name: name, to: customer,
                                                    in: modelContext)
            case .none:
                break
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
        regenerate()
    }

    private func packageSources() -> [Data] {
        var sources: [Data] = []
        // The customer's COI goes in exactly as uploaded — it already names them as the holder.
        if let coi = customer.coiData { sources.append(coi) }
        // tinUnlocked is required here (not just at the toggle) so the full SSN/EIN can never be
        // stamped into a PDF without Face ID, whatever path set includeW9.
        if includeW9, tinUnlocked, profile.w9IsComplete,
           let url = W9PDF.render(profile,
                                  signatureImage: signingW9 ? signatureImage : nil,
                                  signedDate: signingW9 ? Date() : nil),
           let data = try? Data(contentsOf: url) {
            sources.append(data)
        }
        // This customer's insurer-issued Workers' Comp certificate — as uploaded, like the COI.
        if includeWCCOI, let data = customer.wcCoiData { sources.append(data) }
        if includeWCExemption, let data = profile.wcExemptionData { sources.append(data) }
        if includeLicense, let data = profile.licenseDocumentData { sources.append(data) }
        // The per-customer extras (those toggled on) ride after the standard documents, in upload order.
        sources.append(contentsOf: includedExtras.compactMap(\.data))
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

// MARK: - Per-customer extra document detail

/// View / replace / remove one per-customer package extra — the shared insurance-document flow,
/// backed by a `CustomerDocument`. Removing it deletes the document record (not just its bytes),
/// which is also how it leaves the package. Mirrors `JobDocumentDetailScreen`.
struct CustomerDocumentDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
    let document: CustomerDocument
    let businessName: String

    var body: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: document.name.isEmpty ? mbLoc("Document") : document.name,
            data: document.data,
            name: document.name,
            fallbackFileName: "Document.pdf",
            businessName: businessName,
            removeTitle: "Remove document",
            removeSubtitle: "Take this document out of the customer’s package.",
            // DocumentDetailScreen has already gated (and refused out loud); `try?` here only
            // drops a write DocumentService finds impossible (the document went away).
            store: { data, name in
                try? DocumentService.set(.packageExtra(document), data: data, name: name, in: modelContext)
            }
        ))
    }
}
