//
//  ZelleConnectScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/14/26.
//
//  Menu > Payments > "Connect Zelle".
//  Set up Zelle contact info (tag/name, email, phone) and QR code image so customers can pay directly.
//  Details are copyable and can be included on invoices and PDFs.
//

import SwiftUI
import SwiftData
import PhotosUI
import GoldLifeUI

struct ZelleConnectScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [BusinessProfile]

    private enum Field: Hashable { case tag, email }
    @FocusState private var focusedField: Field?

    @State private var tag: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    @State private var qrCodeData: Data? = nil
    @State private var defaultOn: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?
    @State private var photoLoadFailed = false
    @State private var copiedField: String? = nil

    private var profile: BusinessProfile? { profiles.first }

    private var isConfigured: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        qrCodeData != nil
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(mbLoc("Zelle name or tag"), text: $tag)
                        .focused($focusedField, equals: .tag)
                        .onChange(of: tag) { _, _ in save() }
                    let tagEmpty = tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    copyButton(for: tag, name: "tag")
                        .opacity(tagEmpty ? 0 : 1)
                        .disabled(tagEmpty)
                        .accessibilityHidden(tagEmpty)
                }

                HStack {
                    TextField(mbLoc("Zelle email"), text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .onChange(of: email) { _, _ in save() }
                    let emailEmpty = email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    copyButton(for: email, name: "email")
                        .opacity(emailEmpty ? 0 : 1)
                        .disabled(emailEmpty)
                        .accessibilityHidden(emailEmpty)
                }

                HStack {
                    PhoneTextField(placeholder: "Zelle phone number", text: $phone)
                        .onChange(of: phone) { _, _ in save() }
                    let phoneEmpty = phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    copyButton(for: phone, name: "phone")
                        .opacity(phoneEmpty ? 0 : 1)
                        .disabled(phoneEmpty)
                        .accessibilityHidden(phoneEmpty)
                }
            } header: {
                InfoLabel("Zelle Details",
                          info: "Add your Zelle contact details so your customers can pay you directly using Zelle. Payments are received in your bank account and must be recorded manually in the app.",
                          topic: "Zelle Details")
            } footer: {
                Text(mbLoc("Provide at least one detail your customers can use to find you on Zelle. Tap the copy icon or long-press any detail to copy."))
                    .foregroundStyle(GLTheme.textSecondary)
            }

            Section {
                if let data = qrCodeData, let uiImage = UIImage(data: data) {
                    VStack(alignment: .center, spacing: 14) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 160, maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(GLTheme.textSecondary.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.vertical, 6)

                        HStack(spacing: 20) {
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Label(mbLoc("Change QR Code"), systemImage: "photo")
                                    .font(.subheadline.weight(.medium))
                            }

                            Button(role: .destructive) {
                                qrCodeData = nil
                                selectedPhotoItem = nil
                                save()
                            } label: {
                                Label(mbLoc("Remove"), systemImage: "trash")
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                } else {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mbLoc("Upload Zelle QR Code"))
                                Text(mbLoc("From your photos or screenshots"))
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundStyle(GLTheme.accent)
                        }
                    }
                }
            } header: {
                InfoLabel("QR Code",
                          info: "Upload a screenshot or photo of your Zelle QR code from your bank app. When enabled, it will appear directly on your invoice PDFs so customers can scan and pay.",
                          topic: "QR Code")
            } footer: {
                Text(mbLoc("A QR code makes it easy for customers to scan and pay directly from their bank app."))
                    .foregroundStyle(GLTheme.textSecondary)
            }

            Section {
                Toggle(mbLoc("Add Zelle by default"), isOn: $defaultOn)
                    .disabled(!isConfigured)
                    .onChange(of: defaultOn) { _, _ in save() }
            } header: {
                InfoLabel("Invoices",
                          info: "Sets the default for new invoices. Every invoice keeps its own Zelle toggle, so you can turn it on or off for any single invoice.",
                          topic: "Invoices")
            } footer: {
                Text(defaultOn
                     ? mbLoc("New invoices will include your Zelle payment details and QR code. You can turn it off on any invoice.")
                     : mbLoc("New invoices won’t include Zelle details by default. You can turn them on for any invoice."))
                    .foregroundStyle(GLTheme.textSecondary)
            }
        }
        .glFormBackground()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Connect Zelle"))), for: .scrollContent)
        .navigationTitle(GLScript.padded(mbLoc("Connect Zelle")))
        .toolbarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.immediately)
        .onAppear { loadInitialData() }
        .onDisappear { save() }
        .onChange(of: focusedField) { _, _ in save() }
        .onChange(of: selectedPhotoItem) { _, newItem in
            handlePhotoSelected(newItem)
        }
        .photoLoadFailureAlert($photoLoadFailed)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
    }

    private func copyButton(for value: String, name: String) -> some View {
        Button {
            UIPasteboard.general.string = value.trimmingCharacters(in: .whitespacesAndNewlines)
            copiedField = name
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copiedField == name { copiedField = nil }
            }
        } label: {
            Image(systemName: copiedField == name ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(copiedField == name ? GLTheme.statusGood : GLTheme.textSecondary)
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiedField == name ? mbLoc("Copied") : mbLoc("Copy"))
    }

    private func loadInitialData() {
        if let profile {
            tag = profile.zelleTag
            email = profile.zelleEmail
            phone = profile.zellePhone
            qrCodeData = profile.zelleQRCodeData
            defaultOn = profile.zelleDefaultOn
        }
    }

    private func handlePhotoSelected(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = await ImageDownsampler.intakeJPEG(from: data) else {
                selectedPhotoItem = nil
                photoLoadFailed = true
                return
            }
            self.qrCodeData = jpeg
            selectedPhotoItem = nil
            save()
        }
    }

    private func save() {
        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profile {
            let detailsUnchanged = profile.zelleTag == cleanTag
                && profile.zelleEmail == cleanEmail
                && profile.zellePhone == cleanPhone
                && profile.zelleQRCodeData == qrCodeData
            let defaultUnchanged = profile.zelleDefaultOn == defaultOn
            if detailsUnchanged && defaultUnchanged { return }
        } else if cleanTag.isEmpty && cleanEmail.isEmpty && cleanPhone.isEmpty && qrCodeData == nil && !defaultOn {
            return
        }
        guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
        do {
            try BusinessProfileService.updateZelleDetails(tag: tag,
                                                         email: email,
                                                         phone: phone,
                                                         qrCodeData: qrCodeData,
                                                         in: modelContext)
            try BusinessProfileService.setZelleDefault(defaultOn, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
