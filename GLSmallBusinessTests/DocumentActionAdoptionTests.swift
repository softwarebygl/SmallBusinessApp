//
//  DocumentActionAdoptionTests.swift
//  GLSmallBusinessTests
//
//  Zero Duplication (audit 2026-10-03 F95): the Estimate, Invoice and Change Order detail screens
//  draw their quick-action cards (Email, Text, Share, Retry) and the pinned "Preview PDF" footer
//  with GoldLifeUI's `GLDocumentActionLabel` / `GLDocumentActionButton` / `GLStickyPreviewFooter`,
//  never a hand-built copy, so a fix to the component reaches every document screen.
//
//  Read off the code with comments stripped (the F11 rule): a comment naming the old pattern is
//  not code.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct DocumentActionAdoptionTests {

    private static let screens = [
        "Screens/EstimateDetailScreen.swift",
        "Screens/InvoiceDetailScreen.swift",
        "Screens/ChangeOrderScreens.swift",
    ]

    /// The hand-built action card: an icon at `.title2` over a caption, on a 12 pt rounded card.
    private static var handBuiltCard: Regex<Substring> {
        #/VStack\(spacing: 4\)\s*\{\s*Image\(systemName: "[^"]+"\)\s*\.font\(\.title2\)\s*Text\("[^"]+"\)\s*\.font\(\.caption\.weight\(\.medium\)\)/#
    }

    /// The hand-built footer: the Preview PDF label inside its own capsule.
    private static var handBuiltFooter: Regex<Substring> {
        #/Label\("Preview PDF", systemImage: "eye"\)\s*\.font\(\.headline\)/#
    }

    @Test func documentScreensDrawNoHandBuiltActionCards() throws {
        for file in Self.screens {
            let code = try #require(GLSource.code(file), "\(file) is missing")
            let cards = code.matches(of: Self.handBuiltCard).count
            let footers = code.matches(of: Self.handBuiltFooter).count
            #expect(cards == 0,
                    "\(file) hand-builds an action card; use GLDocumentActionButton / GLDocumentActionLabel.")
            #expect(footers == 0,
                    "\(file) hand-builds the Preview PDF footer; use GLStickyPreviewFooter.")
        }
    }

    @Test func documentScreensUseThePackageComponents() throws {
        for file in Self.screens {
            let code = try #require(GLSource.code(file), "\(file) is missing")
            let button = code.contains("GLDocumentActionButton(")
            let label = code.contains("GLDocumentActionLabel(")
            let footer = code.contains("GLStickyPreviewFooter")
            #expect(button, "\(file) doesn't use GLDocumentActionButton.")
            #expect(label, "\(file)'s Share card doesn't use GLDocumentActionLabel.")
            #expect(footer, "\(file) doesn't use GLStickyPreviewFooter.")
        }
    }
}
