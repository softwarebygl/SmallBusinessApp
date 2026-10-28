//
//  GoldLifeIDDeletionWarningTests.swift
//  GLSmallBusinessTests
//
//  Owner ruling 2026-09-26 (law 73): "The UI must explicitly warn the user they will lose their GL
//  ID and ALL data across ALL GL apps. The user must be shown their GL ID and be forced to type it
//  to confirm deletion." The warning is GoldLifeUI's, once; the GoldLifeID package's deletion
//  screen only ADDS its sign-in note (law 48a: My Business shows the package's screen and declares
//  none of its own).
//
//  BEHAVIOR, not source text (audit 2026-10-03 F11). These tests used to grep GoldLifeIDViews.swift,
//  and after build 88 the only matches were COMMENT lines kept there for the tests, so the suite
//  stayed green while deleting a Gold Life ID was impossible from My Business (F1). Now they read
//  the words the shipped screen actually shows, the type the app actually pushes, and whether the
//  app actually handed the package its eraser.
//

import Foundation
import SwiftUI
import GoldLifeUI
import GoldLifeID
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct GoldLifeIDDeletionWarningTests {

    private let id = "4821-9037"

    // MARK: - The screen My Business shows is the package's

    /// Law 48a: the Menu's Gold Life ID door pushes the package's `GoldLifeIDScreen`, whose
    /// deletion door is the package's `GoldLifeIDDeletionScreen`. A type of the same name declared
    /// in this app would shadow it (the trap My Business already fell into once); the name has to
    /// resolve to the package's type.
    @Test func theDeletionScreenIsThePackagesOwn() {
        #expect(String(reflecting: GoldLifeIDDeletionScreen.self) == "GoldLifeID.GoldLifeIDDeletionScreen")
        #expect(String(reflecting: GoldLifeIDScreen<EmptyView>.self).hasPrefix("GoldLifeID.GoldLifeIDScreen"))
    }

    /// F1: My Business hands the package its own eraser at launch, so its own row on that screen
    /// gets a live Delete instead of "open that app and delete it there" (the app it is already in).
    @Test func myBusinessHandsThePackageItsEraser() {
        #expect(GoldLifeID.shared.canEraseHostAppData,
                "GLSmallBusinessApp must configure GoldLifeIDConfig.eraseHostAppData, or no My Business user with data can delete their Gold Life ID")
    }

    @Test func deletionInventoryListsMyBusinessAndSentinel() async throws {
        let saved = GoldLifeID.shared.debugDeletionStub
        defer { GoldLifeID.shared.debugDeletionStub = saved }
        GoldLifeID.shared.debugDeletionStub = .init(goldLifeID: id, rows: [
            .init(appID: MBHostDataErase.appID, name: "My Business", holdsData: true),
            .init(appID: "my_ai", name: "Sentinel", holdsData: false),
        ])
        let links = try await GoldLifeID.shared.appInventory(includeData: true)
        #expect(links.map(\.appID) == ["my-business", "my_ai"])
        #expect(links.map(\.name) == ["My Business", "Sentinel"])
    }

    // MARK: - The words, in both languages

    @Test func theWarningSaysEverythingInEveryAppGoesAndPrintsTheID() {
        let english = Locale(identifier: "en")
        let note = GoldLifeIDDeletionScreen.identityDeletionNote(locale: english)
        let message = GLAccountDeletionSections.identityDeletionMessage(goldLifeID: id, note: note, locale: english)
        #expect(message.hasPrefix("Deleting your Gold Life ID can\u{2019}t be undone."))
        #expect(message.contains("You\u{2019}ll lose your Gold Life ID and all of your data across all Gold Life apps."))
        #expect(message.contains("To confirm, type your Gold Life ID: 4821-9037"))
        // The note the shipped screen adds, exactly once.
        #expect(note == "Your Gold Life ID sign-in record will be removed from our servers, and any app signed into this Gold Life ID will sign out.")
        #expect(message.components(separatedBy: note).count == 2)
        // The old copy told the person their data on this iPhone "stays put" — the deletion wipes it.
        #expect(!message.contains("stays put"))
    }

    @Test func theWarningReadsInSpanishFromThisAppsCatalog() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        let spanish = Locale(identifier: "es")
        let note = GoldLifeIDDeletionScreen.identityDeletionNote(locale: spanish)
        let message = GLAccountDeletionSections.identityDeletionMessage(goldLifeID: id, note: note, locale: spanish)
        #expect(message.hasPrefix("Eliminar tu Gold Life ID no se puede deshacer."))
        #expect(message.contains("Perderás tu Gold Life ID y todos tus datos en todas las apps de Gold Life."))
        #expect(message.contains("Para confirmar, escribe tu Gold Life ID: 4821-9037"))
        #expect(note == "Tu registro de inicio de sesión de Gold Life ID se eliminará de nuestros servidores y se cerrará la sesión en cualquier app conectada a este Gold Life ID.")
    }

    /// Every sentence the deletion screen can put on screen has its Spanish in THIS app's catalog
    /// (the package resolves against `Bundle.main`), placeholders intact. The "held elsewhere" row
    /// sentence was missing until 2026-10-03 (F1), so Spanish users read it in English.
    @Test func everyDeletionScreenStringIsTranslated() throws {
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "Deleting your Gold Life ID can\u{2019}t be undone. You\u{2019}ll lose your Gold Life ID and all of your data across all Gold Life apps.",
            "To confirm, type your Gold Life ID: %@\n\nDelete turns on once what you type matches.",
            "Your Gold Life ID sign-in record will be removed from our servers, and any app signed into this Gold Life ID will sign out.",
            "This app holds your data.",
            "Still has your data \u{2014} open that app and delete it there.",
            "Couldn\u{2019}t check this app. Open it and try again.",
            "Every record %@ holds for you will be erased.",
            "Couldn\u{2019}t delete that app\u{2019}s data",
            "The delete didn\u{2019}t finish \u{2014} %@ still has your data. Check your connection and try again.",
        ]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing key: \(key)")
            let es = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = try #require(es?["value"] as? String, "no Spanish for: \(key)")
            #expect(!value.isEmpty && value != key)
            #expect(value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count,
                    "placeholders differ for: \(key)")
        }
    }

    /// The two row sentences resolve to Spanish at run time, through the same `Bundle.main` lookup
    /// the package's screen uses.
    @Test func theRowSentencesReadInSpanish() {
        func es(_ key: String.LocalizationValue) -> String {
            var resource = LocalizedStringResource(key, bundle: .main)
            resource.locale = Locale(identifier: "es")
            return String(localized: resource)
        }
        #expect(es("This app holds your data.") == "Esta app tiene tus datos guardados.")
        #expect(es("Still has your data \u{2014} open that app and delete it there.")
                != "Still has your data \u{2014} open that app and delete it there.")
    }
}
