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

    @Test func isCompleteNeedsNamePhoneEmail() {
        let p = BusinessProfile()
        #expect(!p.isComplete)
        p.businessName = "Gold Life LLC"
        p.phone = "555"
        #expect(!p.isComplete)        // still missing email
        p.email = "a@b.com"
        #expect(p.isComplete)
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
        p.proofOfInsuranceData = Data("pdf".utf8)
        #expect(p.hasProofOfInsurance)
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
