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
    @Environment(\.colorScheme) private var colorScheme

    let editing: Customer?

    @State private var firstName: String
    @State private var lastName: String
    @State private var businessName: String
    @State private var email: String
    @State private var phoneNumber: String
    @State private var street1: String
    @State private var street2: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String

    init(editing: Customer? = nil) {
        self.editing = editing
        _firstName    = State(initialValue: editing?.firstName ?? "")
        _lastName     = State(initialValue: editing?.lastName ?? "")
        _businessName = State(initialValue: editing?.businessName ?? "")
        _email        = State(initialValue: editing?.email ?? "")
        _phoneNumber  = State(initialValue: editing?.phoneNumber ?? "")
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
                    TextField("Phone", text: $phoneNumber)
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
            }
            .scrollContentBackground(.hidden)
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
            .navigationTitle(editing == nil ? "New Customer" : "Edit Customer")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                }
            }
        }
    }

    private func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if let customer = editing {
            customer.firstName = trim(firstName)
            customer.lastName = trim(lastName)
            customer.email = trim(email)
            customer.phoneNumber = trim(phoneNumber)
            customer.businessName = business
            customer.address = address
        } else {
            let customer = Customer(
                firstName: trim(firstName),
                lastName: trim(lastName),
                email: trim(email),
                phoneNumber: trim(phoneNumber),
                businessName: business,
                address: address
            )
            modelContext.insert(customer)
        }
        dismiss()
    }
}

#Preview("Add") {
    CustomerFormScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
