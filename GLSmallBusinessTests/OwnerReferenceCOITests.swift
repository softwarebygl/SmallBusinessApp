//
//  OwnerReferenceCOITests.swift
//  GLSmallBusinessTests
//
//  The optional, owner-only reference Certificate of Insurance must round-trip like any document
//  slot AND stay completely separate from the customer-facing compliance set — so it can never
//  leak into the "share all" bundle or the Contractor Package (both iterate ComplianceKind).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct OwnerReferenceCOITests {

    @Test func storesAndClearsReferenceCOI() {
        let p = BusinessProfile()
        #expect(p.ownerReferenceCOIData == nil)
        #expect(p.ownerReferenceCOIName == "")

        let blob = Data("blank-coi".utf8)
        p.ownerReferenceCOIData = blob
        p.ownerReferenceCOIName = "Blank-COI.pdf"
        #expect(p.ownerReferenceCOIData == blob)
        #expect(p.ownerReferenceCOIName == "Blank-COI.pdf")

        p.ownerReferenceCOIData = nil
        p.ownerReferenceCOIName = ""
        #expect(p.ownerReferenceCOIData == nil)
        #expect(p.ownerReferenceCOIName == "")
    }

    /// The reference COI must NOT be a `ComplianceKind`. That's the guarantee that keeps it out of
    /// the sheet's "share all" `ShareLink` and the Contractor Package — both iterate
    /// `ComplianceKind.allCases`. If someone adds it as a kind later, this fails loudly.
    @Test func referenceCOIIsNotAComplianceKind() {
        #expect(ComplianceKind.allCases.count == 3)
        #expect(Set(ComplianceKind.allCases) == [.wcInsurance, .wcExemption, .license])
    }

    /// Uploading only the reference COI must not register as a compliance/credential document
    /// (it would otherwise wrongly badge the "Insurance & Licensing" row as complete).
    @Test func referenceCOIDoesNotCountAsComplianceDocument() {
        let p = BusinessProfile()
        p.ownerReferenceCOIData = Data("blank-coi".utf8)
        #expect(!p.hasComplianceDocuments)
        #expect(!p.hasWCInsurance)
        #expect(!p.hasWCExemption)
        #expect(!p.hasLicenseDocument)
    }

    /// The reference COI is isolated from every compliance slot, in both directions.
    @Test func referenceCOIIsolatedFromComplianceSlots() {
        let p = BusinessProfile()

        // Filling every compliance slot leaves the reference COI untouched.
        for kind in ComplianceKind.allCases {
            kind.store(p, data: Data("cert".utf8), name: "cert.pdf")
        }
        #expect(p.hasComplianceDocuments)
        #expect(p.ownerReferenceCOIData == nil)

        // Filling the reference COI doesn't bleed into any compliance slot.
        let coi = Data("blank-coi".utf8)
        p.ownerReferenceCOIData = coi
        for kind in ComplianceKind.allCases {
            #expect(kind.data(p) != coi)
        }
    }
}
