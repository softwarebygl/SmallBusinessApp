//
//  UserProfileTests.swift
//  GLSmallBusinessTests
//
//  The account owner's computed display helpers: full name, monogram initials, and the
//  has-details / has-signature flags.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct UserProfileTests {

    @Test func fullNameTrimsAndDropsEmptyParts() {
        let p = UserProfile()
        p.firstName = "Adrian"; p.lastName = "Gold"
        #expect(p.fullName == "Adrian Gold")
        p.lastName = ""
        #expect(p.fullName == "Adrian")
        p.firstName = "   "
        #expect(p.fullName == "")
    }

    @Test func initials() {
        let p = UserProfile()
        p.firstName = "Adrian"; p.lastName = "Gold"
        #expect(p.initials == "AG")
        p.lastName = ""
        #expect(p.initials == "A")
        p.firstName = ""
        #expect(p.initials == "?")
    }

    @Test func hasDetailsIsTrueWhenAnyFieldSet() {
        let p = UserProfile()
        #expect(!p.hasDetails)
        p.email = "owner@example.com"
        #expect(p.hasDetails)
        p.email = ""; p.phone = "555-0100"
        #expect(p.hasDetails)
        p.phone = ""; p.firstName = "Adrian"
        #expect(p.hasDetails)
    }

    @Test func hasSignatureTracksData() {
        let p = UserProfile()
        #expect(!p.hasSignature)
        p.signatureData = Data([0x1, 0x2, 0x3])
        #expect(p.hasSignature)
    }
}
