//
//  PhoneFormatterTests.swift
//  GLSmallBusinessTests
//
//  Live phone auto-dashing (#5). Mirrors TINFormatterTests: strip non-digits, format as typed, stay
//  idempotent, and never lose a digit the user entered.
//

import Testing
@testable import GLSmallBusiness

struct PhoneFormatterTests {

    @Test func emptyAndNonDigitsStayEmpty() {
        #expect(PhoneFormatter.format("") == "")
        #expect(PhoneFormatter.format("---") == "")
        #expect(PhoneFormatter.format("() -") == "")
        #expect(PhoneFormatter.format("abc") == "")
    }

    @Test func formatsProgressivelyAsTyped() {
        #expect(PhoneFormatter.format("5") == "5")
        #expect(PhoneFormatter.format("55") == "55")
        #expect(PhoneFormatter.format("555") == "555")
        #expect(PhoneFormatter.format("5551") == "555-1")
        #expect(PhoneFormatter.format("555123") == "555-123")
        #expect(PhoneFormatter.format("5551234") == "555-123-4")
        #expect(PhoneFormatter.format("555123456") == "555-123-456")
        #expect(PhoneFormatter.format("5551234567") == "555-123-4567")
    }

    @Test func stripsAnythingThatIsNotADigit() {
        #expect(PhoneFormatter.format("(555) 123-4567") == "555-123-4567")
        #expect(PhoneFormatter.format("555.123.4567") == "555-123-4567")
        #expect(PhoneFormatter.format("call 5551234567 now") == "555-123-4567")
    }

    @Test func usCountryCodeElevenDigits() {
        #expect(PhoneFormatter.format("15551234567") == "1-555-123-4567")
        #expect(PhoneFormatter.format("+1 (555) 123-4567") == "1-555-123-4567")
    }

    @Test func elevenDigitsNotStartingWithOneKeepsEveryDigit() {
        // Not a US country code → format the first 10, append the rest; nothing is dropped.
        let out = PhoneFormatter.format("25551234567")
        #expect(out.filter(\.isNumber) == "25551234567")
        #expect(out.hasPrefix("255-512-3456"))
    }

    @Test func extraDigitsBeyondTenArePreserved() {
        let out = PhoneFormatter.format("55512345678999")   // 14 digits
        #expect(out.filter(\.isNumber) == "55512345678999")  // every digit survives
        #expect(out.hasPrefix("555-123-4567"))
    }

    @Test func reformattingIsIdempotent() {
        // The live .onChange path re-runs format() on already-formatted text every keystroke.
        #expect(PhoneFormatter.format("555-123-4567") == "555-123-4567")
        #expect(PhoneFormatter.format("1-555-123-4567") == "1-555-123-4567")
        #expect(PhoneFormatter.format("555-12") == "555-12")
        #expect(PhoneFormatter.format("555-123-456") == "555-123-456")
    }
}
