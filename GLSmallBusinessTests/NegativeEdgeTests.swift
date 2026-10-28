//
//  NegativeEdgeTests.swift
//  GLSmallBusinessTests
//
//  Negative / failure paths to match the happy-path coverage: empty hex,
//  whitespace-only validation, and whitespace-only customer names.
//  (The temp-file write failure lives with the rest of `CompliancePDF.tempURL`
//  in DocumentSharingCoverageTests.)
//

import Testing
import SwiftUI
import UIKit
@testable import GLSmallBusiness

@MainActor
struct NegativeEdgeTests {
    /// Empty hex string scans to nothing → black.
    @Test func emptyHexIsBlack() {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 0
        UIColor(Color(hex: "")).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(close(Double(r), 0))
        #expect(close(Double(g), 0))
        #expect(close(Double(b), 0))
    }

    /// Required fields that are only whitespace don't satisfy `isComplete`.
    @Test func isCompleteRejectsWhitespaceOnly() {
        let p = BusinessProfile()
        p.businessName = "   "
        p.phone = "  "
        p.email = " "
        #expect(!p.isComplete)
    }

    /// Whitespace-only names fall through to the nameless defaults.
    @Test func customerWhitespaceNamesFallThrough() {
        let c = Customer(firstName: "  ", lastName: " ")
        #expect(c.fullName == "")
        #expect(c.listDisplayName == "No name")
        #expect(c.initials == "?")
    }
}
