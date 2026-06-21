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
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trim(firstName).isEmpty || !trim(lastName).isEmpty || !trim(businessName).isEmpty
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
                    Toggle("Active", isOn: $isActive)
                } footer: {
                    Text("Their W-9, Tax ID, and 1099-NEC come in a later update.")
                        .textCase(nil)
                }
                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .glFormBackground()
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
            sub.address = address
            sub.isActive = isActive
            sub.notes = trim(notes)
            saved = sub
        } else {
            let sub = Subcontractor(
                firstName: trim(firstName), lastName: trim(lastName),
                businessName: trim(businessName), email: trim(email), phone: trim(phone),
                address: address, isActive: isActive, notes: trim(notes)
            )
            modelContext.insert(sub)
            saved = sub
        }
        onSave?(saved)
        dismiss()
    }
}

#Preview("Add") {
    SubcontractorFormScreen()
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
