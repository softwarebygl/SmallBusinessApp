//
//  ContractorPackage.swift
//  GLSmallBusiness
//
//  One button that assembles everything a GC/sub asks a contractor for — a Certificate of Liability
//  Insurance made out to the requesting holder, a W-9, workers'-comp insurance or exemption, and a
//  license — into a single shareable PDF. Mirrors the Generate-a-W-9 flow: see the documents before
//  sharing, with the holder fields and controls below and Share in the navbar.
//
//  The COI is the General Liability certificate already on file. Because COIs are flattened (the text
//  is painted on, not fillable) and every insurer's layout differs, the holder is *stamped*: the app
//  finds the "CERTIFICATE HOLDER" box, drops the entered holder there, and lets you drag it into exact
//  position on a live preview. "Cover existing holder" lays a white box over any prior holder first.
//

import SwiftUI
import SwiftData
import PDFKit

struct ContractorPackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let profile: BusinessProfile

    // The holder is intentionally NOT seeded from anything — it starts blank for every package so a
    // previous GC can never be sent by accident. Only the box placement on the user's COI is reused.
    @State private var companyName = ""
    @State private var ownerName = ""
    @State private var holderAddress = ""
    @State private var additionalDetails = ""
    @State private var offset: CGSize
    @State private var coverExisting: Bool
    @State private var includeW9: Bool
    @State private var includeWCInsurance: Bool
    @State private var includeWCExemption: Bool
    @State private var includeLicense: Bool

    @State private var coiImage: UIImage?
    @State private var placement: ContractorPackagePDF.HolderPlacement?
    @State private var packageURL: URL?

    @State private var showingDocuments = false
    @State private var showingW9Edit = false

    init(profile: BusinessProfile) {
        self.profile = profile
        _offset = State(initialValue: profile.coiHolderOffset)
        _coverExisting = State(initialValue: profile.coiCoverExistingHolder)
        _includeW9 = State(initialValue: profile.w9IsComplete)
        _includeWCInsurance = State(initialValue: profile.hasWCInsurance)
        _includeWCExemption = State(initialValue: profile.hasWCExemption)
        _includeLicense = State(initialValue: profile.hasLicenseDocument)
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    /// The holder block lines, composed once and shared by the preview and the stamp.
    private var holderLines: [String] {
        ContractorPackagePDF.holderLines(company: companyName, owner: ownerName,
                                         address: holderAddress, details: additionalDetails)
    }
    private var hasHolder: Bool { !holderLines.isEmpty }
    private var canShare: Bool { profile.hasCOI && packageURL != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if profile.hasCOI {
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
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                if canShare, let packageURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: packageURL,
                                  subject: Text(shareSubject),
                                  message: Text(DocumentShareText.body(
                                    "Attached is our contractor package — certificate of insurance, W-9, and supporting documents.",
                                    from: profile.businessName))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(gold)
                    }
                }
            }
            .onAppear { loadCOI(); regenerate() }
            .onChange(of: companyName) { _, _ in regenerate() }
            .onChange(of: ownerName) { _, _ in regenerate() }
            .onChange(of: holderAddress) { _, _ in regenerate() }
            .onChange(of: additionalDetails) { _, _ in regenerate() }
            .onChange(of: offset) { _, _ in regenerate() }
            .onChange(of: coverExisting) { _, _ in regenerate() }
            .onChange(of: includeW9) { _, _ in regenerate() }
            .onChange(of: includeWCInsurance) { _, _ in regenerate() }
            .onChange(of: includeWCExemption) { _, _ in regenerate() }
            .onChange(of: includeLicense) { _, _ in regenerate() }
            .onDisappear { persist() }
            .sheet(isPresented: $showingDocuments, onDismiss: refreshAvailability) {
                ComplianceDocsManagerSheet(profile: profile).glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingW9Edit, onDismiss: refreshAvailability) {
                MyCompanyFormScreen(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyContent: some View {
        holderCard
        placementPreview
        coverToggle
        includedCard
        Text(hasHolder
             ? "Review the certificate above, then tap Share to send everything as one PDF."
             : "Fill in the certificate holder above. Every field is optional — leave out anything that doesn't apply.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var holderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Certificate holder", systemImage: "person.text.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gold)
            Text("Who's requesting this COI. Everything here is optional.")
                .font(.caption).foregroundStyle(.secondary)
            holderField("Company name", text: $companyName, capitalization: .words)
            Divider()
            holderField("Owner name", text: $ownerName, capitalization: .words)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                TextField("Street, City, State ZIP", text: $holderAddress, axis: .vertical)
                    .lineLimit(2...4)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Additional details").font(.caption).foregroundStyle(.secondary)
                TextField("Project, reference #, anything else", text: $additionalDetails, axis: .vertical)
                    .lineLimit(1...3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    private func holderField(_ label: LocalizedStringKey, text: Binding<String>,
                             capitalization: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, axis: .vertical)
                .textInputAutocapitalization(capitalization)
        }
    }

    @ViewBuilder
    private var placementPreview: some View {
        if let coiImage, let placement {
            VStack(spacing: 8) {
                COIPlacementView(image: coiImage, placement: placement,
                                 lines: holderLines,
                                 offset: $offset, coverExisting: coverExisting)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
                    .shadow(radius: 4, y: 2)
                Label(placement.autoDetected
                      ? "Drag the holder block to line it up with the certificate-holder box."
                      : "We couldn't find the holder box automatically — drag the block to position it.",
                      systemImage: placement.autoDetected ? "hand.draw" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(placement.autoDetected ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
            }
        } else {
            ContentUnavailableView("Couldn't preview the COI", systemImage: "doc.questionmark",
                                   description: Text("The General Liability file on file couldn't be opened. Replace it with a PDF or image."))
        }
    }

    private var coverToggle: some View {
        Toggle(isOn: $coverExisting) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cover existing holder").font(.subheadline.weight(.semibold))
                Text("Hide any holder already printed on the COI before stamping the new one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(gold)
        .padding()
        .glCardBackground()
    }

    private var includedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("In this package", systemImage: "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gold)

            includedRow(systemImage: "checkmark.shield", title: "Certificate of Insurance",
                        subtitle: "Stamped with the holder above.", required: true)

            if profile.w9IsComplete {
                includedToggle(systemImage: "doc.plaintext", title: "W-9",
                               subtitle: "Generated from your tax details.", isOn: $includeW9)
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
            Text("Add your insurance certificate")
                .font(.title3.weight(.semibold))
            Text("The package is built around your Certificate of Liability Insurance — the General Liability certificate. Upload it once, then make it out to whoever's requesting it each time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showingDocuments = true } label: {
                Text("Upload insurance")
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

    private var shareSubject: String {
        profile.businessName.isEmpty ? "Contractor Package" : "Contractor Package — \(profile.businessName)"
    }

    private func loadCOI() {
        guard let data = profile.coiData else { coiImage = nil; placement = nil; return }
        coiImage = ContractorPackagePDF.coiPageImage(from: data)
        placement = ContractorPackagePDF.document(from: data).flatMap { ContractorPackagePDF.locateHolder(in: $0) }
    }

    private func refreshAvailability() {
        includeWCInsurance = profile.hasWCInsurance
        includeWCExemption = profile.hasWCExemption
        includeLicense = profile.hasLicenseDocument
        if profile.w9IsComplete { includeW9 = true }
        loadCOI()
        regenerate()
    }

    private func packageSources() -> [Data] {
        var sources: [Data] = []
        if let coi = profile.coiData,
           let stamped = ContractorPackagePDF.stampedCOIData(
                coiData: coi, lines: holderLines,
                offset: offset, coverExisting: coverExisting) {
            sources.append(stamped)
        }
        if includeW9, profile.w9IsComplete,
           let url = W9PDF.render(profile), let data = try? Data(contentsOf: url) {
            sources.append(data)
        }
        if includeWCInsurance, let data = profile.wcInsuranceData { sources.append(data) }
        if includeWCExemption, let data = profile.wcExemptionData { sources.append(data) }
        if includeLicense, let data = profile.licenseDocumentData { sources.append(data) }
        return sources
    }

    private func regenerate() {
        guard profile.hasCOI else { packageURL = nil; return }
        let safeName = profile.businessName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "Contractor-Package\(safeName.isEmpty ? "" : "-\(safeName)").pdf"
        packageURL = ContractorPackagePDF.merge(packageSources(), fileName: fileName)
    }

    /// Saves only the box placement on the user's COI form — never the holder identity, which always
    /// starts blank so a previous GC can't be sent by mistake.
    private func persist() {
        profile.coiHolderOffset = offset
        profile.coiCoverExistingHolder = coverExisting
        try? modelContext.save()
    }
}

// MARK: - Interactive placement preview

/// Shows page 1 of the COI with the holder block overlaid where it will be stamped, draggable so the
/// user can line it up with their insurer's certificate-holder box. The preview mirrors the stamp's
/// geometry (see `ContractorPackagePDF.HolderLayout`) so what's shown matches what's produced; the
/// final stamp uses the exact PDF coordinates, so the preview only needs to be a faithful guide.
private struct COIPlacementView: View {
    let image: UIImage
    let placement: ContractorPackagePDF.HolderPlacement
    let lines: [String]
    @Binding var offset: CGSize
    let coverExisting: Bool

    @GestureState private var drag: CGSize = .zero

    private var aspect: CGFloat { placement.pageSize.width / max(placement.pageSize.height, 1) }

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / max(placement.pageSize.width, 1)
            // Effective anchor (PDF points) = base placement + saved nudge + live drag (display→PDF).
            let liveX = offset.width + drag.width / k
            let liveY = offset.height - drag.height / k          // screen y grows down; PDF y grows up
            let anchorX = (placement.anchor.x + liveX) * k
            let anchorTop = (placement.pageSize.height - (placement.anchor.y + liveY)) * k

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                holderBlock(k: k)
                    .offset(x: anchorX, y: anchorTop - ContractorPackagePDF.HolderLayout.topPadding * k)
                    .gesture(
                        DragGesture()
                            .updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                offset.width += value.translation.width / k
                                offset.height -= value.translation.height / k
                            }
                    )
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    @ViewBuilder
    private func holderBlock(k: CGFloat) -> some View {
        let width = placement.width * k
        let lineHeight = ContractorPackagePDF.HolderLayout.lineHeight * k
        if lines.isEmpty {
            // No holder entered yet — show the target area as a dashed outline.
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: width, height: lineHeight + ContractorPackagePDF.HolderLayout.topPadding * 2 * k)
                .contentShape(Rectangle())
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: (index == 0 ? ContractorPackagePDF.HolderLayout.nameSize
                                                          : ContractorPackagePDF.HolderLayout.bodySize) * k,
                                      weight: index == 0 ? .semibold : .regular))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .frame(width: width, height: lineHeight, alignment: .bottomLeading)
                }
            }
            .background(coverExisting ? Color.white : Color.white.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
        }
    }
}
