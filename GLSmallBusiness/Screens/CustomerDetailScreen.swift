//
//  CustomerDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

private struct CroppableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct CustomerDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    let customer: Customer

    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    @State private var showingSaveToContacts = false
    @State private var showingCOIImporter = false
    @State private var coiUploadFailed = false
    @State private var showingPackage = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                moreInfoRow
                GLSection("Records") { documentsSection }
                GLSection("Insurance") { insuranceSection }
            }
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(customer.listDisplayName)
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingSaveToContacts = true } label: {
                        Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
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
            guard let photoItem,
                  let data = try? await photoItem.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data)
            else { return }
            imageToCrop = CroppableImage(image: uiImage)
            self.photoItem = nil
        }
        .fullScreenCover(item: $imageToCrop) { item in
            ImageCropView(image: item.image) {
                imageToCrop = nil
            } onCrop: { cropped in
                customer.profileImageData = cropped.jpegData(compressionQuality: 0.85)
                imageToCrop = nil
            }
        }
        .fileImporter(isPresented: $showingCOIImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            if let data = url.readSecurityScoped() {
                customer.coiData = data
                customer.coiName = url.lastPathComponent
            } else {
                coiUploadFailed = true
            }
        }
        .alert("Couldn't read that file", isPresented: $coiUploadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file couldn't be opened. Try a different file, or export it as a PDF first.")
        }
        .sheet(isPresented: $showingPackage) {
            if let profile = profiles.first {
                ContractorPackageSheet(customer: customer, profile: profile).glAppearance(colorScheme)
            }
        }
    }

    // MARK: - Header (avatar + name + created date)

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                CustomerAvatar(customer: customer, size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            Text("Customer since \(customer.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Info cards

    private var contactCard: some View {
        card("Contact") {
            infoRow("Email", customer.email)
            infoRow("Phone", customer.phoneNumber)
            if !customer.officePhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                infoRow("Office", customer.officePhone)
            }
            if let business = customer.businessName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !business.isEmpty {
                infoRow("Business", business)
            }
        }
    }

    /// The hub's link into the read-only categorized details (where Edit lives) — same flow as
    /// My Business Details.
    private var moreInfoRow: some View {
        NavigationLink {
            CustomerDetailsScreen(customer: customer)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .frame(width: 24)
                    .foregroundStyle(gold)
                Text("More Info")
                Spacer()
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

    private var documentsSection: some View {
        VStack(spacing: 12) {
            ForEach(CustomerDocumentKind.allCases) { kind in
                NavigationLink {
                    switch kind {
                    case .estimates:
                        EstimatesListScreen(customer: customer)
                    case .invoices:
                        InvoicesListScreen(customer: customer)
                    case .receipts:
                        ReceiptsListScreen(customer: customer)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(gold)
                        Text(kind.pluralTitle)
                        Spacer()
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
    }

    // MARK: - Insurance & Contractor Package

    /// The customer's own General Liability COI (upload / view) and the Contractor Package built
    /// around it. A COI names its holder, so it's per-customer; the rest of the package (W-9,
    /// workers'-comp, license) is general and pulled from the business profile.
    private var insuranceSection: some View {
        let packageEnabled = profiles.first != nil
        return VStack(alignment: .leading, spacing: 12) {
            coiCard

            Button { showingPackage = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .frame(width: 24)
                        .foregroundStyle(packageEnabled ? gold : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contractor Package")
                            .foregroundStyle(packageEnabled ? Color.primary : Color.secondary)
                        if !packageEnabled {
                            Text("Add your business details first")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if customer.hasCOI && packageEnabled {
                        Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding()
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
                coiCardLabel(uploaded: true)
            }
            .buttonStyle(.plain)
        } else {
            Button { showingCOIImporter = true } label: {
                coiCardLabel(uploaded: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func coiCardLabel(uploaded: Bool) -> some View {
        let name = customer.coiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .frame(width: 24)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("General Liability (COI)")
                Text(uploaded ? (name.isEmpty ? "Uploaded" : name) : "Tap to upload (PDF or image)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if uploaded {
                Image(systemName: "checkmark.seal.fill").font(.footnote).foregroundStyle(gold)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.up.doc").font(.footnote.weight(.semibold)).foregroundStyle(gold)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }

    // MARK: - Helpers

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GLCard(title: title) { content() }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .multilineTextAlignment(.trailing)
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
