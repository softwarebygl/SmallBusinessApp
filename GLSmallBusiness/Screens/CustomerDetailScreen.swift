//
//  CustomerDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct CustomerDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    let customer: Customer

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.customer, customer, label: customer.listDisplayName, in: modelContext)
    }

    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal CustomerService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var photoLoadFailed = false
    /// "Remove Photo" waits for the standard alert (law 8a).
    @State private var confirmingPhotoRemoval = false
    @State private var showingEdit = false
    @State private var showingSaveToContacts = false
    /// Which certificate the shared file importer fills — General Liability or Workers' Comp. One
    /// `.fileImporter` for both: SwiftUI silently presents only the last of several stacked
    /// `.fileImporter` modifiers on the same view.
    private enum ImportTarget {
        case coi
        case wcCoi
    }
    @State private var importTarget: ImportTarget?
    @State private var showingImporter = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    @State private var showingPackage = false

    var body: some View {
        // The shared deleted-record fence (LiveRecordGate): "This customer was removed" once the
        // customer is deleted out from under the view (e.g. on another device).
        LiveRecordGate(customer, title: "Customer") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                addressCard
                moreInfoRow
                GLSection("Records") { documentsSection }
                GLSection("Their insurance") { insuranceSection }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(GLScript.padded(customer.listDisplayName))
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(customer.listDisplayName)), for: .scrollContent)   // per-string descender clearance
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, customer.canBeNamedToAssistant {
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
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: customer)) {
                showingSaveToContacts = false
            }
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
            guard ReadOnlyGate.allows(.saveCustomer, into: $readOnlyRefusal) else { return }
            setPhoto(nil)
        }
        .fullScreenCover(item: $imageToCrop) { item in
            // The fleet crop screen with a round guide; it draws the 600 px square itself and
            // stays open with an alert if it can't (never saves the uncropped photo).
            GLSquarePhotoCropper(image: item.image, guide: .circle, outputSide: ImageDownsampler.croppedSide) {
                imageToCrop = nil
            } onCropped: { cropped in
                guard ReadOnlyGate.allows(.saveCustomer, into: $readOnlyRefusal) else { imageToCrop = nil; return }
                setPhoto(cropped.jpegData(compressionQuality: 0.85))
                imageToCrop = nil
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            let target = importTarget
            importTarget = nil
            guard case .success(let url) = result else { return }
            // Attaching a certificate stores a file on the customer, so it is refused like every
            // other upload while lapsed — same operation and same shape as the compliance importer
            // in InsuranceDocuments and the master-agreement importer in ProjectScreens. Refused
            // BEFORE the file is read, so a read-only app doesn't pull the document into memory to
            // then throw it away.
            guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
            let kind: CustomerCertificate
            switch target {
            case .coi: kind = .generalLiability
            case .wcCoi: kind = .workersComp
            case .none: return
            }
            // Size-checked first, then read off the main thread (F124).
            Task {
                let data: Data
                switch await FileImport.read(url) {
                case .success(let read): data = read
                case .failure(let failure): importFailure = failure; return
                }
                do {
                    try DocumentService.set(.customerCertificate(customer, kind), data: data,
                                            name: url.lastPathComponent, in: modelContext)
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                }
            }
        }
        .fileImportFailureAlert($importFailure)
        .navigationDestination(isPresented: $showingPackage) {
            if let profile = profiles.first {
                ContractorPackageSheet(customer: customer, profile: profile)
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            CustomerFormScreen.editingLive(customer)
        }
    }

    /// The photo write both photo controls share, through CustomerService (gated, saved).
    private func setPhoto(_ data: Data?) {
        do {
            try CustomerService.setPhoto(data, for: customer, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    // MARK: - Header (avatar + name + created date)

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ProfileAvatar(imageData: customer.profileImageData, initials: customer.initials, size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            if customer.profileImageData != nil {
                Button("Remove Photo", role: .destructive) {
                    // A lapsed app says so before asking a question it would then refuse.
                    guard ReadOnlyGate.allows(.saveCustomer, into: $readOnlyRefusal) else { return }
                    confirmingPhotoRemoval = true
                }
                .font(.subheadline)
            }

            Text("Customer since \(customer.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Info cards

    private var contactCard: some View {
        card("Contact") {
            contactRow("Email", .email, customer.email)
            contactRow("Phone", .phone, customer.phoneNumber)
            if !customer.officePhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contactRow("Office", .phone, customer.officePhone)
            }
            if let business = customer.businessName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !business.isEmpty {
                infoRow("Business", business)
            }
        }
    }

    private var addressCard: some View {
        card("Address") {
            addressRow("Service Address", customer.serviceAddress)
            if !customer.sameAsBillingAddress {
                addressRow("Billing Address", customer.address)
            }
        }
    }

    private func addressRow(_ label: LocalizedStringKey, _ address: Address) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if address.isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(.address, address.singleLine, display: address.formattedMultiline)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// The hub's link into the read-only categorized details (where Edit lives) — same flow as
    /// My Business Details.
    private var moreInfoRow: some View {
        GLHubRow(title: "More Info") { CustomerDetailsScreen(customer: customer) }
    }

    private var documentsSection: some View {
        VStack(spacing: 12) {
            ForEach(CustomerDocumentKind.allCases) { kind in
                NavigationLink {
                    switch kind {
                    case .estimates:
                        EstimatesListScreen(customer: customer)
                    case .contracts:
                        ContractsListScreen(customer: customer)
                    case .invoices:
                        InvoicesListScreen(customer: customer)
                    case .jobs:
                        JobsListScreen(customer: customer)
                    case .receipts:
                        ReceiptsListScreen(customer: customer)
                    case .changeOrders:
                        AllChangeOrdersScreen.forLiveCustomer(customer)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(gold)
                            .accessibilityHidden(true)
                        Text(kind.pluralTitle)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.glCaption.weight(.semibold))
                            .foregroundStyle(GLTheme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(GLLayout.rowContentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glCardBackground()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Insurance & Contractor Package

    /// The customer's own insurer-issued certificates (General Liability + Workers' Comp, upload /
    /// view) and the Contractor Package built around them. A COI names its holder, so both are
    /// per-customer; the rest of the package (W-9, workers'-comp exemption, license) is general and
    /// pulled from the business profile.
    private var insuranceSection: some View {
        let packageEnabled = profiles.first != nil
        return VStack(alignment: .leading, spacing: 12) {
            coiCard
            wcCoiCard

            Button { showingPackage = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .frame(width: 24)
                        .foregroundStyle(packageEnabled ? gold : GLTheme.textSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contractor Package")
                            .foregroundStyle(packageEnabled ? GLTheme.textPrimary : GLTheme.textSecondary)
                        if !packageEnabled {
                            Text("Add your business details first")
                                .font(.caption).foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                    Spacer()
                    if customer.hasCOI && packageEnabled {
                        Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.right")
                        .font(.glCaption.weight(.semibold))
                        .foregroundStyle(GLTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(GLLayout.rowContentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glCardBackground()
            }
            .buttonStyle(.plain)
            .disabled(!packageEnabled)
        }
    }

    @ViewBuilder
    private var coiCard: some View {
        if customer.hasCOI {
            NavigationLink {
                CustomerCOIDetailScreen(customer: customer)
            } label: {
                certCardLabel(title: "General Liability Certificate", systemImage: "checkmark.shield",
                              name: customer.coiName, uploaded: true, expiresOn: customer.coiExpiresOn)
            }
            .buttonStyle(.plain)
        } else {
            Button { importTarget = .coi; showingImporter = true } label: {
                certCardLabel(title: "General Liability Certificate", systemImage: "checkmark.shield",
                              name: customer.coiName, uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    /// The customer's Workers' Comp certificate — insurer-issued naming them as the holder, so it's
    /// per-customer exactly like the General Liability COI above.
    @ViewBuilder
    private var wcCoiCard: some View {
        if customer.hasWCCOI {
            NavigationLink {
                CustomerWCCOIDetailScreen(customer: customer)
            } label: {
                certCardLabel(title: "Workers’ Comp Certificate", systemImage: "cross.case",
                              name: customer.wcCoiName, uploaded: true, expiresOn: customer.wcCoiExpiresOn)
            }
            .buttonStyle(.plain)
        } else {
            Button { importTarget = .wcCoi; showingImporter = true } label: {
                certCardLabel(title: "Workers’ Comp Certificate", systemImage: "cross.case",
                              name: customer.wcCoiName, uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func certCardLabel(title: LocalizedStringKey, systemImage: String,
                               name: String, uploaded: Bool, expiresOn: Date? = nil) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expired = GLCertificateStatus.isExpired(expiresOn)
        let soon = GLCertificateStatus.isExpiringSoon(expiresOn)
        return HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(uploaded ? (trimmed.isEmpty ? mbLoc("Uploaded") : trimmed) : mbLoc("Tap to upload (PDF or image)"))
                    .font(.caption)
                    .foregroundStyle(GLTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The date, said out loud. A certificate whose validity is only
                // implied by a gold seal is exactly how an expired one goes out.
                if uploaded, let caption = GLCertificateStatus.caption(expiresOn) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(expired ? GLTheme.statusCritical : (soon ? GLTheme.statusAttention : GLTheme.textSecondary))
                }
            }
            Spacer(minLength: 8)
            if uploaded {
                // The seal is a CLAIM. It may only be gold while the claim is true. VoiceOver
                // hears the same claim from the date caption above, so the glyph stays silent.
                Image(systemName: expired ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(expired ? GLTheme.statusCritical : (soon ? GLTheme.statusAttention : gold))
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.up.doc").font(.footnote.weight(.semibold)).foregroundStyle(gold)
                    .accessibilityHidden(true)
            }
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    // MARK: - Helpers

    private var gold: Color { GLTheme.accentFill }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        MBTitledCard(title: title) { content() }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).copyable(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }

}

#Preview {
    NavigationStack {
        CustomerDetailScreen(
            customer: Customer(
                firstName: "Jane",
                lastName: "Doe",
                email: "jane@example.com",
                phoneNumber: "555-0142",
                businessName: "Doe Designs",
                address: Address(street1: "123 Main St", city: "Austin", state: "TX", postalCode: "78701")
            )
        )
    }
    .modelContainer(for: [Customer.self, BusinessProfile.self], inMemory: true)
}
