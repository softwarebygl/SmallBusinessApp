//
//  SubcontractorDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  One subcontractor: the year-to-date 1099 status up top, then the payment history. Payments are
//  added/edited through the pushed screens defined at the bottom. Mirrors EmployeeDetailScreen's scaffold.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import PhotosUI

struct SubcontractorDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let subcontractor: Subcontractor

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.subcontractor, subcontractor, label: subcontractor.fullName, in: modelContext)
    }

    @State private var activeSheet: ActiveSheet?
    @State private var showingEdit = false
    @State private var showingSaveToContacts = false
    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal SubcontractorService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var photoLoadFailed = false
    /// "Remove Photo" waits for the standard alert (law 8a).
    @State private var confirmingPhotoRemoval = false

    private enum ActiveSheet: Identifiable, Hashable {
        case payment(SubPayment?)
        case payNow
        case form1099
        case w9
        case coi
        case allActivity
        var id: String {
            switch self {
            case .payment(let p): "payment-\(p?.persistentModelID.hashValue ?? 0)"
            case .payNow: "payNow"
            case .form1099: "1099"
            case .w9: "w9"
            case .coi: "coi"
            case .allActivity: "allActivity"
            }
        }
    }

    private var gold: Color { GLTheme.accentFill }

    /// The W-9 / COI row titles: what the row holds while it's empty, "on file" only once it isn't.
    static func w9RowTitle(onFile: Bool) -> String { onFile ? mbLoc("W-9 on file") : mbLoc("Their W-9") }
    static func coiRowTitle(onFile: Bool) -> String {
        onFile ? mbLoc("COI on file") : mbLoc("Their certificate of insurance")
    }

    var body: some View {
        // The shared deleted-record fence (LiveRecordGate): "This subcontractor was removed" once
        // the subcontractor is deleted out from under the view (e.g. on another device).
        LiveRecordGate(subcontractor, title: "Subcontractor") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                moreInfoRow
                GLSection("Payments") {
                    ledgerCard
                }
                GLSection("Tax") {
                    w9Card
                }
                // Subs carried tax fields ONLY. The customer screen next door has an
                // Insurance card, which had already taught the owner where to look —
                // and an uninsured sub is the liability a GC actually asks about.
                GLSection("Insurance") {
                    coiCard
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(subcontractor.listDisplayName))
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(subcontractor.listDisplayName)), for: .scrollContent)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, subcontractor.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button { showingSaveToContacts = true } label: {
                        Label("Save to Phone Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(item: $activeSheet) { sheet in
            switch sheet {
            case .payment(let payment):
                RecordSubPaymentSheet(subcontractor: subcontractor, existing: payment)
            case .payNow:
                PaySubcontractorSheet(subcontractor: subcontractor)
            case .form1099:
                Form1099NECSheet(subcontractor: subcontractor)
            case .w9:
                SubcontractorW9DetailScreen(subcontractor: subcontractor)
            case .coi:
                SubcontractorCOIDetailScreen(subcontractor: subcontractor)
            case .allActivity:
                AllActivitySheet(subcontractor: subcontractor)
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            SubcontractorFormScreen.editingLive(subcontractor)
        }
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: subcontractor)) { showingSaveToContacts = false }
                .ignoresSafeArea()
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            // Shrunk to 1024 px, upright, off the main thread before the crop screen holds it
            // (Photo Intake Memory Defense, law 62): a 48 MP pick is never decoded at full size.
            guard let data = try? await photoItem.loadTransferable(type: Data.self),
                  let picked = await ImageDownsampler.intakeImage(from: data) else {
                self.photoItem = nil
                photoLoadFailed = true
                return
            }
            imageToCrop = CroppableImage(image: picked)
            self.photoItem = nil
        }
        .photoLoadFailureAlert($photoLoadFailed)
        .deleteConfirmation($confirmingPhotoRemoval, title: "Remove this photo?", confirm: "Remove") {
            guard ReadOnlyGate.allows(.saveSubcontractor, into: $readOnlyRefusal) else { return }
            setPhoto(nil)
        }
        .fullScreenCover(item: $imageToCrop) { item in
            // The fleet crop screen with a round guide; it draws the 600 px square itself and
            // stays open with an alert if it can't (never saves the uncropped photo).
            GLSquarePhotoCropper(image: item.image, guide: .circle, outputSide: ImageDownsampler.croppedSide) {
                imageToCrop = nil
            } onCropped: { cropped in
                guard ReadOnlyGate.allows(.saveSubcontractor, into: $readOnlyRefusal) else { imageToCrop = nil; return }
                setPhoto(cropped.jpegData(compressionQuality: 0.85))
                imageToCrop = nil
            }
        }
    }

    /// The photo write both photo controls share, through SubcontractorService (gated, saved).
    private func setPhoto(_ data: Data?) {
        do {
            try SubcontractorService.setPhoto(data, for: subcontractor, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ProfileAvatar(imageData: subcontractor.profileImageData, initials: subcontractor.initials,
                              size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            if subcontractor.profileImageData != nil {
                Button("Remove Photo", role: .destructive) {
                    // A lapsed app says so before asking a question it would then refuse.
                    guard ReadOnlyGate.allows(.saveSubcontractor, into: $readOnlyRefusal) else { return }
                    confirmingPhotoRemoval = true
                }
                .font(.subheadline)
            }

            // Title (listDisplayName) is the person; show the business under it so "Boyd Electric"
            // stays visible. Skipped when the business is itself the title (no person on file).
            if !subcontractor.businessName.isEmpty && !subcontractor.fullName.isEmpty {
                Text(subcontractor.businessName).font(.subheadline).foregroundStyle(GLTheme.textSecondary)
            }

            if !subcontractor.isActive {
                Text("Inactive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GLTheme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(GLTheme.textSecondary.opacity(0.18)))
            }
        }
    }

    private var contactCard: some View {
        MBTitledCard(title: "Contact") {
            contactRow("Email", .email, subcontractor.email)
            contactRow("Phone", .phone, subcontractor.phone)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }

    private var moreInfoRow: some View {
        GLHubRow(title: "More Info") { SubcontractorDetailsScreen(subcontractor: subcontractor) }
    }

    // MARK: - Ledger (owed + paid this year, activity, actions — one card)

    private var ledgerCard: some View {
        let year = Calendar.current.component(.year, from: .now)
        let owed = subcontractor.outstanding
        let paid = subcontractor.totalPaid(year: year)
        let needs1099 = subcontractor.requires1099(year: year)
        let entries = subcontractor.sortedPayments
        return MBTitledCard {
            // Owed + paid this year (1099 status)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OWED (UNPAID)")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(GLTheme.textSecondary)
                    Text(owed.formatted(.appMoney))
                        .font(.title2.weight(.semibold))
                        // Same rule as the list row: red only once owed work is past due.
                        .foregroundStyle(subcontractor.owedStatus == .pastDue ? GLTheme.statusCritical : (owed > 0.005 ? GLTheme.accentText : GLTheme.textSecondary))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PAID IN \(String(year))")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(GLTheme.textSecondary)
                    Text(paid.formatted(.appMoney))
                        .font(.title3.weight(.semibold))
                    if needs1099 {
                        Text("1099-NEC due")
                            .font(.caption2.weight(.bold)).foregroundStyle(GLTheme.accentText)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            // Recent activity — no title
            if entries.isEmpty {
                Text("No activity recorded yet.")
                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let recent = Array(entries.prefix(5))
                ForEach(recent) { entry in
                    Button { activeSheet = .payment(entry) } label: { entryRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != recent.last?.id { Divider() }
                }
                if entries.count > 5 {
                    Button("View All") { activeSheet = .allActivity }
                        .font(.subheadline.weight(.medium)).foregroundStyle(GLTheme.accentText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }

            Divider().padding(.vertical, 2)

            // Actions: record (leading) · pay now (trailing)
            HStack {
                Button { activeSheet = .payment(nil) } label: {
                    Label("Record", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { activeSheet = .payNow } label: {
                    Label("Pay now", systemImage: "dollarsign.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(subcontractor.hasOutstanding ? GLTheme.accentText : GLTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!subcontractor.hasOutstanding)
            }
        }
    }

    // MARK: - W-9 & Tax ID

    private var coiCard: some View {
        MBTitledCard(title: "Certificate of insurance") {
            Button { activeSheet = .coi } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield").frame(width: 24).foregroundStyle(gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.coiRowTitle(onFile: subcontractor.coiData != nil))
                        Text(subcontractor.coiData != nil
                             ? (subcontractor.coiName.isEmpty ? mbLoc("Uploaded") : subcontractor.coiName)
                             : mbLoc("Tap to upload theirs"))
                            .font(.caption).foregroundStyle(GLTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                        if subcontractor.coiData != nil, let caption = GLCertificateStatus.caption(subcontractor.coiExpiresOn) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(GLCertificateStatus.isExpired(subcontractor.coiExpiresOn) ? GLTheme.statusCritical
                                                 : (GLCertificateStatus.isExpiringSoon(subcontractor.coiExpiresOn) ? GLTheme.statusAttention
                                                    : GLTheme.textSecondary))
                        }
                    }
                    Spacer()
                    if subcontractor.coiData != nil {
                        Image(systemName: GLCertificateStatus.isExpired(subcontractor.coiExpiresOn) ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(GLCertificateStatus.isExpired(subcontractor.coiExpiresOn) ? GLTheme.statusCritical : gold)
                    }
                    Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var w9Card: some View {
        MBTitledCard(title: "W-9") {
            // Their uploaded W-9 carries the full SSN/EIN on its face, so viewing/sharing it is
            // Face ID-gated like "Generate 1099-NEC" below. With nothing on file yet the screen is
            // just the upload picker — no gate needed to add one.
            Button {
                if subcontractor.hasW9OnFile {
                    Task {
                        if await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to view their W-9.")) {
                            activeSheet = .w9
                        }
                    }
                } else {
                    activeSheet = .w9
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.plaintext").frame(width: 24).foregroundStyle(gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.w9RowTitle(onFile: subcontractor.hasW9OnFile))
                        Text(subcontractor.hasW9OnFile ? subcontractor.w9Name : mbLoc("Tap to upload theirs"))
                            .font(.caption).foregroundStyle(GLTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if subcontractor.hasW9OnFile {
                        Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                    }
                    Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
            Button {
                Task {
                    if await BiometricGate.authenticateInSession(reason: mbLoc("Unlock to generate this 1099-NEC.")) {
                        activeSheet = .form1099
                    }
                }
            } label: {
                Label("Generate 1099-NEC", systemImage: "doc.badge.plus")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
            }
            .buttonStyle(.plain)
        }
    }

    private func entryRow(_ entry: SubPayment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    if !entry.isPaid {
                        Text("OWED")
                            .font(.caption2.weight(.bold)).foregroundStyle(GLTheme.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(gold.opacity(0.16)))
                    }
                }
                let sub = entry.detail.isEmpty ? (entry.customer?.listDisplayName ?? "") : entry.detail
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(GLTheme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(entry.amount.formatted(.appMoney))
                .foregroundStyle(entry.isPaid ? GLTheme.textSecondary : GLTheme.textPrimary)
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

}

// MARK: - All activity sheet (full, date-filterable list)

struct AllActivitySheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let subcontractor: Subcontractor

    private var gold: Color { GLTheme.accentFill }

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
        /// The segment's label in the app's language (found 2026-09-29: `Text(rawValue)` drew
        /// the English words verbatim in Spanish).
        var title: String {
            switch self {
            case .all: return mbLoc("All")
            case .year: return mbLoc("This year")
            case .custom: return mbLoc("Custom")
            }
        }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: SubPayment?
    @State private var searchText = ""

    private var filtered: [SubPayment] {
        let byDate = rangeFilter.apply(to: subcontractor.sortedPayments, date: \.date)
        return searchText.isEmpty ? byDate : byDate.filter { $0.matchesSearch(searchText) }
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var paidTotal: Double { DomainMoney.roundedSum(filtered.filter(\.isPaid).map(\.amount)) }

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "All Activity") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        VStack(spacing: 0) {
            // Segmented at normal sizes; a menu at accessibility sizes, where the three
            // segments truncate their labels. The two styles are different types, so the
            // branch is at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            if range == .custom {
                VStack(spacing: 6) {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .padding(.horizontal, GLLayout.rowCardInset)
                .padding(.bottom, 8)
            }
            List {
                GLInListSearchHeader(text: $searchText, prompt: "Search activity").asPlainListRow
                if filtered.isEmpty {
                    ContentUnavailableView(searchText.isEmpty ? "Nothing in this range" : "No matches",
                                           systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filtered) { entry in
                            Button { editing = entry } label: { row(entry) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                    } footer: {
                        Text(verbatim: "\(mbLoc("\(paidTotal.formatted(.appMoney)) paid")) · \(mbLoc("\(filtered.count) entries"))")
                            .padding(.horizontal, GLLayout.rowCardInset)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
            .dismissesKeyboardOnInteraction()
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .navigationTitle(GLScript.padded(mbLoc("All Activity")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Activity"))), for: .scrollContent)
        .mbSystemBanners()
        .navigationDestination(item: $editing) { entry in
            RecordSubPaymentSheet(subcontractor: subcontractor, existing: entry)
        }
    }

    private func row(_ entry: SubPayment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    if !entry.isPaid {
                        Text("OWED")
                            .font(.caption2.weight(.bold)).foregroundStyle(GLTheme.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(gold.opacity(0.16)))
                    }
                }
                let sub = entry.detail.isEmpty ? (entry.customer?.listDisplayName ?? "") : entry.detail
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(GLTheme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(entry.amount.formatted(.appMoney))
                .foregroundStyle(entry.isPaid ? GLTheme.textSecondary : GLTheme.textPrimary)
        }
        .font(.subheadline)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - W-9 document (view / upload / replace / remove)

/// A thin wrapper over the shared `DocumentDetailScreen`, backed by the subcontractor's uploaded
/// W-9 PDF — mirrors `CustomerCOIDetailScreen`.
struct SubcontractorW9DetailScreen: View {
    @Query private var profiles: [BusinessProfile]
    let subcontractor: Subcontractor

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "W-9") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: mbLoc("W-9"),
            data: subcontractor.w9Data,
            name: subcontractor.w9Name,
            fallbackFileName: "W-9.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove W-9",
            removeSubtitle: "Delete this subcontractor’s uploaded W-9.",
            store: { subcontractor.w9Data = $0; subcontractor.w9Name = $1 }
        ))
    }
}

/// Their certificate of insurance. Copied from SubcontractorW9DetailScreen above, minus the
/// Face ID gate — a COI is a business document, not tax PII, and gating it would train people
/// to swat the prompt away on the one document they check most often.
struct SubcontractorCOIDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    let subcontractor: Subcontractor

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "Certificate of insurance") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: mbLoc("Certificate of insurance"),
            data: subcontractor.coiData,
            name: subcontractor.coiName,
            fallbackFileName: "Certificate-of-Insurance.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove certificate",
            removeSubtitle: "Delete this subcontractor’s uploaded COI.",
            // DocumentDetailScreen gates both writes (and refuses out loud) before calling; `try?`
            // only drops a write DocumentService finds impossible (the record went away).
            store: {
                try? DocumentService.set(.subcontractorCOI(subcontractor), data: $0, name: $1, in: modelContext)
            },
            expiresOn: Binding(get: { subcontractor.coiExpiresOn },
                               set: {
                                   try? DocumentService.setExpiry(.subcontractorCOI(subcontractor), $0,
                                                                  in: modelContext)
                               })
        ))
    }
}

// MARK: - 1099-NEC sheet (generate the real IRS Copy B)

struct Form1099NECSheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    let subcontractor: Subcontractor

    @State private var pdfURL: URL?
    @State private var previewImage: UIImage?
    @State private var showingEditSub = false
    @State private var showingEditBusiness = false
    // Default to the most recent COMPLETED tax year — a 1099-NEC for year N is filed in January of
    // N+1, so the form a contractor actually owes is almost always last year's, not this year's.
    @State private var selectedYear = Calendar.current.component(.year, from: .now) - 1
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    private var gold: Color { GLTheme.accentFill }
    private var business: BusinessProfile? { profiles.first }
    /// Box 1: card and payment-app payments are left out (they go on the 1099-K).
    private var amount: Double { subcontractor.form1099NECAmount(year: selectedYear) }
    private var yearOptions: [Int] {
        let now = Calendar.current.component(.year, from: .now)
        return Array((now - 4)...now).reversed()
    }

    /// What's still needed before a valid 1099-NEC can be produced, in the app's language.
    private var missing: [String] {
        var items: [String] = []
        let name = (business?.w9LegalName.isEmpty == false ? business?.w9LegalName : business?.businessName) ?? ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(mbLoc("Your business name")) }
        if business?.secureTIN.filter({ $0.isASCII && $0.isNumber }).count != 9 { items.append(mbLoc("Your business Tax ID")) }
        if subcontractor.secureTIN.filter({ $0.isASCII && $0.isNumber }).count != 9 {
            items.append(mbLoc("\(subcontractor.payeeName)’s Tax ID (from their W-9)"))
        }
        return items
    }
    private var canGenerate: Bool { missing.isEmpty }

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "1099-NEC") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                yearPicker
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.1)))
                        .shadow(radius: 4, y: 2)
                    Text("Copy B — give this to \(subcontractor.payeeName). Keep a copy for your records. File Copy A with the IRS yourself (e-file) or hand your accountant the Year-End Report.")
                        .font(.footnote).foregroundStyle(GLTheme.textSecondary).multilineTextAlignment(.center)
                    if subcontractor.paidOn1099K(year: selectedYear) > 0.005 {
                        // Why box 1 is less than what was paid this year (IRS 1099-NEC instructions).
                        Text("Card and payment-app payments are reported on Form 1099-K.")
                            .font(.footnote).foregroundStyle(GLTheme.textSecondary).multilineTextAlignment(.center)
                    }
                } else if canGenerate {
                    // Everything's filled in but the form didn't build — a generation failure, not
                    // missing data. Offer a retry instead of an empty "add details" checklist.
                    DocumentGenerationError { regenerate() }
                } else {
                    missingCard
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .navigationTitle(GLScript.padded(mbLoc("1099-NEC")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("1099-NEC"))), for: .scrollContent)
        .mbSystemBanners()
        .toolbar {
            if let pdfURL {
                ToolbarItem(placement: .topBarTrailing) {
                    MBShareLink(item: pdfURL,
                                subject: Text("Form 1099-NEC — \(String(selectedYear))"),
                                message: Text("Attached is your \(String(selectedYear)) Form 1099-NEC."),
                                operation: .generate1099,
                                refused: $readOnlyRefusal) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(gold)
                }
            }
        }
        .onAppear { regenerate() }
        .onDisappear { Form1099NECPDF.cleanUp() }   // full-TIN PDFs must not linger in tmp
        .onChange(of: selectedYear) { _, _ in regenerate() }
        .navigationDestination(isPresented: $showingEditSub) {
            SubcontractorFormScreen.editingLive(subcontractor)
        }
        .onChange(of: showingEditSub) { _, isPresented in
            if !isPresented { regenerate() }
        }
        .navigationDestination(isPresented: $showingEditBusiness) {
            if let business { MyCompanyFormScreen(profile: business) }
        }
        .onChange(of: showingEditBusiness) { _, isPresented in
            if !isPresented { regenerate() }
        }
    }

    private var yearPicker: some View {
        HStack {
            Text("Tax year").font(.subheadline.weight(.medium))
            Spacer()
            Picker("Tax year", selection: $selectedYear) {
                ForEach(yearOptions, id: \.self) { Text(verbatim: String($0)).tag($0) }
            }
            .labelsHidden()
            .tint(gold)
        }
        .padding(GLLayout.rowContentPadding)
        .glCardBackground()
    }

    private var missingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add a few details first", systemImage: "exclamationmark.circle")
                .font(.headline).foregroundStyle(GLTheme.accentText)
            Text("A 1099-NEC needs the following before it can be generated:")
                .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
            ForEach(missing, id: \.self) { item in
                Label(item, systemImage: "circle").font(.subheadline).labelStyle(.titleAndIcon)
            }
            if subcontractor.secureTIN.filter({ $0.isASCII && $0.isNumber }).count != 9 {
                Button { showingEditSub = true } label: {
                    Label("Edit \(subcontractor.payeeName)", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                }
                .buttonStyle(.plain)
            }
            if business != nil {
                Button { showingEditBusiness = true } label: {
                    Label("Edit business details", systemImage: "building.2")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GLLayout.rowContentPadding)
        .glCardBackground()
    }

    private func regenerate() {
        guard canGenerate, let business else { pdfURL = nil; previewImage = nil; return }
        pdfURL = Form1099NECPDF.render(payer: business, recipient: subcontractor, amount: amount, year: selectedYear)
        previewImage = pdfURL.flatMap { Form1099NECPDF.pageImage(from: $0) }
    }
}

// MARK: - Ledger entry sheet (record what you owe, or a payment)

struct RecordSubPaymentSheet: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let subcontractor: Subcontractor
    let existing: SubPayment?

    /// How the entry's amount is specified — mirrors the employee "Log Hours" control: a start/end time
    /// range, a number of hours, or a flat amount. Range/Hours are only offered when the sub has a rate.
    enum EntryMode: String, CaseIterable, Identifiable {
        case range = "Range", hours = "Hours", dollars = "Dollars"
        var id: String { rawValue }
        /// The segment's label in the app's language (`rawValue` stays the stable identity).
        var title: String {
            switch self {
            case .range: return mbLoc("Range")
            case .hours: return mbLoc("Hours")
            case .dollars: return mbLoc("Dollars")
            }
        }
    }

    @State private var mode: EntryMode
    @State private var date: Date
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var hours: Double
    @State private var amount: Double
    @State private var rate: Double
    @State private var detail: String
    @State private var customerID: PersistentIdentifier?
    @State private var isPaid: Bool
    @State private var paidDate: Date
    @State private var method: PaymentMethod
    @State private var confirmDelete = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal SubcontractorService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }
    private var savedRate: Double { subcontractor.hourlyRate }
    /// Whether the Range/Hours modes are offered — decided ONCE at init from the EFFECTIVE rate (the
    /// sub's saved rate, or an existing entry's derived amount ÷ hours). Reading the saved rate live
    /// would coerce an hours entry to Dollars after the rate was cleared to $0, and a note-only
    /// re-save would then silently zero its recorded hours. Internal for tests.
    let hasRate: Bool
    /// Without a usable rate there's no way to turn hours into money, so the entry is always a flat amount.
    private var effectiveMode: EntryMode { hasRate ? mode : .dollars }

    init(subcontractor: Subcontractor, existing: SubPayment?) {
        self.subcontractor = subcontractor
        self.existing = existing
        let d = existing?.date ?? .now
        let cal = Calendar.current
        _mode = State(initialValue: (existing?.hours ?? 0) > 0.005 ? .hours : .dollars)
        _date = State(initialValue: d)
        _startAt = State(initialValue: cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
        _endAt = State(initialValue: cal.date(bySettingHour: 17, minute: 0, second: 0, of: d) ?? d)
        _hours = State(initialValue: existing?.hours ?? 0)
        _amount = State(initialValue: existing?.amount ?? 0)
        // Preserve the entry's ORIGINAL rate when editing. SubPayment stores no rateSnapshot, so derive
        // it from the recorded amount ÷ hours — otherwise a note-only re-save, or an edit after the sub's
        // saved rate later changed, would silently re-price the entry at the current saved rate.
        if let existing, existing.hours > 0.005, existing.amount > 0.005 {
            _rate = State(initialValue: existing.amount / existing.hours)
            // The entry's own derived rate keeps Hours/Range editable even after the sub's saved
            // rate is cleared to $0 — the recorded hours must survive a re-save.
            hasRate = true
        } else {
            _rate = State(initialValue: subcontractor.hourlyRate)
            hasRate = subcontractor.hourlyRate > 0
        }
        _detail = State(initialValue: existing?.detail ?? "")
        _customerID = State(initialValue: existing?.customer?.persistentModelID)
        _isPaid = State(initialValue: existing?.isPaid ?? false)
        _paidDate = State(initialValue: existing?.paidDate ?? .now)
        // Most people pay the same way every time — default to how the last payment went out.
        _method = State(initialValue: existing?.method
                        ?? subcontractor.sortedPayments.first(where: \.isPaid)?.method ?? .check)
    }

    /// Hours from the start/end range (end may be the next day for overnight work).
    private var rangeHours: Double { max(0, endAt.timeIntervalSince(startAt) / 3600) }
    private var selectedCustomer: Customer? { customers.first { $0.persistentModelID == customerID } }

    private var saveDisabled: Bool {
        switch effectiveMode {
        // Hours need a rate to become an amount; a $0 rate would save a $0 entry. Use Dollars instead.
        case .range: return rangeHours <= 0 || rate <= 0
        case .hours: return hours <= 0 || rate <= 0
        case .dollars: return amount <= 0
        }
    }

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: existing == nil ? "Record Amount" : "Edit Entry") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        Form {
            if hasRate {
                Section {
                    // Segmented at normal sizes; a menu at accessibility sizes, where the three
                    // segments truncate their labels. The two styles are different types, so the
                    // branch is at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            Picker("", selection: $mode) {
                                ForEach(EntryMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Picker("", selection: $mode) {
                                ForEach(EntryMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .listRowBackground(Color.clear)
                    // Zero row insets so the control spans the full card width — matching the rows below.
                    .listRowInsets(EdgeInsets())
                }

                if mode != .dollars {
                    Section {
                        LabeledContent("Pay rate") {
                            AutoClearNumberField(placeholder: "$0.00", value: $rate, style: .currency)
                                .multilineTextAlignment(.trailing)
                        }
                        // Separate full-row button — a control nested in a LabeledContent value slot
                        // doesn't reliably receive taps in a Form. Hidden when the saved rate is $0
                        // (an hours entry kept alive by its derived rate) — "resetting" to $0 would
                        // only dead-end the Save button.
                        if savedRate > 0.005 && abs(rate - savedRate) > 0.005 {
                            Button { rate = savedRate } label: {
                                Label("Reset to saved rate", systemImage: "arrow.uturn.backward")
                                    .font(.subheadline).foregroundStyle(GLTheme.accentText)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        // With no saved rate on the profile (since cleared), the entry's own rate is
                        // the only one in play — don't cite a "$0.00/hr saved rate".
                        if savedRate > 0.005 {
                            Text("Editable — override the rate for this entry if needed. The saved \(savedRate.formatted(.appMoney))/hr won’t change.")
                                .textCase(nil)
                        } else {
                            Text("Editable — override the rate for this entry if needed. Their profile won’t change.")
                                .textCase(nil)
                        }
                    }
                }
            }

            switch effectiveMode {
            case .range:
                Section {
                    DatePicker("Start", selection: $startAt)
                    DatePicker("End", selection: $endAt)
                } footer: {
                    Text("\(rangeHours.formatted(.number.precision(.fractionLength(0...2)))) hrs → \(DomainMoney.roundedToCents(DomainMoney.product(rangeHours, rate)).formatted(.appMoney)). End can be the next day for overnight work.")
                        .textCase(nil)
                }
            case .hours:
                Section {
                    DatePicker("Work date", selection: $date, displayedComponents: .date)
                    LabeledContent("Hours") {
                        AutoClearNumberField(placeholder: "0", value: $hours, style: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    .listRowSeparator(.hidden, edges: .bottom)   // the chip strip below is its own visual edge
                    HStack(spacing: 8) {
                        ForEach([4.0, 6, 8, 10, 12], id: \.self) { h in
                            Button { hours = h } label: { Text(verbatim: "\(Int(h))").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).tint(gold)
                                .accessibilityLabel("\(Int(h)) hours")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: GLLayout.rowContentPadding, bottom: 10, trailing: GLLayout.rowContentPadding))
                    // A quiet raised strip (the palette's raised surface) that closes the card: square
                    // top edges flow from the rows above, rounded bottom corners match the section's own.
                    .listRowBackground(
                        UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 26, bottomTrailing: 26), style: .continuous)
                            .fill(GLTheme.surfaceRaised)
                    )
                } footer: {
                    Text("\(DomainMoney.roundedToCents(DomainMoney.product(hours, rate)).formatted(.appMoney)) at \(rate.formatted(.appMoney))/hr.")
                        .textCase(nil)
                }
            case .dollars:
                Section {
                    DatePicker("Work date", selection: $date, displayedComponents: .date)
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    // When there's no saved rate, this is the only visible mode — say how to unlock the
                    // Range/Hours ways of logging instead of degrading silently.
                    Text(hasRate
                         ? "A flat amount, not tied to hours."
                         : "A flat amount, not tied to hours. Add a pay rate to their profile to log time as hours.")
                        .textCase(nil)
                }
            }

            Section("For") {
                TextField("What was this for? (optional)", text: $detail, axis: .vertical)
                    .lineLimit(1...4)
                Picker("Job / customer", selection: $customerID) {
                    Text("None").tag(PersistentIdentifier?.none)
                    ForEach(customers) { customer in
                        Text(customer.listDisplayName).tag(PersistentIdentifier?.some(customer.persistentModelID))
                    }
                }
            }
            Section {
                Toggle("Paid", isOn: $isPaid)
                if isPaid {
                    DatePicker("Paid on", selection: $paidDate, displayedComponents: .date)
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                }
            } footer: {
                Text(isPaid ? "Counts toward this year’s total and the 1099-NEC."
                            : "Leave off to track it as owed. It won’t count toward the 1099 until you mark it paid.")
                    .textCase(nil)
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete entry") }
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(existing == nil ? mbLoc("Record Amount") : mbLoc("Edit Entry")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(existing == nil ? mbLoc("Record Amount") : mbLoc("Edit Entry"))), for: .scrollContent)
        .alert("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: saveDisabled, action: save)
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        guard ReadOnlyGate.allows(.recordSubcontractorPayment, into: $readOnlyRefusal) else { return false }
        let work: LoggedWork
        switch effectiveMode {
        case .range: work = .range(start: startAt, end: endAt, rate: rate)
        case .hours: work = .hours(hours, on: date, rate: rate)
        case .dollars: work = .dollars(amount, on: date)
        }
        do {
            try SubcontractorService.recordEntry(work, detail: detail, customer: selectedCustomer,
                                                 paidOn: isPaid ? paidDate : nil, method: method,
                                                 for: subcontractor, editing: existing, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }

    private func delete() {
        guard ReadOnlyGate.allows(.deleteSubcontractorPayment, into: $readOnlyRefusal) else { return }
        if let existing {
            do {
                try DeletionService.delete([.subPayment(existing)], origin: .screen, in: modelContext)
            } catch {
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                return
            }
        }
        dismiss()
    }
}

// MARK: - Pay now sheet (settle what's owed) — the subcontractor analog of the employee "Pay Now"

/// Clears a sub's outstanding balance: pay in full, or a partial amount that settles the oldest unpaid
/// entries first (FIFO). Stamps each settled entry's paid date + method. Anything paid beyond what's
/// owed is recorded as its own paid entry so the year-to-date / 1099 total stays exact.
struct PaySubcontractorSheet: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let subcontractor: Subcontractor

    @State private var amount: Double
    @State private var paidDate: Date = .now
    @State private var method: PaymentMethod
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal SubcontractorService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(subcontractor: Subcontractor) {
        self.subcontractor = subcontractor
        _amount = State(initialValue: subcontractor.outstanding)
        // Most people pay the same way every time — default to how the last payment went out.
        _method = State(initialValue: subcontractor.sortedPayments.first(where: \.isPaid)?.method ?? .check)
    }

    private var gold: Color { GLTheme.accentFill }
    private var owed: Double { subcontractor.outstanding }
    private var payingInFull: Bool { amount + 0.005 >= owed && owed > 0.005 }

    private var footer: String { Self.footer(owed: owed, amount: amount, method: method) }

    /// What the Payment footer says for this amount against what's owed.
    static func footer(owed: Double, amount: Double, method: PaymentMethod = .check) -> String {
        let payingInFull = amount + 0.005 >= owed && owed > 0.005
        if owed <= 0.005 { return mbLoc("Nothing is owed right now.") }
        if amount > owed + 0.005 {
            let extra = DomainMoney.remaining(amount, less: owed).formatted(.appMoney)
            // Card and payment-app payments go on the 1099-K, never the 1099-NEC (F86).
            if Subcontractor.isReportedOn1099K(method) {
                return mbLoc("Marks everything owed as paid — the extra \(extra) is recorded as its own paid entry.")
            }
            return mbLoc("Marks everything owed as paid — the extra \(extra) is recorded as its own paid entry and counts toward the 1099.")
        }
        if payingInFull { return mbLoc("Marks everything owed as paid.") }
        if amount > 0.005 { return mbLoc("Applied to the oldest unpaid entries first; the rest stays owed.") }
        return mbLoc("Enter an amount, or tap Pay in full.")
    }

    var body: some View {
        // F24: draws "This subcontractor was removed" once the subcontractor is deleted while open.
        LiveRecordGate(subcontractor, title: "Pay Now") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        Form {
            Section {
                LabeledContent("Owed") {
                    Text(owed.formatted(.appMoney)).foregroundStyle(GLTheme.textSecondary)
                }
                LabeledContent("Amount") {
                    AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                        .multilineTextAlignment(.trailing)
                }
                // When the amount already covers everything owed, say so instead of just graying
                // out — a silent disabled "Pay in full" reads like something still needs doing.
                Button { amount = owed } label: {
                    Text(payingInFull ? "Full amount entered" : "Pay in full").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(gold)
                .disabled(owed <= 0.005 || payingInFull)
            } header: {
                Text("Payment")
            } footer: {
                Text(footer).textCase(nil)
            }
            Section {
                Picker("Method", selection: $method) {
                    ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Paid on", selection: $paidDate, displayedComponents: .date)
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Pay Now")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Pay Now"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: amount <= 0.005, action: save)
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        // Refused up front: recording a payment that arrives AFTER the lapse is named in the ruling
        // as one of the things a read-only app must not do.
        guard ReadOnlyGate.allows(.recordSubcontractorPayment, into: $readOnlyRefusal) else { return false }
        // SubcontractorService owns the rules: oldest owed entries first, a mid-entry payment
        // splits the entry, and any surplus is booked as its own paid entry.
        do {
            try SubcontractorService.payNow(amount, paidDate: paidDate, method: method,
                                            for: subcontractor, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }
}
