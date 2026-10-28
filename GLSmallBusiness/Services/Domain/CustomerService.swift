//
//  CustomerService.swift
//  GLSmallBusiness
//
//  Every customer write — the Customer form, the detail screen's photo, and (later) the assistant's
//  tools all come through here, so there is one save path to get right. Certificates are
//  `DocumentService`'s, delete is `DeletionService`'s.
//
//  Rules kept from the form: every text field trimmed; an empty Apt/Suite and an empty business
//  name store as nil; a customer needs a first, last or business name; the address goes through
//  the flat columns only (the legacy composite is write-forbidden, see Customer.legacyAddress).
//  New here: edits touch only the fields that changed (`setIfChanged`), and every write ends in
//  `saveChanges()`, so a new customer gets its syncID now instead of at the next launch.
//

import Foundation
import SwiftData

/// A customer's editable fields, as a form or a tool supplies them (untrimmed is fine).
nonisolated struct CustomerDraft: Equatable, Sendable {
    var firstName = ""
    var middleName = ""
    var lastName = ""
    var businessName = ""
    var email = ""
    var phoneNumber = ""
    var officePhone = ""
    var address = Address()
    var serviceAddress = Address()
    var sameAsBillingAddress = true

    init(firstName: String = "", middleName: String = "", lastName: String = "",
         businessName: String = "", email: String = "", phoneNumber: String = "",
         officePhone: String = "", address: Address = Address(),
         serviceAddress: Address = Address(), sameAsBillingAddress: Bool = true) {
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.businessName = businessName
        self.email = email
        self.phoneNumber = phoneNumber
        self.officePhone = officePhone
        self.address = address
        self.serviceAddress = serviceAddress
        self.sameAsBillingAddress = sameAsBillingAddress
    }

    /// The customer's current values — the starting point for a partial edit.
    @MainActor
    init(_ customer: Customer) {
        self.init(firstName: customer.firstName, middleName: customer.middleName,
                  lastName: customer.lastName, businessName: customer.businessName ?? "",
                  email: customer.email, phoneNumber: customer.phoneNumber,
                  officePhone: customer.officePhone, address: customer.address,
                  serviceAddress: customer.rawServiceAddress,
                  sameAsBillingAddress: customer.sameAsBillingAddress)
    }

    /// Every field trimmed; an empty Apt/Suite becomes nil (the form's rule).
    var trimmed: CustomerDraft {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let street2 = t(address.street2 ?? "")
        let sStreet2 = t(serviceAddress.street2 ?? "")
        return CustomerDraft(
            firstName: t(firstName), middleName: t(middleName), lastName: t(lastName),
            businessName: t(businessName), email: t(email), phoneNumber: t(phoneNumber),
            officePhone: t(officePhone),
            address: Address(street1: t(address.street1), street2: street2.isEmpty ? nil : street2,
                             city: t(address.city), state: t(address.state),
                             postalCode: t(address.postalCode)),
            serviceAddress: Address(street1: t(serviceAddress.street1), street2: sStreet2.isEmpty ? nil : sStreet2,
                                    city: t(serviceAddress.city), state: t(serviceAddress.state),
                                    postalCode: t(serviceAddress.postalCode)),
            sameAsBillingAddress: sameAsBillingAddress)
    }

    /// First, last or business name — what the form's Save requires.
    var hasName: Bool {
        let d = trimmed
        return !d.firstName.isEmpty || !d.lastName.isEmpty || !d.businessName.isEmpty
    }
}

/// The two insurer-issued certificates a customer can hold.
nonisolated enum CustomerCertificate: Sendable {
    case generalLiability
    case workersComp
}

@MainActor
enum CustomerService {

    /// Adds a customer. `photo` (e.g. carried in from Contacts) is stored when given.
    @discardableResult
    static func create(_ draft: CustomerDraft, photo: Data? = nil, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws -> Customer {
        try DomainGate.requireCanCreate(Customer.self, cap: FreeTier.customers,
                                        operation: .saveCustomer, in: context, subscription)
        let d = try validated(draft)
        let customer = Customer(
            firstName: d.firstName, middleName: d.middleName, lastName: d.lastName,
            email: d.email, phoneNumber: d.phoneNumber, officePhone: d.officePhone,
            businessName: d.businessName.isEmpty ? nil : d.businessName, address: d.address,
            serviceAddress: d.sameAsBillingAddress ? nil : d.serviceAddress,
            sameAsBillingAddress: d.sameAsBillingAddress)
        if let photo { customer.profileImageData = photo }
        context.insert(customer)
        context.saveChanges()
        return customer
    }

    /// Edits a customer in place. `photo` replaces the current one only when given — importing a
    /// contact without a picture never blanks the photo already set.
    static func update(_ customer: Customer, with draft: CustomerDraft, photo: Data? = nil,
                       in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveCustomer, subscription)
        try DomainGate.requireLive(customer, .saveCustomer)
        let d = try validated(draft)
        setIfChanged(customer, \.firstName, d.firstName)
        setIfChanged(customer, \.middleName, d.middleName)
        setIfChanged(customer, \.lastName, d.lastName)
        setIfChanged(customer, \.email, d.email)
        setIfChanged(customer, \.phoneNumber, d.phoneNumber)
        setIfChanged(customer, \.officePhone, d.officePhone)
        setIfChanged(customer, \.businessName, d.businessName.isEmpty ? nil : d.businessName)
        // The flats behind the `address` façade, one by one: assigning the façade would write all
        // five columns even when one changed.
        setIfChanged(customer, \.addressStreet1, d.address.street1)
        setIfChanged(customer, \.addressStreet2, d.address.street2 ?? "")
        setIfChanged(customer, \.addressCity, d.address.city)
        setIfChanged(customer, \.addressState, d.address.state)
        setIfChanged(customer, \.addressPostalCode, d.address.postalCode)
        setIfChanged(customer, \.sameAsBillingAddress, d.sameAsBillingAddress)
        if !d.sameAsBillingAddress {
            setIfChanged(customer, \.serviceAddressStreet1, d.serviceAddress.street1)
            setIfChanged(customer, \.serviceAddressStreet2, d.serviceAddress.street2 ?? "")
            setIfChanged(customer, \.serviceAddressCity, d.serviceAddress.city)
            setIfChanged(customer, \.serviceAddressState, d.serviceAddress.state)
            setIfChanged(customer, \.serviceAddressPostalCode, d.serviceAddress.postalCode)
        }
        if let photo { setIfChanged(customer, \.profileImageData, photo) }
        context.saveChanges()
    }

    /// Sets the profile photo, or removes it with `nil`.
    static func setPhoto(_ data: Data?, for customer: Customer, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveCustomer, subscription)
        try DomainGate.requireLive(customer, .saveCustomer)
        setIfChanged(customer, \.profileImageData, data)
        context.saveChanges()
    }

    private static let reservedPronounPhrases: Set<String> = [
        "me", "for me", "for, me", "me, for", "myself", "for myself",
        "to me", "for me client", "for me customer", "client for me",
        "self", "yo", "para mi", "para mí", "mi", "mí", "a mi", "a mí",
        "mismo", "para mi mismo", "para mí mismo"
    ]

    /// True when the WHOLE name is a phrase like "me", "for me" or "para mí" — what the
    /// assistant writes when someone says "add this for me". Owner ruling 2026-09-26: only the
    /// assistant refuses these (MBCustomerTool), and only whole phrases; a real client whose
    /// first or last name is "Mi", "Me" or "Yo" (e.g. "Mi Nguyen") always saves, and the
    /// New Customer form saves any name. The whole name is the person's name, or the business
    /// name when there is no person name.
    static func isReservedPronounName(first: String, last: String, business: String?) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased()
             .components(separatedBy: CharacterSet.punctuationCharacters)
             .joined(separator: " ")
             .components(separatedBy: .whitespacesAndNewlines)
             .filter { !$0.isEmpty }
             .joined(separator: " ")
        }
        let person = normalized("\(first) \(last)")
        let whole = person.isEmpty ? normalized(business ?? "") : person
        guard !whole.isEmpty else { return false }
        return reservedPronounPhrases.contains { normalized($0) == whole }
    }

    private static func validated(_ draft: CustomerDraft) throws -> CustomerDraft {
        guard draft.hasName else { throw DomainGate.refusal(.nameRequired, .saveCustomer) }
        return draft.trimmed
    }
}
