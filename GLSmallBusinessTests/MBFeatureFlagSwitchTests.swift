//
//  MBFeatureFlagSwitchTests.swift
//  GLSmallBusinessTests
//
//  Owner ask 2026-10-03 (D1/D2): ONE compile-time switch (`MBFeatureFlags.assistantEnabled`)
//  hides the assistant everywhere while it is off. These tests are the fence: delete any guard
//  and one of them goes red. QA audit F97/F100.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct MBFeatureFlagSwitchTests {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness")

    /// A source file with its comments removed, so a guard that survives only in a comment
    /// does not count.
    private static func code(_ relative: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// The assistant is enabled in this build (100% free via BYOK).
    @Test func theAssistantSwitchIsOnInThisBuild() {
        #expect(MBFeatureFlags.assistantEnabled == true)
    }

    @Test func recordsCanBeNamedToTheAssistantWhileItIsOn() {
        #expect(MBFeatureFlags.assistantEnabled == true)
        let source = try? Self.code("Screens/AssistantScreen.swift")
        #expect(source?.contains("var canBeNamedToAssistant: Bool { MBFeatureFlags.assistantEnabled") == true,
                "canBeNamedToAssistant must be gated by the switch")
    }

    @Test func theTabAndTheSidebarSectionAreGuardedBySwitch() throws {
        #expect(try Self.code("Screens/RootTabView.swift").contains("if MBFeatureFlags.assistantEnabled"))
        #expect(try Self.code("Screens/IPadRootSplitView.swift").contains("$0 != .assistant || MBFeatureFlags.assistantEnabled"))
    }

    @Test func settingsShowsTheAssistantSectionWhileItIsOn() throws {
        let settings = try Self.code("Screens/SettingsScreen.swift")
        #expect(settings.contains("if MBFeatureFlags.assistantEnabled && assistantSharingOn"),
                "stored consent must not bring the Assistant section back while the switch is off")
        // Stored consent stays, and sign-out still clears it: the reset path is untouched.
        #expect(settings.contains("MBAssistantSession.shared.consent.reset()"))
    }

    @Test func noCapOrUpgradePaywallSellsProPlusAI() throws {
        let sold = Set(PaywallSheet.productIDs(for: .atCap)).union(PaywallSheet.productIDs(for: .upgrade))
        #expect(sold.isDisjoint(with: SubscriptionManager.aiProductIDs),
                "Pro + AI products must not be offered on the cap or upgrade paywalls (AI Assistant is 100% free via BYOK)")
        #expect(try Self.code("AccessControl/PaywallSheet.swift")
            .contains("!SubscriptionManager.aiProductIDs.contains"))
    }

    @Test func whatsNewHasNoAssistantItemButTheComingSoonRow() {
        let off = MBWhatsNew.items(assistantEnabled: false)
        let titles = off.map { String(localized: $0.title) }
        #expect(titles.contains("Coming soon: the assistant (Beta)"))
        for gone in ["See your AI use", "Tax IDs stay out of AI", "Remove a logo or photo by asking", "Exact prices and rates"] {
            #expect(!titles.contains(gone), "\(gone) must not show while the assistant is off")
        }
        let on = MBWhatsNew.items(assistantEnabled: true).map { String(localized: $0.title) }
        #expect(!on.contains("Coming soon: the assistant (Beta)"))
        #expect(on.contains("See your AI use"))
    }
}
