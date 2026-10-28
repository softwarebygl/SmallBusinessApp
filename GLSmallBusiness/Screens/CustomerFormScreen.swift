//
//  CustomerFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import GoldLifeUI
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
    @State private var sameAsBillingAddress: Bool
    @State private var serviceStreet1: String
    @State private var serviceStreet2: String
    @State private var serviceCity: String
    @State private var serviceState: String
    @State private var servicePostalCode: String
    @State private var showingContactPicker = false
    /// Set when a lapsed subscription refuses this save — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal CustomerService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

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
        _sameAsBillingAddress = State(initialValue: editing?.sameAsBillingAddress ?? true)
        _serviceStreet1    = State(initialValue: editing?.serviceAddressStreet1 ?? "")
        _serviceStreet2    = State(initialValue: editing?.serviceAddressStreet2 ?? "")
        _serviceCity       = State(initialValue: editing?.serviceAddressCity ?? "")
        _serviceState      = State(initialValue: editing?.serviceAddressState ?? "")
        _servicePostalCode = State(initialValue: editing?.serviceAddressPostalCode ?? "")
    }

    private var isValid: Bool {
        !trim(firstName).isEmpty
            || !trim(lastName).isEmpty
            || !trim(businessName).isEmpty
    }

    @State private var initialDigest: String?
    private var digest: String {
        [firstName, middleName, lastName, businessName, email, phoneNumber, officePhone,
         street1, street2, city, state, postalCode,
         String(sameAsBillingAddress), serviceStreet1, serviceStreet2, serviceCity, serviceState, servicePostalCode].joined(separator: "|")
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            if editing == nil {
                Section {
                    HStack {
                        Button {
                            showingContactPicker = true
                        } label: {
                            Label("Import from Phone Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        InfoButton(text: "Pull a name, phone, email, and address straight from your phone's contacts.", topic: "Import from Phone Contacts")
                    }
                }
            }

            Section("Name") {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                TextField("Middle name (optional)", text: $middleName)
                    .textContentType(.middleName)
                    .textInputAutocapitalization(.words)
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
            }
            Section("Business") {
                TextField("Business name (optional)", text: $businessName)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
            }
            Section("Contact") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if !os(macOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                PhoneTextField(placeholder: "Phone", text: $phoneNumber)
                PhoneTextField(placeholder: "Office number (optional)", text: $officePhone)
            }
            Section("Billing Address") {
                GLAddressField("Street", street: $street1, city: $city, state: $state, zip: $postalCode)
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
                Toggle("Same as billing address", isOn: $sameAsBillingAddress)
                if !sameAsBillingAddress {
                    GLAddressField("Service street", street: $serviceStreet1, city: $serviceCity, state: $serviceState, zip: $servicePostalCode)
                        .textContentType(.streetAddressLine1)
                    TextField("Apt / Suite (optional)", text: $serviceStreet2)
                        .textContentType(.streetAddressLine2)
                    TextField("City", text: $serviceCity)
                        .textContentType(.addressCity)
                    TextField("State", text: $serviceState)
                        .textContentType(.addressState)
                        .textInputAutocapitalization(.characters)
                    TextField("Postal code", text: $servicePostalCode)
                        .textContentType(.postalCode)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                }
            } header: {
                HStack {
                    Text("Service Address")
                    Spacer()
                    InfoButton(text: "The job site or property address where work is performed. When different from billing, this will auto-fill into new estimates and contracts.", topic: "Service Address")
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView { contact in
                fill(from: ContactsBridge.draft(from: contact))
                showingContactPicker = false
            } onCancel: {
                showingContactPicker = false
            }
            .ignoresSafeArea()
        }
        .navigationTitle(GLScript.padded(editing == nil ? mbLoc("New Customer") : mbLoc("Edit Customer")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editing == nil ? mbLoc("New Customer") : mbLoc("Edit Customer"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !isValid, action: save)
            }
        }
    }

    private func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seeds the form fields from an imported contact, for the user to review before saving.
    /// A photo carried in from the Contacts picker, applied on save.
    @State private var importedPhoto: Data?

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
        // Only when the contact actually carried one: importing must never
        // blank a photo the person already set on an existing customer.
        if let photo = draft.imageData { importedPhoto = photo }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        // A lapsed subscription writes nothing — and says so, rather than dismissing as if it had
        // saved. Placed at the TOP so no model property is touched before the refusal: SwiftData
        // autosaves, so a half-applied edit would persist even though the form said no.
        guard ReadOnlyGate.allows(.saveCustomer, into: $readOnlyRefusal) else { return false }
        // CustomerService trims, validates and saves — the same path the assistant uses.
        let draft = CustomerDraft(
            firstName: firstName, middleName: middleName, lastName: lastName,
            businessName: businessName, email: email, phoneNumber: phoneNumber,
            officePhone: officePhone,
            address: Address(street1: street1, street2: street2, city: city,
                             state: state, postalCode: postalCode),
            serviceAddress: Address(street1: serviceStreet1, street2: serviceStreet2,
                                    city: serviceCity, state: serviceState, postalCode: servicePostalCode),
            sameAsBillingAddress: sameAsBillingAddress
        )
        let saved: Customer
        do {
            if let customer = editing {
                try CustomerService.update(customer, with: draft, photo: importedPhoto, in: modelContext)
                saved = customer
            } else {
                saved = try CustomerService.create(draft, photo: importedPhoto, in: modelContext)
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        // The add flow's onSave replaces the navigation path itself; dismissing on top of that
        // is a second stack mutation in the same tick — the exact blank-screen push. One owner.
        if let onSave { onSave(saved) } else { dismiss() }
        return true
    }
}

#Preview("Add") {
    CustomerFormScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
