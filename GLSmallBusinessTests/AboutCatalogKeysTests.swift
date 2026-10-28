//
//  AboutCatalogKeysTests.swift
//
//  Audit 2026-10-03 F72 (laws 1, 2, 53): GoldLifeUI's About screen reads its own words (legal
//  rows, version line, apps header, the no-email alert) and every fleet card's tagline and
//  category from THIS app's catalog, in the in-app language. A key missing here stays English
//  in Español, so every one must be in the catalog with its Spanish. The cards come from
//  GLAppCatalog itself, so a new tagline or category fails here until its key is added.
//

import Testing
import Foundation
import GoldLifeUI
@testable import GLSmallBusiness

@MainActor
struct AboutCatalogKeysTests {

    private static func strings() throws -> [String: [String: Any]] {
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    private static func spanish(_ key: String, in strings: [String: [String: Any]]) -> String? {
        let es = (strings[key]?["localizations"] as? [String: Any])?["es"] as? [String: Any]
        return (es?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    /// The About screen's own keys (GoldLifeUI GLAboutScreen), with the Spanish each must read.
    private static let aboutScreenKeys: [String: String] = [
        "Privacy Policy": "Política de privacidad",
        "Terms of Use": "Términos de uso",
        "Contact Support": "Contactar a soporte",
        "Version %@ (%@)": "Versión %@ (%@)",
        "Legal & Support": "Legal y soporte",
        "No email app set up": "No hay una app de correo configurada",
        "Email us any time at %@.": "Escríbenos cuando quieras a %@.",
        kGLAdditionalAppsTitle: "Más apps creadas por Gold Life LLC",
        "Made by Gold Life LLC": "Hecho por Gold Life LLC",
    ]

    @Test func aboutScreenWordsReadInSpanish() throws {
        let strings = try Self.strings()
        for (key, expected) in Self.aboutScreenKeys {
            #expect(Self.spanish(key, in: strings) == expected, "\(key)")
        }
    }

    @Test func everyFleetCardReadsInSpanish() throws {
        let strings = try Self.strings()
        for app in GLAppCatalog.all {
            for key in [app.tagline, app.category] {
                let es = Self.spanish(key, in: strings)
                #expect(es != nil && es != key, "\(app.name): \"\(key)\" has no Spanish")
            }
        }
    }
}
