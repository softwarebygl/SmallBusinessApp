//
//  SubcontractorFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Add / edit a subcontractor. Mirrors EmployeeFormScreen / CustomerFormScreen: a pushed Form
//  with the cream background, a trailing Save (the back button replaces Cancel), and an onSave
//  callback (iPad auto-select).
//  Tax details (W-9 / TIN) come in the tax-document round.
//

import SwiftUI
import SwiftData

struct SubcontractorFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let editing: Subcontractor?
    var onSave: ((Subcontractor) -> Void)? = nil

    @State private var firstName: String
    @State private var lastName: String
    @State private var businessName: String
    @State private var email: String
    @State private var phone: String
    @State private var street1: String
    @State private var street2: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var isActive: Bool
    @State private var notes: String
    @State private var hourlyRate: Double
    @State private var w9TINType: W9TINType?
    @State private var w9TIN: String
    @State private var showingContactPicker = false
    @State private var tinSaveFailed = false
    /// In-flight guard: prevents a double-tap from inserting twice, but resets on a Tax-ID failure so
    /// the user can unlock and tap Save again (unlike SaveOnceButton, which would stay dead).
    @State private var isSaving = false
    /// On the add path, the subcontractor inserted on the first attempt — reused on a retry so a
    /// Tax-ID-failure re-save mutates the same record instead of creating a duplicate.
    @State private var insertedSubcontractor: Subcontractor?

    init(editing: Subcontractor? = nil, onSave: ((Subcontractor) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _firstName    = State(initialValue: editing?.firstName ?? "")
        _lastName     = State(initialValue: editing?.lastName ?? "")
        _businessName = State(initialValue: editing?.businessName ?? "")
        _email        = State(initialValue: editing?.email ?? "")
        _phone        = State(initialValue: editing?.phone ?? "")
        _street1      = State(initialValue: editing?.address.street1 ?? "")
        _street2      = State(initialValue: editing?.address.street2 ?? "")
        _city         = State(initialValue: editing?.address.city ?? "")
        _state        = State(initialValue: editing?.address.state ?? "")
        _postalCode   = State(initialValue: editing?.address.postalCode ?? "")
        _isActive     = State(initialValue: editing?.isActive ?? true)
        _notes        = State(initialValue: editing?.notes ?? "")
        _hourlyRate   = State(initialValue: editing?.hourlyRate ?? 0)
        _w9TINType    = State(initialValue: editing?.w9TINType)
        _w9TIN        = State(initialValue: editing?.secureTIN ?? "")
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trim(firstName).isEmpty || !trim(lastName).isEmpty || !trim(businessName).isEmpty
    }

    var body: some View {
        Form {
            if editing == nil {
                Section {
                    HStack {
                        Button { showingContactPicker = true } label: {
                            Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        InfoButton(text: "Pull a name, business, phone, email, and address from your phone's contacts.")
                    }
                }
            }
            Section("Name") {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
            }
            Section("Business") {
                TextField("Business name (optional)", text: $businessName)
                    .textContentType(.organizationName)
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
                    .phoneNumberFormatted($phone)
            }
            Section("Address") {
                AddressSearchButton(street1: $street1, city: $city, state: $state, postalCode: $postalCode)
                TextField("Street", text: $street1)
                    .textContentType(.streetAddressLine1)
                TextField("Apt / Suite (optional)", text: $street2)
                    .textContentType(.streetAddressLine2)
                TextField("City", text: $city)
                    .textContentType(.addressCity)
                TextField("State", text: $state)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("Postal code", text: $postalCode)
                    .textContentType(.postalCode)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            Section {
                LabeledContent("Hourly rate") {
                    AutoClearNumberField(placeholder: "$0.00", value: $hourlyRate, style: .currency)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                InfoLabel("Pay rate", info: "Optional. If set, you can log what you owe as “hours × rate.” Leave at $0 to enter flat amounts.")
            }
            Section {
                Picker("Taxpayer ID type", selection: $w9TINType) {
                    Text("Select…").tag(W9TINType?.none)
                    ForEach(W9TINType.allCases) { Text($0.label).tag(W9TINType?.some($0)) }
                }
                .onChange(of: w9TINType) { _, _ in w9TIN = "" }
                LabeledContent(w9TINType?.label ?? String(localized: "Tax ID")) {
                    TINField(kind: w9TINType, text: $w9TIN)
                }
            } header: {
                InfoLabel("Tax details (for their 1099-NEC)", info: "Optional. The SSN/EIN from the W-9 they gave you. Stored securely in your Keychain, not the synced database — used to generate their 1099-NEC.")
            }
            Section {
                Toggle("Active", isOn: $isActive)
            }
            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .glFormBackground()
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView { contact in
                let draft = ContactsBridge.draft(from: contact)
                firstName = draft.firstName; lastName = draft.lastName
                businessName = draft.businessName
                email = draft.email; phone = draft.phoneNumber
                street1 = draft.street1; street2 = draft.street2
                city = draft.city; state = draft.state; postalCode = draft.postalCode
                showingContactPicker = false
            } onCancel: {
                showingContactPicker = false
            }
            .ignoresSafeArea()
        }
        .navigationTitle(editing == nil ? "New Subcontractor" : "Edit Subcontractor")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard !isSaving else { return }
                    isSaving = true
                    save()
                }
                .disabled(!isValid || isSaving)
            }
        }
        .alert("Couldn’t save their Tax ID", isPresented: $tinSaveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Their other details were saved, but the Tax ID wasn’t. Make sure your device is unlocked, then tap Save again.")
        }
    }

    private func save() {
        let trimmedStreet2 = trim(street2)
        let address = Address(
            street1: trim(street1),
            street2: trimmedStreet2.isEmpty ? nil : trimmedStreet2,
            city: trim(city),
            state: trim(state),
            postalCode: trim(postalCode)
        )
        let saved: Subcontractor
        // On the add path, reuse the record inserted on a prior attempt — otherwise a Tax-ID-failure
        // retry would insert a SECOND subcontractor (the resettable Save re-runs this whole method).
        if let sub = editing ?? insertedSubcontractor {
            sub.firstName = trim(firstName)
            sub.lastName = trim(lastName)
            sub.businessName = trim(businessName)
            sub.email = trim(email)
            sub.phone = trim(phone)
            sub.hourlyRate = hourlyRate
            sub.address = address
            sub.isActive = isActive
            sub.notes = trim(notes)
            saved = sub
        } else {
            let sub = Subcontractor(
                firstName: trim(firstName), lastName: trim(lastName),
                businessName: trim(businessName), email: trim(email), phone: trim(phone),
                hourlyRate: hourlyRate, address: address, isActive: isActive, notes: trim(notes)
            )
            modelContext.insert(sub)
            insertedSubcontractor = sub
            saved = sub
        }
        saved.w9TINType = w9TINType
        let tinSaved = saved.updateTIN(w9TIN)
        // Everything but the secure Tax ID is saved; if that one write failed, keep the form open
        // and tell the user instead of dismissing as if it all saved.
        guard tinSaved else { tinSaveFailed = true; isSaving = false; return }
        onSave?(saved)
        dismiss()
    }
}

#Preview("Add") {
    SubcontractorFormScreen()
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
