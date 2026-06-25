//
//  AddressSearchTests.swift
//  GLSmallBusinessTests
//
//  Covers the pure piece of the address-typeahead feature: parsing a MapKit `fullAddress` string
//  (iOS 26 retired MKPlacemark's structured fields) into street / city / state / ZIP form values.
//

import Testing
@testable import GLSmallBusiness

struct AddressSearchTests {

    @Test func parsesAFullUSAddress() {
        let r = AddressSearchResult.parse(fullAddress: "123 Main St, Springfield, FL 32308, United States")
        #expect(r.street == "123 Main St")
        #expect(r.city == "Springfield")
        #expect(r.state == "FL")
        #expect(r.postalCode == "32308")
    }

    @Test func keepsAMultiPartStreet() {
        let r = AddressSearchResult.parse(fullAddress: "123 Main St, Apt 4, Tallahassee, FL 32301, United States")
        #expect(r.street == "123 Main St, Apt 4")
        #expect(r.city == "Tallahassee")
        #expect(r.state == "FL")
        #expect(r.postalCode == "32301")
    }

    @Test func handlesNoCountryAndZipPlusFour() {
        let r = AddressSearchResult.parse(fullAddress: "2491 Dundee Dr, Tallahassee, FL 32308-3927")
        #expect(r.street == "2491 Dundee Dr")
        #expect(r.city == "Tallahassee")
        #expect(r.state == "FL")
        #expect(r.postalCode == "32308-3927")
    }

    @Test func handlesAMissingZip() {
        let r = AddressSearchResult.parse(fullAddress: "500 Oak Ave, Austin, TX, United States")
        #expect(r.street == "500 Oak Ave")
        #expect(r.city == "Austin")
        #expect(r.state == "TX")
        #expect(r.postalCode == "")
    }

    @Test func anEmptyStringYieldsBlanks() {
        let r = AddressSearchResult.parse(fullAddress: "")
        #expect(r.street == "")
        #expect(r.city == "")
        #expect(r.state == "")
        #expect(r.postalCode == "")
    }
}
