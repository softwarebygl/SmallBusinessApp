//
//  PersonalInfo.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  "My Personal Info" — the account owner's personal details, separate from the business. View +
//  Edit, mirroring the My Business Details pattern.

import SwiftUI
import SwiftData
import PhotosUI

private struct PendingPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct MyPersonalInfoScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [UserProfile]
    @State private var showingSignature = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        Group {
            if let profile = profiles.first {
                detail(profile)
            } else {
                Color.clear.onAppear { modelContext.insert(UserProfile()) }
            }
        }
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle("My Personal Info")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSignature) {
            if let profile = profiles.first {
                SignatureEditorSheet(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    /// Existing signatures are revealed only after Face ID; creating a first one needs no unlock.
    private func openSignature(_ profile: UserProfile) async {
        if profile.hasSignature {
            guard await BiometricGate.authenticate(reason: String(localized: "Unlock your saved signature.")) else { return }
        }
        showingSignature = true
    }

    private func detail(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    if let data = profile.photoData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage).resizable().scaledToFill()
                    } else {
                        gold.opacity(0.12)
                        Image(systemName: "person.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(gold)
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(Circle())
                .frame(maxWidth: .infinity)

                Text(profile.fullName.isEmpty ? String(localized: "Your name") : profile.fullName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(profile.fullName.isEmpty ? .secondary : .primary)

                GLCard(title: "Contact") {
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }

                NavigationLink {
                    PersonalDetailsScreen(profile: profile)
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
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - More Info (read-only details)

/// Read-only, categorized view of the personal details, with Edit — mirrors the My Business Details
/// "More Info" flow.
struct PersonalDetailsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let profile: UserProfile
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GLCard(title: "Name") {
                    infoRow("First name", profile.firstName)
                    infoRow("Last name", profile.lastName)
                }
                GLCard(title: "Contact") {
                    infoRow("Email", profile.email)
                    infoRow("Phone", profile.phone)
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
        .navigationTitle("More Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showingEdit = true } }
        }
        .sheet(isPresented: $showingEdit) {
            MyPersonalInfoFormScreen(profile: profile).glAppearance(colorScheme)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Edit form

struct MyPersonalInfoFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let profile: UserProfile

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var phone: String
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoToCrop: PendingPhoto?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    init(profile: UserProfile) {
        self.profile = profile
        _firstName = State(initialValue: profile.firstName)
        _lastName = State(initialValue: profile.lastName)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
        _photoData = State(initialValue: profile.photoData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer(minLength: 0)
                        VStack(spacing: 8) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                ZStack {
                                    GLColor.backgroundPrimary.render(in: colorScheme)
                                    if let photoData, let uiImage = UIImage(data: photoData) {
                                        Image(uiImage: uiImage).resizable().scaledToFill()
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "person.crop.circle.badge.plus")
                                                .font(.system(size: 26))
                                                .foregroundStyle(gold)
                                            Text("Add photo")
                                                .font(.caption)
                                                .foregroundStyle(gold.opacity(0.85))
                                        }
                                    }
                                }
                                .frame(width: 120, height: 120)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(gold.opacity(0.4), lineWidth: 1))
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

                            if photoData != nil {
                                Button(role: .destructive) {
                                    photoData = nil
                                    photoItem = nil
                                } label: {
                                    Text("Remove").font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Photo")
                } footer: {
                    Text("Optional. A photo of you for your personal profile.")
                        .textCase(nil)
                }

                Section("Name") {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Last name", text: $lastName)
                        .textContentType(.familyName)
                }
                Section("Contact") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        #if !os(macOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Phone", text: $phone)
                        .textContentType(.telephoneNumber)
                        #if !os(macOS)
                        .keyboardType(.phonePad)
                        #endif
                }
            }
            .glFormBackground()
            .navigationTitle("My Personal Info")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .task(id: photoItem) {
                guard let photoItem,
                      let data = try? await photoItem.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data)
                else { return }
                photoToCrop = PendingPhoto(image: uiImage)
                self.photoItem = nil
            }
            .fullScreenCover(item: $photoToCrop) { pending in
                ImageCropView(image: pending.image, guide: .circle) {
                    photoToCrop = nil
                } onCrop: { cropped in
                    photoData = cropped.pngData()
                    photoToCrop = nil
                }
            }
        }
    }

    private func save() {
        profile.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.photoData = photoData
        dismiss()
    }
}
