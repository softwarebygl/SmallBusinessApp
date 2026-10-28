//
//  AssistantInfoWordingTests.swift
//  GLSmallBusinessTests
//
//  Settings › Sentinel's info, and Sentinel's own help answer about it, say where the data
//  goes in the owner-approved words of the consent sheet (2026-09-27): Sentinel sends what you type
//  and the records needed to answer when using a connected cloud AI.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct AssistantInfoWordingTests {

    private static let english = "Sentinel sends what you type and the records needed to answer when using a connected cloud AI. Turn this off and Sentinel will ask again before sending."
    private static let spanish = "Sentinel env\u{ED}a lo que escribes y los registros necesarios para responder al usar una IA en la nube conectada. Desactiva esto y Sentinel volver\u{E1} a preguntar antes de enviar."

    private func assistantTopic() throws -> MBHelpCatalog.Topic {
        try #require(MBHelpCatalog.topics.first { MBHelpTool.english($0.topic) == "Sentinel" })
    }

    /// The help answer reads the approved sentence in English and in Spanish.
    @Test func theAssistantHelpTopicUsesTheApprovedWordsInBothLanguages() throws {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        let topic = try assistantTopic()
        #expect(MBHelpTool.english(topic.text) == Self.english)

        MBLocalization.shared.language = .en
        #expect(mbLoc(topic.text) == Self.english)

        MBLocalization.shared.language = .es
        #expect(mbLoc(topic.text) == Self.spanish)
    }

    /// Settings shows the same catalog key the help answer reads, so the two can't drift; the old
    /// "Gemini API" wording is gone from the screens, the help and the catalog.
    @Test func settingsShowsTheSameWordsAndTheOldOnesAreGone() throws {
        let settings = try #require(GLSource.file("Screens/SettingsScreen.swift"))
        #expect(settings.contains("InfoLabel(\"Sentinel\", info: \"\(Self.english)\", topic: \"Sentinel\")"))
        for file in GLSource.files() {
            #expect(!file.text.contains("Gemini API"), "\(file.path) still says \"Gemini API\"")
        }
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[Self.english] as? [String: Any])
        let es = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(es?["value"] as? String == Self.spanish)
        #expect(es?["state"] as? String == "translated")
        #expect(!strings.keys.contains { $0.contains("Gemini API") }, "the old wording is still in the catalog")
    }
}
