//
//  AddressFormattingTests.swift
//  GLSmallBusinessTests
//
//  Address.formattedMultiline / isEmpty — omitting empty parts, the second street line,
//  partial city/state/zip, and whitespace-only fields.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct AddressFormattingTests {
    @Test func includesSecondStreetLine() {
        let a = Address(street1: "1 A St", street2: "Apt 5", city: "Tampa", state: "FL", postalCode: "33601")
        #expect(!a.isEmpty)
        #expect(a.formattedMultiline == "1 A St\nApt 5\nTampa, FL 33601")
    }

    @Test func omitsMissingCityKeepsStateAndZip() {
        let a = Address(state: "FL", postalCode: "33601")
        #expect(a.formattedMultiline == "FL 33601")
    }

    @Test func streetOnly() {
        #expect(Address(street1: "1 A St").formattedMultiline == "1 A St")
    }

    @Test func cityOnly() {
        #expect(Address(city: "Tampa").formattedMultiline == "Tampa")
    }

    @Test func emptyAndWhitespaceOnlyAreEmpty() {
        #expect(Address().isEmpty)
        let a = Address(street1: "  ", city: " ", state: "  ", postalCode: " ")
        #expect(a.isEmpty)
        #expect(a.formattedMultiline == "")
    }
}
