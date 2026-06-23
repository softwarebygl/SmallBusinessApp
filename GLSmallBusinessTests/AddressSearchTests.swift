//
//  AddressSearchTests.swift
//  GLSmallBusinessTests
//
//  Covers the one pure piece of the address-typeahead feature: assembling the street line from a
//  MapKit result's house number + street name when either part may be missing or padded.
//

import Testing
@testable import GLSmallBusiness

struct AddressSearchTests {

    @Test func joinsNumberAndStreet() {
        #expect(AddressSearchResult.streetLine(number: "88", street: "Lakeshore Dr") == "88 Lakeshore Dr")
    }

    @Test func keepsWhicheverPartIsPresent() {
        #expect(AddressSearchResult.streetLine(number: nil, street: "Main St") == "Main St")
        #expect(AddressSearchResult.streetLine(number: "100", street: nil) == "100")
    }

    @Test func trimsAndDropsEmptyParts() {
        #expect(AddressSearchResult.streetLine(number: "  ", street: " Oak Ave ") == "Oak Ave")
        #expect(AddressSearchResult.streetLine(number: nil, street: nil) == "")
        #expect(AddressSearchResult.streetLine(number: "", street: "") == "")
    }
}
