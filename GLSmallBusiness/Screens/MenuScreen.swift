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
                Section("My Info") {
                    NavigationLink {
                        MyCompanyDetailScreen()
                    } label: {
                        Label {
                            Text("Business")
                        } icon: {
                            Image(systemName: "building.2")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
                    }
                    NavigationLink {
                        MyPersonalInfoScreen()
                    } label: {
                        Label {
                            Text("Personal")
                        } icon: {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
                    }
                }

                Section("Job Records") {
                    NavigationLink {
                        AllEstimatesScreen()
                    } label: {
                        Label {
                            Text("All Estimates")
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
                    }
                    NavigationLink {
                        AllInvoicesScreen()
                    } label: {
                        Label {
                            Text("All Invoices")
                        } icon: {
                            Image(systemName: "doc.plaintext")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
                    }
                    NavigationLink {
                        AllChangeOrdersScreen()
                    } label: {
                        Label {
                            Text("All Change Orders")
                        } icon: {
                            Image(systemName: "pencil.and.list.clipboard")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
                    }
                    NavigationLink {
                        AllReceiptsScreen()
                    } label: {
                        Label {
                            Text("All Receipts")
                        } icon: {
                            Image(systemName: "doc.viewfinder")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                        }
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
            .toolbarTitleDisplayMode(.large)   // large so the Records lists pushed from here render large too
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
    @State private var activeDocument: BusinessDocument?
    @State private var ensuredProfile = false

    private enum BusinessDocument: String, Identifiable {
        case insurance, taxReport, w9
        var id: String { rawValue }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        Group {
            if let profile = profiles.first {
                detail(profile)
            } else {
                Color.clear
            }
        }
        .task {
            // Create the single profile once, and only if there genuinely isn't one — guarding
            // against a transient empty state during sync (or a repeated onAppear) inserting a dup.
            guard !ensuredProfile, profiles.isEmpty else { return }
            ensuredProfile = true
            modelContext.insert(BusinessProfile())
        }
        .background {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("My Business Details")
        .toolbarTitleDisplayMode(.large)   // large so Statistics (pushed from here) renders large too
        .sheet(item: $activeDocument) { document in
            if let profile = profiles.first {
                switch document {
                case .insurance:
                    ComplianceDocsManagerSheet(profile: profile).glAppearance(colorScheme)
                case .taxReport:
                    YearEndTaxReportSheet().glAppearance(colorScheme)
                case .w9:
                    W9DocumentSheet(profile: profile).glAppearance(colorScheme)
                }
            }
        }
    }

    private func detail(_ profile: BusinessProfile) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                logo(profile)
                Text(profile.businessName.isEmpty ? String(localized: "Your business") : profile.businessName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(profile.businessName.isEmpty ? .secondary : .primary)

                GLCard(title: "Contact") {
                    infoRow("Name", profile.ownerFullName)
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }

                NavigationLink {
                    CompanyDetailsScreen(profile: profile)
                } label: {
                    rowLabel("More Info", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)

                GLSection("Compliance") {
                    actionRow("Insurance & Licensing", systemImage: "checkmark.shield",
                              badge: profile.hasComplianceDocuments) { activeDocument = .insurance }
                    actionRow("Generate a W-9", systemImage: "doc.plaintext") { activeDocument = .w9 }
                }

                GLSection("Reports") {
                    actionRow("Year-End Tax Report", systemImage: "doc.text") { activeDocument = .taxReport }
                    NavigationLink {
                        StatsScreen()
                    } label: {
                        rowLabel("Statistics", systemImage: "chart.bar")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    /// The shared icon + label + chevron row body, used by both tap-action rows and navigation rows
    /// so every hub row is visually identical.
    private func rowLabel(_ title: LocalizedStringKey, systemImage: String, badge: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(gold)
            Text(title)
            Spacer()
            if badge {
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

    private func actionRow(_ title: LocalizedStringKey, systemImage: String,
                           badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, systemImage: systemImage, badge: badge)
        }
        .buttonStyle(.plain)
    }

    private func logo(_ profile: BusinessProfile) -> some View {
        // Show the variant for the current scheme, but back it with the surface that variant was made
        // for (light logo on a light card, dark logo on a dark card) so it's always legible — a
        // light-only logo no longer vanishes in dark mode.
        let useDark = colorScheme == .dark && profile.logoDataDark != nil
        let data = useDark ? profile.logoDataDark : (profile.logoData ?? profile.logoDataDark)
        let backing: ColorScheme = useDark ? .dark : (profile.logoData != nil ? .light : .dark)
        return ZStack {
            if let data, let uiImage = UIImage(data: data) {
                GLColor.backgroundPrimary.render(in: backing)
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
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(gold.opacity(0.25), lineWidth: 1))
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
    @State private var ownerFirstName: String
    @State private var ownerLastName: String
    @State private var licenseNumber: String
    @State private var email: String
    @State private var phone: String
    @State private var street1: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var estimateMessageSubject: String
    @State private var messageIntro: String
    @State private var messageClosing: String
    @State private var invoiceMessageSubject: String
    @State private var invoiceMessageIntro: String
    @State private var invoiceMessageClosing: String
    @State private var receiptMessageSubject: String
    @State private var receiptMessageIntro: String
    @State private var receiptMessageClosing: String
    @State private var changeOrderMessageSubject: String
    @State private var changeOrderMessageIntro: String
    @State private var changeOrderMessageClosing: String
    @State private var packageMessageSubject: String
    @State private var packageMessageIntro: String
    @State private var packageMessageClosing: String
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
    @State private var tinSaveFailed = false
    @State private var photoLoadFailed = false

    init(profile: BusinessProfile) {
        self.profile = profile
        _businessName = State(initialValue: profile.businessName)
        _ownerFirstName = State(initialValue: profile.ownerFirstName)
        _ownerLastName = State(initialValue: profile.ownerLastName)
        _licenseNumber = State(initialValue: profile.licenseNumber)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
        _street1 = State(initialValue: profile.address.street1)
        _city = State(initialValue: profile.address.city)
        _state = State(initialValue: profile.address.state)
        _postalCode = State(initialValue: profile.address.postalCode)
        _estimateMessageSubject = State(initialValue: profile.estimateMessageSubject)
        _messageIntro = State(initialValue: profile.messageIntro)
        _messageClosing = State(initialValue: profile.messageClosing)
        _invoiceMessageSubject = State(initialValue: profile.invoiceMessageSubject)
        _invoiceMessageIntro = State(initialValue: profile.invoiceMessageIntro)
        _invoiceMessageClosing = State(initialValue: profile.invoiceMessageClosing)
        _receiptMessageSubject = State(initialValue: profile.receiptMessageSubject)
        _receiptMessageIntro = State(initialValue: profile.receiptMessageIntro)
        _receiptMessageClosing = State(initialValue: profile.receiptMessageClosing)
        _changeOrderMessageSubject = State(initialValue: profile.changeOrderMessageSubject)
        _changeOrderMessageIntro = State(initialValue: profile.changeOrderMessageIntro)
        _changeOrderMessageClosing = State(initialValue: profile.changeOrderMessageClosing)
        _packageMessageSubject = State(initialValue: profile.packageMessageSubject)
        _packageMessageIntro = State(initialValue: profile.packageMessageIntro)
        _packageMessageClosing = State(initialValue: profile.packageMessageClosing)
        _logoData = State(initialValue: profile.logoData)
        _logoDataDark = State(initialValue: profile.logoDataDark)
        _w9Name = State(initialValue: profile.w9Name)
        _w9Classification = State(initialValue: profile.w9TaxClassification)
        _w9LLCClassification = State(initialValue: profile.w9LLCClassification)
        _w9OtherClassification = State(initialValue: profile.w9OtherClassification)
        _w9TINType = State(initialValue: profile.w9TINType)
        _w9TIN = State(initialValue: profile.secureTIN)
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
                    InfoLabel("Logo", info: "Optional. Appears on your estimates and invoices, and customizes the app.")
                }

                Section("Business") {
                    HStack {
                        TextField("Business name", text: $businessName)
                            .textContentType(.organizationName)
                        requiredMark
                    }
                    TextField("License number", text: $licenseNumber)
                        .idCodeStyle()
                }

                Section("Contact") {
                    TextField("Owner first name", text: $ownerFirstName)
                        .textContentType(.givenName)
                    TextField("Owner last name", text: $ownerLastName)
                        .textContentType(.familyName)
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
                        .textInputAutocapitalization(.characters)
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
                    .onChange(of: w9TINType) { _, _ in
                        // The SSN and EIN formats differ, so switching type clears the old number.
                        w9TIN = ""
                    }
                    LabeledContent(w9TINType?.label ?? String(localized: "Tax ID")) {
                        TINField(kind: w9TINType, text: $w9TIN)
                    }
                } header: {
                    InfoLabel("Tax details (for W-9)", info: "Optional. Used to generate a W-9. Your Tax ID is stored securely in your Keychain, not the synced database. Sign and date the form by hand after you print or send it.")
                }

                Section {
                    TextField("Exempt payee code", text: $w9ExemptPayeeCode)
                        .idCodeStyle()
                    TextField("FATCA exemption code", text: $w9FATCACode)
                        .idCodeStyle()
                } header: {
                    InfoLabel("Exemption codes", info: "Optional W-9 exemption codes. Most small businesses leave these blank.")
                }

                messageSection("Estimate message", document: "estimate",
                               subject: $estimateMessageSubject, subjectHint: "Estimate # from your business",
                               intro: $messageIntro, introHint: EstimateMessage.defaultIntro,
                               closing: $messageClosing, closingHint: EstimateMessage.defaultClosing)

                messageSection("Invoice message", document: "invoice",
                               subject: $invoiceMessageSubject, subjectHint: "Invoice # from your business",
                               intro: $invoiceMessageIntro, introHint: InvoiceMessage.defaultIntro,
                               closing: $invoiceMessageClosing, closingHint: InvoiceMessage.defaultClosing)

                messageSection("Receipt message", document: "payment receipt",
                               subject: $receiptMessageSubject, subjectHint: "Receipt for invoice # from your business",
                               intro: $receiptMessageIntro, introHint: "Thank you for your payment. Your receipt is attached.",
                               closing: $receiptMessageClosing, closingHint: PaymentReceiptMessage.defaultClosing)

                messageSection("Change order message", document: "change order",
                               subject: $changeOrderMessageSubject, subjectHint: "Change order # from your business",
                               intro: $changeOrderMessageIntro, introHint: ChangeOrderMessage.defaultIntro,
                               closing: $changeOrderMessageClosing, closingHint: ChangeOrderMessage.defaultClosing)

                messageSection("Contractor package message", document: "contractor package",
                               subject: $packageMessageSubject, subjectHint: "Contractor package from your business",
                               intro: $packageMessageIntro, introHint: ContractorPackageMessage.defaultIntro,
                               closing: $packageMessageClosing, closingHint: ContractorPackageMessage.defaultClosing)
            }
            .glFormBackground()
            .navigationTitle("My Business Details")
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
                guard let logoItem else { return }
                guard let data = try? await logoItem.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else {
                    self.logoItem = nil
                    photoLoadFailed = true
                    return
                }
                logoToCrop = LogoCrop(image: uiImage, isDark: false)
                self.logoItem = nil
            }
            .task(id: logoItemDark) {
                guard let logoItemDark else { return }
                guard let data = try? await logoItemDark.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else {
                    self.logoItemDark = nil
                    photoLoadFailed = true
                    return
                }
                logoToCrop = LogoCrop(image: uiImage, isDark: true)
                self.logoItemDark = nil
            }
            .photoLoadFailureAlert($photoLoadFailed)
            .fullScreenCover(item: $logoToCrop) { crop in
                ImageCropView(image: crop.image, guide: .roundedRect,
                              windowBackground: GLColor.backgroundPrimary.render(in: crop.isDark ? .dark : .light)) {
                    logoToCrop = nil
                } onCrop: { cropped in
                    let data = cropped.pngData()
                    if crop.isDark { logoDataDark = data } else { logoData = data }
                    logoToCrop = nil
                }
            }
            .alert("Couldn’t save your Tax ID", isPresented: $tinSaveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your other details were saved, but your Tax ID wasn’t. Make sure your device is unlocked, then tap Save again.")
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

    /// One document's editable text/email wording: an optional subject line plus the intro and
    /// closing paragraphs. Each shows its default as placeholder; blank falls back to that default.
    private func messageSection(_ title: LocalizedStringKey, document: String,
                                subject: Binding<String>, subjectHint: String,
                                intro: Binding<String>, introHint: String,
                                closing: Binding<String>, closingHint: String) -> some View {
        Section {
            TextField("Subject — \(subjectHint)", text: subject, axis: .vertical)
                .lineLimit(1...2)
            TextField(introHint, text: intro, axis: .vertical)
                .lineLimit(2...6)
            TextField(closingHint, text: closing, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            InfoLabel(title, info: "Subject line, then the message between the greeting and your signature, used when you send the \(document) by email or text. Leave any field blank to use the suggested wording shown.")
        }
    }

    private func save() {
        profile.businessName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.ownerFirstName = ownerFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.ownerLastName = ownerLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.licenseNumber = licenseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.street1 = street1.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address.postalCode = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.estimateMessageSubject = estimateMessageSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.messageIntro = messageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.messageClosing = messageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceMessageSubject = invoiceMessageSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceMessageIntro = invoiceMessageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceMessageClosing = invoiceMessageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.receiptMessageSubject = receiptMessageSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.receiptMessageIntro = receiptMessageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.receiptMessageClosing = receiptMessageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.changeOrderMessageSubject = changeOrderMessageSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.changeOrderMessageIntro = changeOrderMessageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.changeOrderMessageClosing = changeOrderMessageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.packageMessageSubject = packageMessageSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.packageMessageIntro = packageMessageIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.packageMessageClosing = packageMessageClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.logoData = logoData
        profile.logoDataDark = logoDataDark
        profile.w9Name = w9Name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9TaxClassification = w9Classification
        profile.w9LLCClassification = w9LLCClassification.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        profile.w9OtherClassification = w9OtherClassification.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9TINType = w9TINType
        let tinSaved = profile.updateTIN(w9TIN)
        profile.w9ExemptPayeeCode = w9ExemptPayeeCode.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.w9FATCACode = w9FATCACode.trimmingCharacters(in: .whitespacesAndNewlines)
        // The rest of the profile is saved; only the secure Tax ID write can fail. If it did, keep
        // the form open and tell the user rather than dismissing as if everything saved.
        if tinSaved {
            dismiss()
        } else {
            tinSaveFailed = true
        }
    }
}

#Preview {
    MenuScreen()
        .modelContainer(for: [Customer.self, Estimate.self, BusinessProfile.self], inMemory: true)
}
