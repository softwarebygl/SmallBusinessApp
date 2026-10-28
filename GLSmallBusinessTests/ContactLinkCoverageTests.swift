//
//  ContactLinkCoverageTests.swift
//  GLSmallBusinessTests
//
//  REQUIREMENTS law 84 / PARITY "Contact links": every address, phone number and email shown as
//  text is a `GLContactLink`, and no app keeps its own `mailto:` / `tel:` / maps link code.
//  Audit 2026-10-03 F45: the Estimate and Invoice detail screens showed the customer's email,
//  phone and service address as plain `Text` (tapping them did nothing), and the Menu's
//  "Message the Developer" row built its own `mailto:` URL instead of the shared mail route.
//
//  These are facts about call sites, so they are read off the code (comments stripped, the
//  F11 rule), the instrument `GLSource` exists for.
//

import Testing
import Foundation
import GoldLifeUI
@testable import GLSmallBusiness

@MainActor
struct ContactLinkCoverageTests {

    /// The detail screens and the record each one shows contacts for.
    private static let detailScreens: [(file: String, record: String)] = [
        ("Screens/EstimateDetailScreen.swift", "estimate"),
        ("Screens/InvoiceDetailScreen.swift", "invoice"),
    ]

    @Test func estimateAndInvoiceDetailsShowNoPlainContactText() throws {
        for screen in Self.detailScreens {
            let code = try #require(GLSource.code(screen.file), "\(screen.file) is missing")
            for field in ["customerEmail", "customerPhone", "serviceAddress.formattedMultiline",
                          "serviceAddress.singleLine"] {
                let plain = "Text(\(screen.record).\(field))"
                let showsPlain = code.contains(plain)
                #expect(!showsPlain,
                        "\(screen.file) shows \(screen.record).\(field) as plain Text; law 84 makes it a GLContactLink.")
            }
        }
    }

    @Test func estimateAndInvoiceDetailsUseContactLinksForAllThree() throws {
        for screen in Self.detailScreens {
            let code = try #require(GLSource.code(screen.file), "\(screen.file) is missing")
            for kind in ["email", "phone", "address"] {
                let usesLink = code.contains("GLContactLink(.\(kind)")
                #expect(usesLink,
                        "\(screen.file) has no GLContactLink(.\(kind), …) for the customer's \(kind).")
            }
        }
    }

    /// The developer row goes through the shared mail route (the person's chosen mail app), never a
    /// hand-built `mailto:` link.
    @Test func menuKeepsNoMailtoLinkOfItsOwn() throws {
        let code = try #require(GLSource.code("Screens/MenuScreen.swift"))
        let buildsMailto = code.contains("\"mailto:")
        let usesSharedRoute = code.contains("GLContactRoute.destination")
        #expect(!buildsMailto, "MenuScreen builds its own mailto: link (PARITY: no app keeps its own).")
        #expect(usesSharedRoute,
                "MenuScreen should route the developer email through GLContactRoute.")
    }

    // MARK: - The developer email's route

    @Test func developerMailOpensAppleMailByDefault() throws {
        let destination = try #require(MenuScreen.developerMailDestination(mail: .appleMail) { _ in true })
        #expect(destination.primary.scheme == "mailto")
        #expect(destination.primary.absoluteString.contains("support@softwarebygl.com"))
        #expect(destination.fallback == nil)
    }

    @Test func developerMailOpensGmailWhenChosenAndInstalled() throws {
        let destination = try #require(MenuScreen.developerMailDestination(mail: .gmail) { _ in true })
        #expect(destination.primary.scheme == "googlegmail")
        #expect(destination.fallback?.scheme == "mailto", "Apple Mail is the fallback if Gmail can't open.")
    }

    @Test func developerMailFallsBackToAppleMailWhenGmailIsMissing() throws {
        let destination = try #require(MenuScreen.developerMailDestination(mail: .gmail) { _ in false })
        #expect(destination.primary.scheme == "mailto", "A chosen app that isn't installed: Apple's app, never a dead tap.")
    }
}
