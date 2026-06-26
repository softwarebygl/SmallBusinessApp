//
//  ProfileCustomerTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
import SwiftUI
@testable import GLSmallBusiness

@MainActor
struct ProfileCustomerTests {
    @Test func ownerFullNameJoinsAndTrims() {
        let p = BusinessProfile()
        #expect(p.ownerFullName == "")
        p.ownerFirstName = "  Adrian "
        p.ownerLastName = " Gutierrez "
        #expect(p.ownerFullName == "Adrian Gutierrez")
    }

    @Test func isCompleteNeedsNameAndOneContact() {
        let p = BusinessProfile()
        #expect(!p.isComplete)
        p.businessName = "Gold Life LLC"
        #expect(!p.isComplete)        // name only — needs a phone or email
        p.phone = "555"
        #expect(p.isComplete)         // name + phone is enough (phone-only businesses are valid)
        p.phone = ""; p.email = "a@b.com"
        #expect(p.isComplete)         // name + email is also enough
    }

    @Test func w9LegalNameFallsBackToBusinessName() {
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        #expect(p.w9LegalName == "Gold Life LLC")
        p.w9Name = "Adrian Gutierrez"
        #expect(p.w9LegalName == "Adrian Gutierrez")
    }

    @Test func complianceDocumentsDetected() {
        let p = BusinessProfile()
        #expect(!p.hasComplianceDocuments)
        p.wcInsuranceData = Data("pdf".utf8)
        #expect(p.hasWCInsurance)
        #expect(p.hasComplianceDocuments)
    }

    @Test func logoPrefersVariantThenFallsBack() {
        let p = BusinessProfile()
        let light = Data("light".utf8)
        p.logoData = light
        #expect(p.logo(for: .light) == light)
        #expect(p.logo(for: .dark) == light)   // dark falls back to the light/default
        let dark = Data("dark".utf8)
        p.logoDataDark = dark
        #expect(p.logo(for: .dark) == dark)
    }

    // MARK: - Customer

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

    // MARK: - Recipient pre-fill (live customer, snapshot fallback)

    @Test func estimateRecipientPrefersLiveCustomerThenSnapshot() {
        let c = Customer(firstName: "Dana", email: "dana@x.com", phoneNumber: "555-1000")
        let est = Estimate(customer: c)   // snapshots email/phone at creation
        #expect(est.recipientEmail == "dana@x.com")
        #expect(est.recipientPhone == "555-1000")

        c.email = "new@x.com"; c.phoneNumber = "555-2000"   // updated after creation
        #expect(est.recipientEmail == "new@x.com")
        #expect(est.recipientPhone == "555-2000")

        c.email = "  "; c.phoneNumber = ""                  // cleared → fall back to snapshot
        #expect(est.recipientEmail == "dana@x.com")
        #expect(est.recipientPhone == "555-1000")
    }

    @Test func invoiceRecipientFallsBackToSnapshotWithoutLiveCustomer() {
        let inv = Invoice(number: "INV-1")
        inv.customerEmail = "snap@x.com"
        inv.customerPhone = "555-9999"
        #expect(inv.customer == nil)
        #expect(inv.recipientEmail == "snap@x.com")
        #expect(inv.recipientPhone == "555-9999")
    }

    // MARK: - Address

    @Test func addressFormatting() {
        #expect(Address().isEmpty)
        let a = Address(street1: "1 A St", city: "Tampa", state: "FL", postalCode: "33601")
        #expect(!a.isEmpty)
        let lines = a.formattedMultiline
        #expect(lines.contains("1 A St"))
        #expect(lines.contains("Tampa, FL 33601"))
    }
}
