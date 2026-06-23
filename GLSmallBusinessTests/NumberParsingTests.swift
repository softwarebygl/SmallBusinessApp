//
//  NumberParsingTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct NumberParsingTests {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")   // grouping ".", decimal ","

    @Test func parsesPlainAndGroupedUSNumbers() {
        #expect(NumberParsing.double(from: "12", locale: us) == 12)
        #expect(NumberParsing.double(from: "1,234.56", locale: us) == 1234.56)
        #expect(NumberParsing.double(from: "  5.5 ", locale: us) == 5.5)
    }

    @Test func stripsCurrencySymbols() {
        #expect(NumberParsing.double(from: "$1,000.00", locale: us) == 1000)
    }

    @Test func handlesCommaDecimalLocales() {
        // In German, "1,5" means 1.5 and "." is the grouping separator.
        #expect(NumberParsing.double(from: "1,5", locale: de) == 1.5)
        #expect(NumberParsing.double(from: "1.234,56", locale: de) == 1234.56)
    }

    @Test func emptyOrGarbageReturnsNil() {
        #expect(NumberParsing.double(from: "", locale: us) == nil)
        #expect(NumberParsing.double(from: "abc", locale: us) == nil)
        #expect(NumberParsing.double(from: "   ", locale: us) == nil)
    }

    @Test func rejectsNonFiniteOverflow() {
        // An absurdly long digit string overflows Double to infinity — a money/quantity field must
        // never hold that, so parsing returns nil instead of ∞.
        let huge = String(repeating: "9", count: 400)
        #expect(NumberParsing.double(from: huge, locale: us) == nil)
    }
}
