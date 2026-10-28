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

    @Test func rejectsNegativeHexAndScientific() {
        // Paste (and third-party keyboards) bypass the decimal pad, so Double(_:)'s permissive
        // syntax must not leak through — money/quantity fields only take plain non-negative decimals.
        #expect(NumberParsing.double(from: "-5", locale: us) == nil)
        #expect(NumberParsing.double(from: "-1.5", locale: us) == nil)
        #expect(NumberParsing.double(from: "+5", locale: us) == nil)
        #expect(NumberParsing.double(from: "0x10", locale: us) == nil)
        #expect(NumberParsing.double(from: "1e9", locale: us) == nil)
        #expect(NumberParsing.double(from: "1E9", locale: us) == nil)
        #expect(NumberParsing.double(from: "inf", locale: us) == nil)
        #expect(NumberParsing.double(from: "infinity", locale: us) == nil)
        #expect(NumberParsing.double(from: "nan", locale: us) == nil)
        #expect(NumberParsing.double(from: "-5", locale: de) == nil)
        #expect(NumberParsing.double(from: "1e9", locale: de) == nil)
        // Multiple decimal points are garbage, not a number.
        #expect(NumberParsing.double(from: "1.2.3", locale: us) == nil)
    }

    @Test func rejectsNonFiniteOverflow() {
        // An absurdly long digit string overflows Double to infinity — a money/quantity field must
        // never hold that, so parsing returns nil instead of ∞.
        let huge = String(repeating: "9", count: 400)
        #expect(NumberParsing.double(from: huge, locale: us) == nil)
    }

    // MARK: - capped: the percentage ceiling (owner ruling, 2026-08-23)

    @Test func cappedHoldsAValueToItsCeiling() {
        // The whole point: 150 typed into a percentage discount becomes 100, at the keyboard,
        // where the person can still see it happen.
        #expect(NumberParsing.capped(150, max: 100) == 100)
        #expect(NumberParsing.capped(100.01, max: 100) == 100)
        #expect(NumberParsing.capped(1000, max: 100) == 100)
    }

    @Test func cappedLeavesAnythingUnderTheCeilingAlone() {
        // A cap that moves a legitimate entry would be worse than no cap at all.
        #expect(NumberParsing.capped(15, max: 100) == 15)
        #expect(NumberParsing.capped(99.9, max: 100) == 99.9)
        #expect(NumberParsing.capped(100, max: 100) == 100)
        #expect(NumberParsing.capped(0, max: 100) == 0)
    }

    @Test func noCeilingMeansNoChange() {
        // Fixed-amount discounts pass nil: they are dollars, and $150 off is an ordinary figure.
        #expect(NumberParsing.capped(150, max: nil) == 150)
        #expect(NumberParsing.capped(0, max: nil) == 0)
    }

    @Test func cappedOnlyEverLowersAValue() {
        // It must not be able to invent money by raising a small entry to the ceiling.
        for value in [0.0, 0.5, 7, 42.25, 99.999, 100, 100.001, 250, 1_000_000] {
            #expect(NumberParsing.capped(value, max: 100) <= value)
        }
    }

    @Test func noEntryAtOrBelowOneHundredHasAPrefixAboveIt() {
        // Why per-keystroke capping is safe to do at 100 and cannot eat a digit mid-typing:
        // appending digits only grows the integer part, so no number a person legitimately wants
        // (<= 100) passes through a capped prefix on the way in.
        for text in ["1", "10", "100", "7", "12.5", "99.99", "0.5"] {
            var prefix = ""
            for ch in text {
                prefix.append(ch)
                guard let parsed = NumberParsing.double(from: prefix, locale: us) else { continue }
                #expect(NumberParsing.capped(parsed, max: 100) == parsed,
                        "typing \"\(text)\" would have been interrupted at \"\(prefix)\"")
            }
        }
    }

    // MARK: - Zero Duplication: components from GoldLifeDocuments

    /// Audit 2026-10-03 C28 (F27): AutoClearNumberField and LineItemNameSuggestions are
    /// provided by GoldLifeDocuments; My Business declares no struct AutoClearNumberField
    /// or enum LineItemNameSuggestions of its own.
    @Test func noMovedNumberOrSuggestionComponentsDeclaredInApp() {
        let retiredDeclarations = [
            "struct AutoClearNumberField", "enum LineItemNameSuggestions"
        ]
        var found: [String] = []
        for file in GLSource.codeFiles() {
            for declaration in retiredDeclarations {
                let name = declaration.split(separator: " ").last.map(String.init) ?? declaration
                let kind = declaration.split(separator: " ").first.map(String.init) ?? ""
                let pattern = "\\b\(kind)\\s+\(name)\\b"
                if file.text.range(of: pattern, options: .regularExpression) != nil {
                    found.append("\(file.path): \(declaration)")
                }
            }
        }
        #expect(found.isEmpty, "My Business still declares duplicate number/suggestion types: \(found)")
    }
}
