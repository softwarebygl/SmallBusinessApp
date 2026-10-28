//
//  DocumentSettingsTests.swift
//  GLSmallBusinessTests
//
//  The "show logo / address on documents" toggles gate what the document generators read.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct DocumentSettingsTests {
    @Test func defaultsAreOn() {
        let p = BusinessProfile()
        #expect(p.showLogoOnDocuments)
        #expect(p.showAddressOnDocuments)
    }

    @Test func logoOnDocumentsGatesTheLogoData() {
        let p = BusinessProfile()
        p.logoData = Data([1, 2, 3])
        p.showLogoOnDocuments = true
        #expect(p.documentLogoData != nil)            // shown when on
        p.showLogoOnDocuments = false
        #expect(p.documentLogoData == nil)            // omitted when off — but logoData itself is kept
        #expect(p.logoData != nil)
    }

    @Test func addressOnDocumentsGatesTheAddress() {
        let p = BusinessProfile()
        p.address = Address(street1: "1 Main St", city: "Miami", state: "FL", postalCode: "32301")
        p.showAddressOnDocuments = true
        #expect(p.documentAddress.street1 == "1 Main St")   // shown when on
        p.showAddressOnDocuments = false
        #expect(p.documentAddress.street1.isEmpty)          // headers skip an empty address
        #expect(p.address.street1 == "1 Main St")           // but the real address is kept for the app + W-9
    }
}
