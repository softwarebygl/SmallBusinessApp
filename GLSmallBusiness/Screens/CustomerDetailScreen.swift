//
//  CustomerDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import PhotosUI

private struct CroppableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct CustomerDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let customer: Customer

    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                addressCard
                documentsSection
            }
            .padding()
        }
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .navigationTitle(customer.listDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            CustomerFormScreen(editing: customer).glAppearance(colorScheme)
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
    }

    // MARK: - Header (avatar + name + created date)

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                CustomerAvatar(customer: customer, size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            Text(customer.listDisplayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

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
            if let business = customer.businessName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !business.isEmpty {
                infoRow("Business", business)
            }
        }
    }

    private var addressCard: some View {
        card("Address") {
            if formattedAddress.isEmpty {
                Text("No address on file")
                    .foregroundStyle(.secondary)
            } else {
                Text(formattedAddress)
            }
        }
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

    // MARK: - Helpers

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GLCard(title: title) { content() }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var formattedAddress: String {
        let a = customer.address
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
    .modelContainer(for: Customer.self, inMemory: true)
}
