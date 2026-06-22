//
//  ContactsBridgeTests.swift
//  GLSmallBusinessTests
//
//  The CNContact <-> Customer mapping behind import/export is pure and worth testing directly.
//

import Testing
import Foundation
import Contacts
@testable import GLSmallBusiness

@MainActor
struct ContactsBridgeTests {

    @Test func draftMapsPickedContactFields() {
        let c = CNMutableContact()
        c.givenName = "Dana"; c.middleName = "R"; c.familyName = "Reed"
        c.organizationName = "Reed GC"
        c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "dana@reed.com" as NSString)]
        c.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-1000")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "555-2000")),
        ]
        let postal = CNMutablePostalAddress()
        postal.street = "123 Main St\nSuite 4"
        postal.city = "Tampa"; postal.state = "FL"; postal.postalCode = "33601"
        c.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: postal)]

        let d = ContactsBridge.draft(from: c)
        #expect(d.firstName == "Dana")
        #expect(d.middleName == "R")
        #expect(d.lastName == "Reed")
        #expect(d.businessName == "Reed GC")
        #expect(d.email == "dana@reed.com")
        #expect(d.phoneNumber == "555-1000")   // mobile → phone (text recipient)
        #expect(d.officePhone == "555-2000")   // work → office
        #expect(d.street1 == "123 Main St")
        #expect(d.street2 == "Suite 4")
        #expect(d.city == "Tampa")
        #expect(d.state == "FL")
        #expect(d.postalCode == "33601")
    }

    @Test func draftFallsBackForUnlabeledNumbers() {
        let c = CNMutableContact()
        c.givenName = "Sam"
        c.phoneNumbers = [
            CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-7777")),
            CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-8888")),
        ]
        let d = ContactsBridge.draft(from: c)
        #expect(d.phoneNumber == "555-7777")   // first → phone
        #expect(d.officePhone == "555-8888")   // second distinct → office
    }

    @Test func contactFromCustomerMapsFields() {
        let cust = Customer(firstName: "Dana", middleName: "R", lastName: "Reed",
                            email: "dana@reed.com", phoneNumber: "555-1000", officePhone: "555-2000",
                            businessName: "Reed GC",
                            address: Address(street1: "123 Main St", city: "Tampa", state: "FL", postalCode: "33601"))
        let c = ContactsBridge.contact(from: cust)
        #expect(c.givenName == "Dana")
        #expect(c.middleName == "R")
        #expect(c.familyName == "Reed")
        #expect(c.organizationName == "Reed GC")
        #expect(c.emailAddresses.first.map { $0.value as String } == "dana@reed.com")
        #expect(c.phoneNumbers.contains { $0.value.stringValue == "555-1000" })
        #expect(c.phoneNumbers.contains { $0.value.stringValue == "555-2000" })
        #expect(c.postalAddresses.first?.value.city == "Tampa")
    }

    @Test func contactFromCustomerOmitsEmptyFields() {
        let cust = Customer(firstName: "Solo")
        let c = ContactsBridge.contact(from: cust)
        #expect(c.givenName == "Solo")
        #expect(c.emailAddresses.isEmpty)
        #expect(c.phoneNumbers.isEmpty)
        #expect(c.postalAddresses.isEmpty)
    }

    @Test func contactFromEmployeeMapsNameEmailPhone() {
        let e = Employee(firstName: "Juan", lastName: "Gonzalez", email: "juan@example.com", phone: "555-0110")
        let c = ContactsBridge.contact(from: e)
        #expect(c.givenName == "Juan" && c.familyName == "Gonzalez")
        #expect(c.emailAddresses.first.map { $0.value as String } == "juan@example.com")
        #expect(c.phoneNumbers.first?.value.stringValue == "555-0110")
        // No empty fields
        #expect(ContactsBridge.contact(from: Employee(firstName: "Solo")).phoneNumbers.isEmpty)
    }

    @Test func contactFromSubcontractorMapsBusinessAndAddress() {
        let sub = Subcontractor(firstName: "Luis", lastName: "Mendoza", businessName: "Mendoza Plumbing",
                                email: "luis@mp.com", phone: "555-0164",
                                address: Address(street1: "904 Industrial Dr", city: "Tallahassee", state: "FL", postalCode: "32310"))
        let c = ContactsBridge.contact(from: sub)
        #expect(c.givenName == "Luis" && c.familyName == "Mendoza")
        #expect(c.organizationName == "Mendoza Plumbing")
        #expect(c.emailAddresses.first.map { $0.value as String } == "luis@mp.com")
        #expect(c.phoneNumbers.first?.value.stringValue == "555-0164")
        #expect(c.postalAddresses.first?.value.city == "Tallahassee")
    }
}
