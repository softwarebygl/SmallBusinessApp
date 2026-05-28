//
//  MenuScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Menu (app hub, presented from the Customers Menu button)

struct MenuScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    MyCompanyDetailScreen()
                } label: {
                    Label {
                        Text("My Company")
                    } icon: {
                        Image(systemName: "building.2")
                            .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle("Menu")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - My Company (read-only view + Edit, mirroring the app's view -> Edit -> form pattern)

struct MyCompanyDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [BusinessProfile]
    @State private var showingEdit = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        Group {
            if let profile = profiles.first {
                detail(profile)
            } else {
                Color.clear.onAppear { modelContext.insert(BusinessProfile()) }
            }
        }
        .background {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("My Company")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let profile = profiles.first {
                MyCompanyFormScreen(profile: profile)
            }
        }
    }

    private func detail(_ profile: BusinessProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                logo(profile)
                Text(profile.businessName.isEmpty ? "Your business" : profile.businessName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(profile.businessName.isEmpty ? .secondary : .primary)

                card("Contact") {
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }
                if !profile.licenseNumber.isEmpty {
                    card("License") {
                        Text(profile.licenseNumber)
                    }
                }
                let address = formattedAddress(profile.address)
                if !address.isEmpty {
                    card("Address") {
                        Text(address)
                    }
                }
            }
            .padding()
        }
    }

    private func logo(_ profile: BusinessProfile) -> some View {
        ZStack {
            if let data = profile.logoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else {
                gold.opacity(0.12)
                Image(systemName: "building.2")
                    .font(.system(size: 40))
                    .foregroundStyle(gold)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(gold.opacity(0.4), lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(gold.opacity(0.12)))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }

    private func formattedAddress(_ a: Address) -> String {
        let cityLine = [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
        let cityZip = [cityLine, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [a.street1, a.street2 ?? "", cityZip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - My Company edit form (sheet with Cancel/Save, same pattern as the Customer/Estimate forms)

struct MyCompanyFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let profile: BusinessProfile

    @State private var businessName: String
    @State private var licenseNumber: String
    @State private var email: String
    @State private var phone: String
    @State private var street1: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var logoData: Data?
    @State private var logoItem: PhotosPickerItem?

    init(profile: BusinessProfile) {
        self.profile = profile
        _businessName = State(initialValue: profile.businessName)
        _licenseNumber = State(initialValue: profile.licenseNumber)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
        _street1 = State(initialValue: profile.address.street1)
        _city = State(initialValue: profile.address.city)
        _state = State(initialValue: profile.address.state)
        _postalCode = State(initialValue: profile.address.postalCode)
        _logoData = State(initialValue: profile.logoData)
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var requiredMark: some View {
        Text("*").foregroundStyle(.red).accessibilityLabel("Required")
    }

    private var canSave: Bool {
        !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            logoView
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Logo")
                        Text("Optional. Appears on your estimates and invoices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        Text("Customizes the app")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }

                Section("Business") {
                    HStack {
                        TextField("Business name", text: $businessName)
                            .textContentType(.organizationName)
                        requiredMark
                    }
                    TextField("License number", text: $licenseNumber)
                }

                Section("Contact") {
                    HStack {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            #if !os(macOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        requiredMark
                    }
                    HStack {
                        TextField("Phone", text: $phone)
                            .textContentType(.telephoneNumber)
                            #if !os(macOS)
                            .keyboardType(.phonePad)
                            #endif
                        requiredMark
                    }
                }

                Section("Address") {
                    TextField("Street", text: $street1)
                        .textContentType(.streetAddressLine1)
                    TextField("City", text: $city)
                        .textContentType(.addressCity)
                    TextField("State", text: $state)
                        .textContentType(.addressState)
                    TextField("Postal code", text: $postalCode)
                        .textContentType(.postalCode)
                        #if !os(macOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle("My Company")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .task(id: logoItem) {
                guard let logoItem,
                      let data = try? await logoItem.loadTransferable(type: Data.self)
                else { return }
                logoData = data
            }
        }
    }

    private var logoView: some View {
        ZStack {
            if let data = logoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                gold.opacity(0.12)
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(gold)
                    Text("Add logo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(gold.opacity(0.4), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(7)
                .background(Circle().fill(gold))
                .padding(6)
        }
    }

    private func save() {
        profile.businessName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.licenseNumber = licenseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.street1 = street1.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.postalCode = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.logoData = logoData
        dismiss()
    }
}

#Preview {
    MenuScreen()
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self], inMemory: true)
}
