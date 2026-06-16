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

struct MyPersonalInfoScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var profiles: [UserProfile]
    @State private var showingEdit = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showingEdit = true } }
        }
        .sheet(isPresented: $showingEdit) {
            if let profile = profiles.first {
                MyPersonalInfoFormScreen(profile: profile).glAppearance(colorScheme)
            }
        }
    }

    private func detail(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    gold.opacity(0.12)
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(gold)
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

// MARK: - Edit form

struct MyPersonalInfoFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let profile: UserProfile

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var phone: String

    init(profile: UserProfile) {
        self.profile = profile
        _firstName = State(initialValue: profile.firstName)
        _lastName = State(initialValue: profile.lastName)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
    }

    var body: some View {
        NavigationStack {
            Form {
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
        }
    }

    private func save() {
        profile.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}
