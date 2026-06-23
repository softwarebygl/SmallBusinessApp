//
//  CSVTests.swift
//  GLSmallBusinessTests
//
//  The shared CSV field escaping used by every accountant export. Covers the formula-injection
//  guard (a customer/sub/vendor name a user typed starting with = + - @ must NOT execute in Excel)
//  and RFC-4180 quoting.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct CSVTests {

    // MARK: - Formula-injection guard

    @Test func neutralizesFormulaPrefixes() {
        #expect(CSV.field("=cmd()") == "'=cmd()")
        #expect(CSV.field("+1+2") == "'+1+2")
        #expect(CSV.field("-5") == "'-5")
        #expect(CSV.field("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSV.field("\tlead") == "'\tlead")
    }

    @Test func leavesSafeLeadingCharsAlone() {
        #expect(CSV.field("Acme Tile") == "Acme Tile")
        #expect(CSV.field("123 Main St") == "123 Main St")
        #expect(CSV.field("") == "")
    }

    // MARK: - RFC-4180 quoting

    @Test func quotesFieldsWithCommas() {
        #expect(CSV.field("Reed, Marcus") == "\"Reed, Marcus\"")
    }

    @Test func quotesAndDoublesEmbeddedQuotes() {
        #expect(CSV.field("3\" pipe") == "\"3\"\" pipe\"")
    }

    @Test func quotesFieldsWithNewlines() {
        #expect(CSV.field("line1\nline2") == "\"line1\nline2\"")
    }

    // MARK: - Injection + quoting combined

    @Test func injectionPrefixAndQuotingCombine() {
        // A malicious value that also contains a comma: neutralize first, then quote the whole thing.
        #expect(CSV.field("=2,3") == "\"'=2,3\"")
    }
}
