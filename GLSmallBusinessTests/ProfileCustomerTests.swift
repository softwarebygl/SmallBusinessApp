//
//  ProfileCustomerTests.swift
//  GLSmallBusinessTests
//
//  Customer display helpers: the list name, initials, and full name. (BusinessProfile's helpers
//  live in BusinessProfileTests; the estimate/invoice recipient pre-fill in the
//  CalendarJobsEstimates / InvoiceLifecycle coverage suites; Address in AddressFormattingTests.)
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct ProfileCustomerTests {

    @Test func customerListDisplayNameVariants() {
        let c = Customer(firstName: "Devin", lastName: "Odom")
        #expect(c.listDisplayName == "Odom, Devin")
        let lastOnly = Customer(lastName: "Odom")
        #expect(lastOnly.listDisplayName == "Odom")
        let firstOnly = Customer(firstName: "Devin")
        #expect(firstOnly.listDisplayName == "Devin")
        let biz = Customer(businessName: "Frog Realty")
        #expect(biz.listDisplayName == "Frog Realty")
        let nameless = Customer()
        #expect(nameless.listDisplayName == "No name")
    }

    @Test func customerInitials() {
        #expect(Customer(firstName: "Devin", lastName: "Odom").initials == "DO")
        #expect(Customer(businessName: "frog").initials == "F")
        #expect(Customer().initials == "?")
    }

    @Test func customerFullNameIncludesMiddleWhenPresent() {
        #expect(Customer(firstName: "Devin", lastName: "Odom").fullName == "Devin Odom")
        let withMiddle = Customer(firstName: "Devin", middleName: "Ray", lastName: "Odom")
        #expect(withMiddle.fullName == "Devin Ray Odom")
        #expect(Customer().fullName == "")
        #expect(withMiddle.officePhone == "")   // office defaults empty / optional
    }
}
