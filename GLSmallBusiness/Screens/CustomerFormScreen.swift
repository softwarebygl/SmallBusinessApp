//
//  CustomerFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData

struct CustomerFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let editing: Customer?
    /// Called with the saved customer (created or edited) — lets a caller auto-select a new one.
    var onSave: ((Customer) -> Void)? = nil

    @State private var firstName: String
    @State private var middleName: String
    @State private var lastName: String
    @State private var businessName: String
    @State private var email: String
    @State private var phoneNumber: String
    @State private var officePhone: String
    @State private var street1: String
    @State private var street2: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var showingContactPicker = false

    init(editing: Customer? = nil, onSave: ((Customer) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _firstName    = State(initialValue: editing?.firstName ?? "")
        _middleName   = State(initialValue: editing?.middleName ?? "")
        _lastName     = State(initialValue: editing?.lastName ?? "")
        _businessName = State(initialValue: editing?.businessName ?? "")
        _email        = State(initialValue: editing?.email ?? "")
        _phoneNumber  = State(initialValue: editing?.phoneNumber ?? "")
        _officePhone  = State(initialValue: editing?.officePhone ?? "")
        _street1      = State(initialValue: editing?.address.street1 ?? "")
        _street2      = State(initialValue: editing?.address.street2 ?? "")
        _city         = State(initialValue: editing?.address.city ?? "")
        _state        = State(initialValue: editing?.address.state ?? "")
        _postalCode   = State(initialValue: editing?.address.postalCode ?? "")
    }

    private var isValid: Bool {
        !trim(firstName).isEmpty
            || !trim(lastName).isEmpty
            || !trim(businessName).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Section {
                        HStack {
                            Button {
                                showingContactPicker = true
                            } label: {
                                Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            InfoButton(text: "Pull a name, phone, email, and address straight from your phone's contacts.")
                        }
                    }
                }

                Section("Name") {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Middle name (optional)", text: $middleName)
                        .textContentType(.middleName)
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
                    TextField("Phone", text: $phoneNumber)
                        .textContentType(.telephoneNumber)
                        #if !os(macOS)
                        .keyboardType(.phonePad)
                        #endif
                    TextField("Office number (optional)", text: $officePhone)
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
                        .textInputAutocapitalization(.characters)
                    TextField("Postal code", text: $postalCode)
                        .textContentType(.postalCode)
                        #if !os(macOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
            }
            .glFormBackground()
            .sheet(isPresented: $showingContactPicker) {
                ContactPickerView { contact in
                    fill(from: ContactsBridge.draft(from: contact))
                    showingContactPicker = false
                } onCancel: {
                    showingContactPicker = false
                }
                .ignoresSafeArea()
            }
            .navigationTitle(editing == nil ? "New Customer" : "Edit Customer")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SaveOnceButton(disabled: !isValid, action: save)
                }
            }
        }
    }

    private func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seeds the form fields from an imported contact, for the user to review before saving.
    private func fill(from draft: ContactsBridge.Draft) {
        firstName = draft.firstName
        middleName = draft.middleName
        lastName = draft.lastName
        businessName = draft.businessName
        email = draft.email
        phoneNumber = draft.phoneNumber
        officePhone = draft.officePhone
        street1 = draft.street1
        street2 = draft.street2
        city = draft.city
        state = draft.state
        postalCode = draft.postalCode
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
        let trimmedBusiness = trim(businessName)
        let business: String? = trimmedBusiness.isEmpty ? nil : trimmedBusiness

        let saved: Customer
        if let customer = editing {
            customer.firstName = trim(firstName)
            customer.middleName = trim(middleName)
            customer.lastName = trim(lastName)
            customer.email = trim(email)
            customer.phoneNumber = trim(phoneNumber)
            customer.officePhone = trim(officePhone)
            customer.businessName = business
            customer.address = address
            saved = customer
        } else {
            let customer = Customer(
                firstName: trim(firstName),
                middleName: trim(middleName),
                lastName: trim(lastName),
                email: trim(email),
                phoneNumber: trim(phoneNumber),
                officePhone: trim(officePhone),
                businessName: business,
                address: address
            )
            modelContext.insert(customer)
            saved = customer
        }
        onSave?(saved)
        dismiss()
    }
}

#Preview("Add") {
    CustomerFormScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
