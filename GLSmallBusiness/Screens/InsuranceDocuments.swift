//
//  InsuranceDocuments.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Manually-uploaded compliance certificates (PDF or image) — a workers' comp exemption and the
//  contractor license. Uploaded, managed, and shared from the Business screen's "Insurance &
//  Licensing" row (ComplianceDocsManagerSheet). These are the general documents that are the same for
//  every customer; the insurer-issued COIs (General Liability AND Workers' Comp) name their
//  certificate holder, so they're per-customer and live on the Customer.
//  The sheet also offers an optional, owner-only reference COI (a spare blank form) kept purely for the
//  owner's records — never shared with customers or bundled into a package.

import SwiftUI
import GoldLifeUI
import CryptoKit
import SwiftData
import PDFKit
import UniformTypeIdentifiers

// MARK: - Certificate kinds

/// The general compliance certificates, each backed by a pair of `BusinessProfile` properties. These
/// are the same for every customer; the insurer-issued COIs (General Liability and Workers' Comp)
/// name their holder, so they're stored per-customer on the Customer instead.
enum ComplianceKind: String, CaseIterable, Identifiable {
    case wcExemption
    case license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wcExemption: return mbLoc("Workers’ Comp Exemption")   // NOT a certificate — proof you are exempt from carrying coverage
        case .license: return mbLoc("Contractor License")
        }
    }

    var systemImage: String {
        switch self {
        case .wcExemption: return "shield.lefthalf.filled"
        case .license: return "person.text.rectangle"
        }
    }

    var fallbackFileName: String {
        switch self {
        case .wcExemption: return "Workers-Comp-Exemption.pdf"
        case .license: return "Contractor-License.pdf"
        }
    }

    func data(_ profile: BusinessProfile) -> Data? {
        switch self {
        case .wcExemption: return profile.wcExemptionData
        case .license: return profile.licenseDocumentData
        }
    }

    func fileName(_ profile: BusinessProfile) -> String {
        switch self {
        case .wcExemption: return profile.wcExemptionName
        case .license: return profile.licenseDocumentName
        }
    }

    /// When this compliance document lapses. Added 2026-09-01 — a GC rejects an
    /// expired exemption or licence exactly as fast as an expired COI, and until
    /// now only PRESENCE was modelled.
    func expiry(_ profile: BusinessProfile) -> Date? {
        switch self {
        case .wcExemption: return profile.wcExemptionExpiresOn
        case .license: return profile.licenseExpiresOn
        }
    }

    func setExpiry(_ profile: BusinessProfile, _ date: Date?) {
        switch self {
        case .wcExemption: setIfChanged(profile, \.wcExemptionExpiresOn, date)
        case .license: setIfChanged(profile, \.licenseExpiresOn, date)
        }
    }

    /// The field mapping only — no gate, no save. Screens and tools write through
    /// `DocumentService.set(.compliance(_:)…)`, which gates, calls this, and saves.
    func store(_ profile: BusinessProfile, data: Data?, name: String) {
        switch self {
        case .wcExemption:
            setIfChanged(profile, \.wcExemptionData, data)
            setIfChanged(profile, \.wcExemptionName, name)
        case .license:
            setIfChanged(profile, \.licenseDocumentData, data)
            setIfChanged(profile, \.licenseDocumentName, name)
        }
    }
}

enum CompliancePDF {
    /// Writes a certificate to a temp file for sharing; returns its URL. `subdirectory` namespaces
    /// the write (one folder per slot) so two documents uploaded under the same filename — e.g. a
    /// workers'-comp cert and a license both named "Scan.pdf" — can't overwrite each other when the
    /// "share all" bundle writes them side by side.
    static func tempURL(_ data: Data, name: String, fallback: String, subdirectory: String? = nil) -> URL? {
        // Trimmed, so a name that is only whitespace falls back like an empty one.
        // `DocumentDetailScreen.displayName` already trims for what it SHOWS, so an
        // untrimmed check here shared a file literally called " .pdf" while the
        // screen above it displayed the fallback name.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = correctingExtension(of: trimmed.isEmpty ? fallback : trimmed, for: data)
        var directory = FileManager.default.temporaryDirectory
        // Namespace EVERY write, not only the ones that pass a subdirectory. Sharing one
        // document at a time passes none, so two documents that happen to share a filename
        // — a customer's "Scan.pdf" extra and the license's "Scan.pdf" — resolved to the
        // same temp path and the second write replaced the first. Falling back to a folder
        // named for the content means same bytes reuse one file and different bytes never
        // collide, whoever calls.
        directory.appendPathComponent(subdirectory ?? contentFolder(for: data), isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let url = directory.appendingPathComponent(fileName)
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Writes certificates for ONE share, at the tap, into a new send folder (each in its slot's
    /// own subfolder, so same-named uploads can't collide); the share sheet removes the folder
    /// when it closes. nil when nothing could be written.
    static func preparedShare(_ files: [(data: Data, name: String, fallback: String, slot: String)]) -> PreparedShare? {
        guard !files.isEmpty, let folder = SendFiles.makeFolder() else { return nil }
        let urls = files.compactMap { file in
            tempURL(file.data, name: file.name, fallback: file.fallback,
                    subdirectory: folder.lastPathComponent + "/" + file.slot)
        }
        guard !urls.isEmpty else {
            SendFiles.discard(folder)
            return nil
        }
        return PreparedShare(urls: urls, folder: folder)
    }

    /// A stable folder name for a document's bytes. Content-addressed, so it is the same
    /// every time for the same document and different for any other.
    private static func contentFolder(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "doc-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes the filename's extension match what the bytes actually ARE. Uploads are stored
    /// as raw data with whatever name they arrived under, and the shared fallbacks are all
    /// "…​.pdf" — so an unnamed photo of a certificate went out as a .pdf that no PDF reader
    /// could open. A name that already agrees with its bytes is left exactly as it is.
    private static func correctingExtension(of fileName: String, for data: Data) -> String {
        guard let actual = fileExtension(for: data) else { return fileName }
        let current = (fileName as NSString).pathExtension.lowercased()
        // .jpg and .jpeg are the same thing; don't rewrite one into the other.
        if current == actual || (current == "jpeg" && actual == "jpg") { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? "Document" : base) + "." + actual
    }

    /// Whether an upload's bytes look like something the app can actually render — a PDF
    /// or an image it can decode. Deliberately a byte sniff and not a full parse: this is
    /// asked while drawing a row, and parsing a multi-page certificate on every body pass
    /// is the kind of per-render work that freezes a screen.
    nonisolated static func looksReadable(_ data: Data) -> Bool {
        fileExtension(for: data) != nil
    }

    /// Sniffs the format from the leading bytes — the file's own name can't be trusted here,
    /// since it is whatever the document was called when it was picked.
    nonisolated private static func fileExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }                 // %PDF
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }                 // \u{89}PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }                       // JPEG SOI
        // HEIC/HEIF: "ftyp" at offset 4, brand at 8.
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("msf") { return "heic" }
        }
        return nil
    }
}

// MARK: - My Company: upload / manage

/// Upload, replace, or remove the certificate PDFs. Lives on the My Company side; changes commit
/// immediately to the profile (and sync via CloudKit), so the sheet just closes with an X.
struct ComplianceDocsManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let profile: BusinessProfile

    /// Which slot a file is being imported into. Compliance certificates and the owner's reference COI
    /// share ONE `.fileImporter` — SwiftUI silently presents only the last of several stacked
    /// `.fileImporter` modifiers on the same view, which previously left every compliance row dead and
    /// only the reference row working. `importTarget` is kept separate from `showingImporter` so
    /// dismissing the importer can't clear the target before the completion handler reads it.
    private enum ImportTarget {
        case compliance(ComplianceKind)
        case reference
    }
    @State private var importTarget: ImportTarget?
    @State private var showingImporter = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal BusinessProfileService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    /// Whether there is anything to share — a read only; the files are written at the tap.
    private var hasShareableDocuments: Bool {
        ComplianceKind.allCases.contains { $0.data(profile) != nil }
    }

    /// Every uploaded certificate, written for this share only (namespaced per slot: same-named
    /// uploads must not collide in the bundle).
    private func preparedShare() -> PreparedShare? {
        CompliancePDF.preparedShare(ComplianceKind.allCases.compactMap { kind in
            kind.data(profile).map { (data: $0, name: kind.fileName(profile), fallback: kind.fallbackFileName,
                                      slot: kind.rawValue) }
        })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(ComplianceKind.allCases) { card($0) }
                Text("Upload each document once (PDF or image). Tap one to view, share, or replace it — or use the button above to share them all. Stored privately in your Gold Life account.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                referenceCOISection
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("My Insurance & License")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("My Insurance & License"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if hasShareableDocuments {
                ToolbarItem(placement: .topBarTrailing) {
                    MBPreparedShareButton(
                        subject: profile.businessName.isEmpty
                            ? mbLoc("Insurance & Licensing") : mbLoc("Insurance & Licensing — \(profile.businessName)"),
                        message: DocumentShareText.body(
                            "Attached are our current exemption and license documents.", from: profile.businessName),
                        refused: $readOnlyRefusal,
                        prepare: preparedShare) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .tint(gold)
                }
            }
        }
        // One importer for every slot. Two stacked `.fileImporter`s would leave all but one dead.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            let target = importTarget
            importTarget = nil
            guard case .success(let url) = result else { return }
            guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
            // Size-checked first, then read off the main thread (F124).
            Task {
                let data: Data
                switch await FileImport.read(url) {
                case .success(let read): data = read
                case .failure(let failure): importFailure = failure; return
                }
                // DocumentService stores and saves — the path the assistant uses.
                do {
                    switch target {
                    case .compliance(let kind):
                        try DocumentService.set(.compliance(kind), data: data, name: url.lastPathComponent,
                                                profile: profile, in: modelContext)
                    case .reference:
                        try DocumentService.set(.referenceCOI, data: data, name: url.lastPathComponent,
                                                profile: profile, in: modelContext)
                    case .none:
                        break
                    }
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                }
            }
        }
        .fileImportFailureAlert($importFailure)
    }

    /// Uploaded slots push a detail screen (view / share / replace / remove); empty slots upload.
    @ViewBuilder
    private func card(_ kind: ComplianceKind) -> some View {
        let name = kind.fileName(profile)
        let subtitle = kind.data(profile) != nil
            ? (name.isEmpty ? mbLoc("Uploaded") : name)
            : mbLoc("Tap to upload (PDF or image)")
        if kind.data(profile) != nil {
            NavigationLink {
                ComplianceDocDetailScreen(kind: kind, profile: profile)
            } label: {
                Self.cardLabel(title: kind.title, systemImage: kind.systemImage, subtitle: subtitle, uploaded: true,
                               wraps: name.isEmpty)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                importTarget = .compliance(kind)
                showingImporter = true
            } label: {
                Self.cardLabel(title: kind.title, systemImage: kind.systemImage, subtitle: subtitle, uploaded: false,
                               wraps: true)
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
                    .foregroundStyle(GLTheme.textSecondary)
                InfoButton(text: "Optional. A spare, blank Certificate of Insurance kept only for your own records — it’s never sent to customers or added to a package.", topic: "Reference Certificate of Insurance")
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
                    title: mbLoc("Blank COI (your reference copy)"),
                    data: profile.ownerReferenceCOIData,
                    name: profile.ownerReferenceCOIName,
                    fallbackFileName: "Certificate-of-Insurance.pdf",
                    businessName: profile.businessName,
                    removeTitle: "Remove document",
                    removeSubtitle: "Delete this reference copy from your records.",
                    // DocumentDetailScreen has already gated (and refused out loud).
                    store: { try? DocumentService.set(.referenceCOI, data: $0, name: $1, profile: profile, in: modelContext) }
                ))
            } label: {
                Self.cardLabel(title: mbLoc("Blank COI (your reference copy)"),
                          systemImage: "doc.text",
                          // NEVER sent. The real, insurer-issued certificate that names a
                          // customer as the holder lives on that customer, and it is the one
                          // the Contractor Package pulls from. Say so here, because the two
                          // slots used to share a title and this is the one he finds first.
                          subtitle: profile.ownerReferenceCOIName.isEmpty ? mbLoc("Your own copy — never sent to customers") : profile.ownerReferenceCOIName,
                          uploaded: true, wraps: profile.ownerReferenceCOIName.isEmpty)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                importTarget = .reference
                showingImporter = true
            } label: {
                Self.cardLabel(title: mbLoc("Blank COI (your reference copy)"),
                          systemImage: "doc.text",
                          subtitle: mbLoc("Your own reference copy — never sent. Customer certificates live on each customer."),
                          uploaded: false, wraps: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// One upload row. A file-name subtitle stays on one line, cut in the middle so its extension
    /// shows; a sentence (`wraps`) wraps onto as many lines as it needs instead of being cut off.
    static func cardLabel(title: String, systemImage: String, subtitle: String, uploaded: Bool,
                          wraps: Bool = false) -> some View {
        let gold = GLTheme.accentFill
        return HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GLTheme.textSecondary)
                    .lineLimit(wraps ? nil : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: wraps)
            }
            Spacer(minLength: 8)
            if uploaded {
                Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
            } else {
                Image(systemName: "arrow.up.doc").font(.footnote.weight(.semibold)).foregroundStyle(gold)
            }
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }
}

// MARK: - Certificate detail

/// View one uploaded compliance certificate (workers'-comp insurance/exemption or the license). A thin
/// wrapper over the shared `DocumentDetailScreen`, backed by the BusinessProfile through `ComplianceKind`.
struct ComplianceDocDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
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
            // DocumentDetailScreen has already gated (and refused out loud); `try?` only drops a
            // write DocumentService finds impossible (the profile went away).
            store: { try? DocumentService.set(.compliance(kind), data: $0, name: $1,
                                              profile: profile, in: modelContext) },
            expiresOn: Binding(get: { kind.expiry(profile) },
                               set: { try? DocumentService.setExpiry(.compliance(kind), $0, profile: profile,
                                                                     in: modelContext) })
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
            // Shared by four hosts (documents, invoice preview, change orders, job photos), so the
            // next step has to be one they ALL offer — every one of them has a share button.
            ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark",
                                   description: Text("This file can’t be shown here. Tap the share button to open it in another app."))
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
