//
//  NegativeEdgeTests.swift
//  GLSmallBusinessTests
//
//  Negative / failure paths to match the happy-path coverage: empty hex, a write failure,
//  whitespace-only validation, and whitespace-only customer names.
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

    /// Writing into a non-existent subdirectory fails, so tempURL returns nil.
    @Test func compliancePDFReturnsNilOnWriteFailure() {
        let badName = "gl-no-such-dir-\(UUID().uuidString)/Cert.pdf"
        #expect(CompliancePDF.tempURL(Data("x".utf8), name: badName, fallback: "fb.pdf") == nil)
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
