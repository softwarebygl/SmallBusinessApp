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
    @Environment(\.openURL) private var openURL
    @State private var showingSettings = false

    /// `mailto:` link that opens the user's mail app, pre-addressed to support with a subject filled in.
    private var developerFeedbackURL: URL? {
        let subject = "Developer Feedback"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Developer%20Feedback"
        return URL(string: "mailto:support@evolvedbygl.com?subject=\(subject)")
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    MyPersonalInfoScreen()
                } label: {
                    Label {
                        Text("My Personal Info")
                    } icon: {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    }
                }
                NavigationLink {
                    MyCompanyDetailScreen()
                } label: {
                    Label {
                        Text("My Business Details")
                    } icon: {
                        Image(systemName: "building.2")
                            .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    }
                }
                NavigationLink {
                    DocumentsScreen()
                } label: {
                    Label {
                        Text("Documents")
                    } icon: {
                        Image(systemName: "doc.on.doc")
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

                    Button {
                        if let developerFeedbackURL { openURL(developerFeedbackURL) }
                    } label: {
                        Text("Developer Feedback")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    }
                    .accessibilityLabel("Developer Feedback")
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
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
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
    @Query private var userProfiles: [UserProfile]
    @State private var showingSignature = false
    @State private var showingCompliance = false

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
        .navigationTitle("My Business Details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSignature) {
            if let profile = profiles.first {
                SignatureEditorSheet(profile: profile).glAppearance(colorScheme)
            }
        }
        .sheet(isPresented: $showingCompliance) {
            if let profile = profiles.first {
                ComplianceDocsManagerSheet(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    private func detail(_ profile: BusinessProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                logo(profile)
                Text(profile.businessName.isEmpty ? String(localized: "Your business") : profile.businessName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(profile.businessName.isEmpty ? .secondary : .primary)

                GLCard(title: "Contact") {
                    infoRow("Name", userProfiles.first?.fullName ?? "")
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }

                NavigationLink {
                    CompanyDetailsScreen(profile: profile)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .frame(width: 24)
                            .foregroundStyle(gold)
                        Text("Details")
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

                NavigationLink {
                    BusinessReceiptsScreen()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.viewfinder")
                            .frame(width: 24)
                            .foregroundStyle(gold)
                        Text("Receipts")
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

                Button {
                    Task { await openSignature(profile) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "signature")
                            .frame(width: 24)
                            .foregroundStyle(gold)
                        Text("Signature")
                        Spacer()
                        if profile.hasSignature {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.footnote)
                                .foregroundStyle(gold)
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

                Button {
                    showingCompliance = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .frame(width: 24)
                            .foregroundStyle(gold)
                        Text("Insurance & WC Exemption")
                        Spacer()
                        if profile.hasComplianceDocuments {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.footnote)
                                .foregroundStyle(gold)
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
            }
            .padding()
        }
    }

    /// Existing signatures are revealed only after Face ID; creating a first one needs no unlock.
    private func openSignature(_ profile: BusinessProfile) async {
        if profile.hasSignature {
            guard await BiometricGate.authenticate(reason: String(localized: "Unlock your saved signature.")) else { return }
        }
        showingSignature = true
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

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - My Company edit form (sheet with Cancel/Save, same pattern as the Customer/Estimate forms)

private struct LogoCrop: Identifiable {
    let id = UUID()
    let image: UIImage
    let isDark: Bool
}

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
    @State private var logoToCrop: LogoCrop?
    @State private var w9Name: String
    @State private var w9Classification: W9TaxClassification?
    @State private var w9LLCClassification: String
    @State private var w9OtherClassification: String
    @State private var w9TINType: W9TINType?
    @State private var w9TIN: String
    @State private var w9ExemptPayeeCode: String
    @State private var w9FATCACode: String

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
        _w9Name = State(initialValue: profile.w9Name)
        _w9Classification = State(initialValue: profile.w9TaxClassification)
        _w9LLCClassification = State(initialValue: profile.w9LLCClassification)
        _w9OtherClassification = State(initialValue: profile.w9OtherClassification)
        _w9TINType = State(initialValue: profile.w9TINType)
        _w9TIN = State(initialValue: profile.w9TIN)
        _w9ExemptPayeeCode = State(initialValue: profile.w9ExemptPayeeCode)
        _w9FATCACode = State(initialValue: profile.w9FATCACode)
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
                    TextField("Name (as on tax return)", text: $w9Name)
                        .textContentType(.name)
                    Picker("Tax classification", selection: $w9Classification) {
                        Text("Select…").tag(W9TaxClassification?.none)
                        ForEach(W9TaxClassification.allCases) { option in
                            Text(option.label).tag(W9TaxClassification?.some(option))
                        }
                    }
                    if w9Classification == .llc {
                        TextField("LLC tax classification (C, S, or P)", text: $w9LLCClassification)
                            #if !os(macOS)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            #endif
                    }
                    if w9Classification == .other {
                        TextField("Describe classification", text: $w9OtherClassification)
                    }
                    Picker("Taxpayer ID type", selection: $w9TINType) {
                        Text("Select…").tag(W9TINType?.none)
                        ForEach(W9TINType.allCases) { option in
                            Text(option.label).tag(W9TINType?.some(option))
                        }
                    }
                    TextField(w9TINType == .ein ? "EIN" : "Taxpayer ID number", text: $w9TIN)
                        #if !os(macOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                } header: {
                    Text("Tax details (for W-9)")
                } footer: {
                    Text("Optional. Used to generate a W-9. Sign and date the form by hand after you print or send it.")
                        .textCase(nil)
                }

                Section {
                    TextField("Exempt payee code", text: $w9ExemptPayeeCode)
                    TextField("FATCA exemption code", text: $w9FATCACode)
                } footer: {
                    Text("Optional W-9 exemption codes. Most small businesses leave these blank.")
                        .textCase(nil)
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
            .glFormBackground()
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
                      let data = try? await logoItem.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data)
                else { return }
                logoToCrop = LogoCrop(image: uiImage, isDark: false)
                self.logoItem = nil
            }
            .task(id: logoItemDark) {
                guard let logoItemDark,
                      let data = try? await logoItemDark.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data)
                else { return }
                logoToCrop = LogoCrop(image: uiImage, isDark: true)
                self.logoItemDark = nil
            }
            .fullScreenCover(item: $logoToCrop) { crop in
                ImageCropView(image: crop.image, guide: .roundedRect) {
                    logoToCrop = nil
                } onCrop: { cropped in
                    let data = cropped.pngData()
                    if crop.isDark { logoDataDark = data } else { logoData = data }
                    logoToCrop = nil
                }
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
        profile.w9Name = w9Name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9TaxClassification = w9Classification
        profile.w9LLCClassification = w9LLCClassification.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        profile.w9OtherClassification = w9OtherClassification.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9TINType = w9TINType
        profile.w9TIN = w9TIN.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9ExemptPayeeCode = w9ExemptPayeeCode.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9FATCACode = w9FATCACode.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}

#Preview {
    MenuScreen()
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self], inMemory: true)
}
