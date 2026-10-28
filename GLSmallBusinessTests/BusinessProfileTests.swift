//
//  BusinessProfileTests.swift
//  GLSmallBusinessTests
//
//  Computed helpers on the business profile: the send gate (isComplete), the owner's display
//  name, the light/dark logo fallback, the W-9 legal-name fallback, and the compliance-document
//  flags. (The W-9 enum accessors and labels live in EnumTests.)
//

import Testing
import Foundation
import SwiftUI
@testable import GLSmallBusiness

@MainActor
struct BusinessProfileTests {

    @Test func isCompleteNeedsNameAndOneContact() {
        let b = BusinessProfile()
        #expect(!b.isComplete)                                   // nothing set
        b.businessName = "Summit Tile"
        #expect(!b.isComplete)                                   // name only — no way to be reached
        b.phone = "850-555-0142"
        #expect(b.isComplete)                                    // name + phone is enough
        b.phone = ""; b.email = "office@summit.com"
        #expect(b.isComplete)                                    // name + email is enough (phone-only or email-only both valid)
        b.email = "   "
        #expect(!b.isComplete)                                   // blank contact again → name only
        b.email = "office@summit.com"; b.businessName = ""
        #expect(!b.isComplete)                                   // contact but no name
    }

    @Test func ownerFullNameJoinsAndTrims() {
        let b = BusinessProfile()
        #expect(b.ownerFullName == "")
        b.ownerFirstName = "  Adrian "
        b.ownerLastName = " Gutierrez "
        #expect(b.ownerFullName == "Adrian Gutierrez")
    }

    @Test func logoPrefersVariantThenFallsBack() {
        let b = BusinessProfile()
        #expect(b.logo(for: .light) == nil)
        #expect(b.logo(for: .dark) == nil)

        let light = Data([0x1]), dark = Data([0x2])
        b.logoData = light
        #expect(b.logo(for: .light) == light)
        #expect(b.logo(for: .dark) == light)        // only one logo → shows in both

        b.logoDataDark = dark
        #expect(b.logo(for: .dark) == dark)
        #expect(b.logo(for: .light) == light)

        b.logoData = nil
        #expect(b.logo(for: .light) == dark)        // light falls back to the dark variant
    }

    @Test func w9LegalNameFallsBackToBusinessName() {
        let b = BusinessProfile()
        b.businessName = "Summit Tile & Stone"
        #expect(b.w9LegalName == "Summit Tile & Stone")
        b.w9Name = "Summit Tile LLC"
        #expect(b.w9LegalName == "Summit Tile LLC")
        b.w9Name = "   "
        #expect(b.w9LegalName == "Summit Tile & Stone")
    }

    @Test func complianceDocumentFlags() {
        let b = BusinessProfile()
        #expect(!b.hasComplianceDocuments)
        b.wcExemptionData = Data([0x1])
        #expect(b.hasWCExemption)
        #expect(b.hasComplianceDocuments)
        b.wcExemptionData = nil
        b.licenseDocumentData = Data([0x1])
        #expect(b.hasLicenseDocument)
        #expect(b.hasComplianceDocuments)
        // Retired: the business-level WC insurance slot is dormant (the WC COI is per-customer).
        b.licenseDocumentData = nil
        b.wcInsuranceData = Data([0x1])
        #expect(!b.hasComplianceDocuments)
    }
}
