//
//  DeviceWordingTests.swift
//  GLSmallBusinessTests
//
//  QA audit F111: My Business runs on iPad too, so a Settings explanation or help topic says "this
//  device", never "this iPhone" (the wrong device on an iPad).
//

import Testing
import Foundation

struct DeviceWordingTests {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness")

    private static func strings(in relative: String, pattern: String) throws -> [String] {
        let source = try String(contentsOf: app.appendingPathComponent(relative), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    @Test func noSettingsExplanationOrHelpTopicSaysIPhone() throws {
        let infoLabels = try Self.strings(in: "Screens/SettingsScreen.swift", pattern: #"info: "((?:[^"\\]|\\.)*)""#)
        #expect(infoLabels.count >= 4, "the sweep found no Settings explanations: the pattern drifted")
        let help = try Self.strings(in: "AI/MBHelpTool.swift", pattern: #"text: "((?:[^"\\]|\\.)*)""#)
        #expect(help.count >= 4)
        for text in infoLabels + help {
            #expect(!text.contains("iPhone"), "says iPhone: \(text.prefix(60))…")
        }
    }

    @Test func theSyncMessagesAndWhatsNewSayDevice() throws {
        for (file, needle) in [("Sync/GLSyncStatus.swift", "Nothing on this device has changed yet."),
                               ("Sync/GLSyncEngine.swift", "so this device stopped instead"),
                               ("Screens/WhatsNewScreen.swift", "Sign out, and this device is clear")] {
            let source = try String(contentsOf: Self.app.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(needle), "\(file) should say: \(needle)")
        }
    }
}
