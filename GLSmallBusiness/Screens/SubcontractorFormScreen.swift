//
//  SubcontractorFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Add / edit a subcontractor. Mirrors EmployeeFormScreen / CustomerFormScreen: a Form in a
//  NavigationStack with the cream background, Cancel/Save, and an onSave callback (iPad auto-select).
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
        NavigationStack {
            Form {
                if editing == nil {
                    Section {
                        Button { showingContactPicker = true } label: {
                            Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("Pull a name, business, phone, email, and address from your phone's contacts.")
                            .textCase(nil)
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
                }
                Section("Address") {
                    TextField("Street", text: $street1)
                        .textContentType(.streetAddressLine1)
                    TextField("Apt / Suite (optional)", text: $street2)
                        .textContentType(.streetAddressLine2)
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
                    LabeledContent("Hourly rate") {
                        AutoClearNumberField(placeholder: "$0.00", value: $hourlyRate, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Pay rate")
                } footer: {
                    Text("Optional. If set, you can log what you owe as “hours × rate.” Leave at $0 to enter flat amounts.")
                        .textCase(nil)
                }
                Section {
                    Picker("Taxpayer ID type", selection: $w9TINType) {
                        Text("Select…").tag(W9TINType?.none)
                        ForEach(W9TINType.allCases) { Text($0.label).tag(W9TINType?.some($0)) }
                    }
                    .onChange(of: w9TINType) { _, _ in w9TIN = "" }
                    LabeledContent(w9TINType?.label ?? String(localized: "Tax ID")) {
                        TextField(w9TINType == .ein ? "12-3456789" : "123-45-6789", text: $w9TIN)
                            .multilineTextAlignment(.trailing)
                            #if !os(macOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                } header: {
                    Text("Tax details (for their 1099-NEC)")
                } footer: {
                    Text("Optional. The SSN/EIN from the W-9 they gave you. Stored securely in your Keychain, not the synced database — used to generate their 1099-NEC.")
                        .textCase(nil)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
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
        if let sub = editing {
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
            saved = sub
        }
        saved.w9TINType = w9TINType
        saved.updateTIN(w9TIN)
        onSave?(saved)
        dismiss()
    }
}

#Preview("Add") {
    SubcontractorFormScreen()
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
