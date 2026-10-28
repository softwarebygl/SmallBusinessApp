//
//  ComposeCapabilityTests.swift
//  GLSmallBusinessTests
//
//  The Mail / Messages capability guard (audit 2026-10-03 F127). `canSendMail()` /
//  `canSendText()` used to be read only in `.disabled(…)` when the screen last drew, so a stale
//  answer (a Mail account removed while the app was in the background) could still build a
//  composer the device can't show. One helper now re-checks at the tap, and the compose views
//  check again before they build a controller, showing a plain message instead.
//

import Foundation
import SwiftUI
import Testing
@testable import GLSmallBusiness

@MainActor
struct ComposeCapabilityTests {

    /// Every Email and Text button on a document re-checks at the tap, through the one helper.
    @Test func everyComposeButtonRechecksAtTheTap() throws {
        for path in ["Screens/EstimateDetailScreen.swift", "Screens/InvoiceDetailScreen.swift",
                     "Screens/ChangeOrderScreens.swift"] {
            let code = try #require(GLSource.code(path))
            #expect(code.contains("ComposeCapability.check(.mail"), "\(path): Email doesn't re-check at the tap")
            #expect(code.contains("ComposeCapability.check(.text"), "\(path): Text doesn't re-check at the tap")
        }
    }

    /// The compose views decide before they build a controller.
    @Test func composeViewsCheckBeforeBuildingAController() throws {
        let code = try #require(GLSource.code("UIComponents/ShareSupport.swift"))
        #expect(code.contains("ComposeCapability.canSend(.mail)"), "MailComposeView builds a controller unchecked")
        #expect(code.contains("ComposeCapability.canSend(.text)"), "MessageComposeView builds a controller unchecked")
        // Nobody else builds the controllers.
        for file in GLSource.codeFiles() where file.path != "UIComponents/ShareSupport.swift" {
            #expect(!file.text.contains("MFMailComposeViewController()"), "\(file.path) builds a Mail controller")
            #expect(!file.text.contains("MFMessageComposeViewController()"), "\(file.path) builds a Messages controller")
        }
    }
}

/// The helper's own rules, with the device's answer injected.
@MainActor
struct ComposeCapabilityRuleTests {

    @Test func theTapGoesAheadOnlyWhenTheDeviceCanCompose() {
        var unavailable: ComposeCapability.Channel?
        let binding = Binding(get: { unavailable }, set: { unavailable = $0 })

        #expect(ComposeCapability.check(.mail, into: binding, available: true))
        #expect(unavailable == nil, "nothing to say when Mail can open")

        #expect(!ComposeCapability.check(.mail, into: binding, available: false))
        #expect(unavailable == .mail, "a stale Email button says why instead of opening")

        unavailable = nil
        #expect(!ComposeCapability.check(.text, into: binding, available: false))
        #expect(unavailable == .text)
    }

    @Test func theMessagesArePlainAndLocalized() {
        #expect(ComposeCapability.unavailableMessage(.mail) == mbLoc("There’s no email account set up on this iPhone."))
        #expect(ComposeCapability.unavailableMessage(.text) == mbLoc("This iPhone can’t send text messages."))
    }
}
