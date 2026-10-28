//
//  InsuranceCardLabelTests.swift
//  GLSmallBusinessTests
//
//  My Insurance & License rows (ComplianceDocsManagerSheet.cardLabel). A file name stays on one
//  line, cut in the middle so its extension shows; a sentence (the reference COI's "Your own
//  reference copy - never sent. ...") wraps instead of being cut mid-word (lead finding L10).
//

import Testing
import SwiftUI
import UIKit
@testable import GLSmallBusiness

@MainActor
struct InsuranceCardLabelTests {

    private let sentence = "Your own reference copy \u{2014} never sent. Customer certificates live on each customer."

    private func height(_ view: some View, width: CGFloat = 343) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// The sentence subtitle gets more height than a one-line row, so nothing is cut off.
    @Test func referenceCOISentenceWrapsInsteadOfTruncating() {
        let oneLine = height(ComplianceDocsManagerSheet.cardLabel(
            title: "Blank COI (your reference copy)", systemImage: "doc.text",
            subtitle: "Tap to upload", uploaded: false))
        let sentenceRow = height(ComplianceDocsManagerSheet.cardLabel(
            title: "Blank COI (your reference copy)", systemImage: "doc.text",
            subtitle: sentence, uploaded: false, wraps: true))
        #expect(sentenceRow > oneLine + 8)
    }

    /// A file name never wraps: a long one stays one line, the same height as a short one.
    @Test func fileNameStaysOneLine() {
        let short = height(ComplianceDocsManagerSheet.cardLabel(
            title: "Contractor License", systemImage: "person.text.rectangle",
            subtitle: "license.pdf", uploaded: true))
        let long = height(ComplianceDocsManagerSheet.cardLabel(
            title: "Contractor License", systemImage: "person.text.rectangle",
            subtitle: "Florida-Certified-Contractor-License-Renewal-2026-final-signed-copy.pdf",
            uploaded: true))
        #expect(abs(long - short) < 1)
    }
}
