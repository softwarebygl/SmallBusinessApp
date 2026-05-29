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
    @State private var showingSettings = false

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
            .safeAreaInset(edge: .bottom) {
                // A bottom toolbar item doesn't render reliably inside a sheet (it logs a
                // "UIKitToolbar as subview of UIHostingController" warning and goes missing),
                // so the bottom-left Settings gear is placed with a safe-area inset instead.
                HStack {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    }
                    .accessibilityLabel("Settings")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle("Menu")
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingSettings) {
                SettingsScreen()
            }
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
            if let data = profile.logo(for: colorScheme), let uiImage = UIImage(data: data) {
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
    @State private var messageIntro: String
    @State private var messageClosing: String
    @State private var invoiceMessageIntro: String
    @State private var invoiceMessageClosing: String
    @State private var logoData: Data?
    @State private var logoDataDark: Data?
    @State private var logoItem: PhotosPickerItem?
    @State private var logoItemDark: PhotosPickerItem?

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
        _messageIntro = State(initialValue: profile.messageIntro)
        _messageClosing = State(initialValue: profile.messageClosing)
        _invoiceMessageIntro = State(initialValue: profile.invoiceMessageIntro)
        _invoiceMessageClosing = State(initialValue: profile.invoiceMessageClosing)
        _logoData = State(initialValue: profile.logoData)
        _logoDataDark = State(initialValue: profile.logoDataDark)
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
                    HStack(alignment: .top, spacing: 24) {
                        Spacer(minLength: 0)
                        logoWell(title: "Light", scheme: .light, data: $logoData, item: $logoItem)
                        logoWell(title: "Dark", scheme: .dark, data: $logoDataDark, item: $logoItemDark)
                        Spacer(minLength: 0)
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

                Section {
                    TextField(EstimateMessage.defaultIntro, text: $messageIntro, axis: .vertical)
                        .lineLimit(2...6)
                    TextField(EstimateMessage.defaultClosing, text: $messageClosing, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Estimate message")
                } footer: {
                    Text("Appears in the estimate email and text, between the greeting and your signature. Leave blank to use the suggested wording shown.")
                        .textCase(nil)
                }

                Section {
                    TextField(InvoiceMessage.defaultIntro, text: $invoiceMessageIntro, axis: .vertical)
                        .lineLimit(2...6)
                    TextField(InvoiceMessage.defaultClosing, text: $invoiceMessageClosing, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Invoice message")
                } footer: {
                    Text("Appears in the invoice email and text. Leave blank to use the suggested wording shown.")
                        .textCase(nil)
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
            .task(id: logoItemDark) {
                guard let logoItemDark,
                      let data = try? await logoItemDark.loadTransferable(type: Data.self)
                else { return }
                logoDataDark = data
            }
        }
    }

    /// One labeled logo slot (Light or Dark), Xcode-asset style. Each previews the logo on the
    /// brand background for its appearance so the user sees how it will actually look.
    @ViewBuilder
    private func logoWell(title: String, scheme: ColorScheme, data: Binding<Data?>, item: Binding<PhotosPickerItem?>) -> some View {
        let wellBackground = GLColor.backgroundPrimary.render(in: scheme)
        let wellGold = GLColor.gold.render(in: scheme)
        VStack(spacing: 8) {
            PhotosPicker(selection: item, matching: .images) {
                ZStack {
                    wellBackground
                    if let value = data.wrappedValue, let uiImage = UIImage(data: value) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 24))
                                .foregroundStyle(wellGold)
                            Text("Add")
                                .font(.caption)
                                .foregroundStyle(wellGold.opacity(0.85))
                        }
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(gold.opacity(0.4), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(gold))
                        .padding(5)
                }
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.subheadline.weight(.medium))

            if data.wrappedValue != nil {
                Button(role: .destructive) {
                    data.wrappedValue = nil
                    item.wrappedValue = nil
                } label: {
                    Text("Remove").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else {
                // Keeps both wells the same height whether or not a logo is set.
                Text(" ").font(.caption).hidden()
            }
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
        profile.messageIntro = messageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.messageClosing = messageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceMessageIntro = invoiceMessageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceMessageClosing = invoiceMessageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.logoData = logoData
        profile.logoDataDark = logoDataDark
        dismiss()
    }
}

#Preview {
    MenuScreen()
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self], inMemory: true)
}
