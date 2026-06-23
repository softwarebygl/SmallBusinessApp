//
//  TINFormatterTests.swift
//  GLSmallBusinessTests
//
//  Covers the taxpayer-ID field's digit-only + auto-format logic: letters/symbols are stripped, input
//  is capped at 9 digits, and dashes land in the SSN (XXX-XX-XXXX) and EIN (XX-XXXXXXX) positions.
//

import Testing
@testable import GLSmallBusiness

struct TINFormatterTests {

    @Test func formatsFullSSN() {
        #expect(TINFormatter.format("123456789", kind: .ssn) == "123-45-6789")
    }

    @Test func formatsFullEIN() {
        #expect(TINFormatter.format("987654321", kind: .ein) == "98-7654321")
    }

    @Test func nilKindFormatsAsSSN() {
        #expect(TINFormatter.format("123456789", kind: nil) == "123-45-6789")
    }

    @Test func stripsLettersAndSymbols() {
        // The whole point of the fix: non-digits never survive.
        #expect(TINFormatter.format("abc12!34", kind: .ssn) == "123-4")
        #expect(TINFormatter.format("12-34-56", kind: .ein) == "12-3456")
    }

    @Test func capsAtNineDigits() {
        #expect(TINFormatter.format("12345678901234", kind: .ssn) == "123-45-6789")
        #expect(TINFormatter.format("12345678901234", kind: .ein) == "12-3456789")
    }

    @Test func formatsPartialInputAsFarAsItGoes() {
        #expect(TINFormatter.format("1", kind: .ssn) == "1")
        #expect(TINFormatter.format("1234", kind: .ssn) == "123-4")
        #expect(TINFormatter.format("12345", kind: .ssn) == "123-45")
        #expect(TINFormatter.format("123456", kind: .ssn) == "123-45-6")
        #expect(TINFormatter.format("12", kind: .ein) == "12")
        #expect(TINFormatter.format("123", kind: .ein) == "12-3")
    }

    @Test func reformattingIsIdempotent() {
        // Re-running on already-formatted text (the .onChange path) must be stable.
        #expect(TINFormatter.format("123-45-6789", kind: .ssn) == "123-45-6789")
        #expect(TINFormatter.format("98-7654321", kind: .ein) == "98-7654321")
    }

    @Test func emptyStaysEmpty() {
        #expect(TINFormatter.format("", kind: .ssn) == "")
        #expect(TINFormatter.format("---", kind: .ssn) == "")
    }
}
