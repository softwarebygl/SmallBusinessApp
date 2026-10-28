//
//  MBAssistantStrings.swift
//  GLSmallBusiness — AI
//
//  Everything the HOST supplies to the chat screen already localized (GoldLifeAI's
//  `GLAIChatHost`): the title, the composer's prompt, the working line per phase, the example
//  requests, the activity card's caption, and the whole consent sheet's content — the provider,
//  every data class the tools can return, what is never sent, how the provider treats requests,
//  and where to stop sharing.
//
//  The package owns its own sentences (`GLAIStrings`); this file owns the ones that are about THIS
//  app's data. Both are resolved against this app's `Localizable.xcstrings` (EN + ES).
//

import Foundation
import GoldLifeAI
import GoldLifeCloud
import GoldLifeUI

extension GLAIConsent {
    /// My Business's assistant consent key (law 26 "mb." prefix).
    static let myBusinessKey = "mb.ai.consent.version"

    /// The version of the assistant's consent sheet (`MBAssistantStrings.consentContent` plus
    /// GoldLifeAI's own sentences). Bump it whenever the sheet says something new (who receives
    /// the data, what is shared): everyone who agreed to an older sheet is asked again (law 74).
    /// - v1: the old assistant's yes/no flag (`GLAIConsent.legacyKey`). Never honoured.
    /// - v2 (build 83): the toolbox assistant's sheet (contract §4).
    /// - v3 (build 84): the sheet names Gold Life's server, which carries every request to
    ///   Google (owner decision 2026-09-27). Everyone who agreed to v2 is asked again. The
    ///   Worker's `AI_MIN_CONSENT_VERSION` stays 2 so the App Store build keeps working.
    /// - v4: added Beta disclaimers and Terms/Privacy Policy agreement.
    static let myBusinessVersion = 4

    /// The one store the consent sheet writes and the assistant's transport checks.
    static func myBusiness(defaults: UserDefaults = .standard) -> GLAIConsent {
        GLAIConsent(key: myBusinessKey, requiredVersion: myBusinessVersion, defaults: defaults)
    }
}

@MainActor
enum MBAssistantStrings {

    // MARK: The screen

    static var title: String { mbLoc("Sentinel") }
    static var composerPlaceholder: String { mbLoc("Ask about your business, or tell me what to do") }
    static var activityCardTitle: String { mbLoc("What I did") }
    static var examplesTitle: String { mbLoc("Try one of these") }

    static func workingLabel(_ phase: GLAIConversationController.Phase) -> String {
        switch phase {
        case .idle, .thinking: return mbLoc("Thinking…")
        case .working: return mbLoc("Working…")
        case .confirming: return mbLoc("Waiting for you…")
        }
    }

    /// Three requests a contractor would really make, in the app's language.
    static var examples: [GLChatExample] {
        [
            GLChatExample(systemImage: "banknote", text: mbLoc("Who owes me money right now?")),
            GLChatExample(systemImage: "clock", text: mbLoc("Log 6 hours for yesterday’s job.")),
            GLChatExample(systemImage: "doc.text", text: mbLoc("Start an estimate for a master bath tile job.")),
        ]
    }

    // MARK: Consent (contract §4, consent v4 — BYOK)

    /// Who receives the data, and the road it takes: straight from this device to the AI company
    /// the person connected with their own key.
    static var providerName: String { mbLoc("the AI companies you connect (OpenAI, Anthropic, Google or Meta), straight from this device with your own key") }

    static var consentContent: GLAIConsentContent {
        GLAIConsentContent(
            providerName: providerName,
            shared: [
                GLAIConsentItem(systemImage: "text.bubble", text: mbLoc("What you type or say to the assistant")),
                GLAIConsentItem(systemImage: "person.crop.circle",
                                text: mbLoc("Customers, their contact details and addresses")),
                GLAIConsentItem(systemImage: "doc.text",
                                text: mbLoc("Estimates, invoices, payments and change orders")),
                GLAIConsentItem(systemImage: "hammer", text: mbLoc("Jobs and their addresses")),
                GLAIConsentItem(systemImage: "doc.viewfinder",
                                text: mbLoc("Receipts, including their scanned text when you ask about one")),
                GLAIConsentItem(systemImage: "list.bullet.rectangle", text: mbLoc("Your price sheet")),
                GLAIConsentItem(systemImage: "person.text.rectangle",
                                text: mbLoc("Employees’ hours and pay")),
                GLAIConsentItem(systemImage: "person.2",
                                text: mbLoc("Subcontractors and what you paid them")),
                GLAIConsentItem(systemImage: "building.2",
                                text: mbLoc("Your business profile — name, contact details and address")),
            ],
            neverShared: [
                GLAIConsentItem(systemImage: "lock.shield", text: mbLoc("Tax IDs and W-9 details")),
                GLAIConsentItem(systemImage: "signature", text: mbLoc("Signatures")),
                GLAIConsentItem(systemImage: "photo", text: mbLoc("Photos, logos and scanned images")),
                GLAIConsentItem(systemImage: "creditcard", text: mbLoc("Card payment account details")),
                GLAIConsentItem(systemImage: "person.badge.key", text: mbLoc("Your Gold Life ID details")),
            ],
            providerTerms: mbLoc("BETA NOTICE: This assistant is in beta testing. There may be malfunctions, bugs, issues, or inaccurate responses. By using it, you agree to our Terms of Use and Privacy Policy.\n\nEach company handles your messages under its own terms and privacy policy, and bills your key for what you use."),
            howToStop: mbLoc("You can stop sharing any time in Settings, under Sentinel."))
    }

    // MARK: Offline

    /// The on-device model's instructions, in the app's language (contract §6).
    static var onDeviceInstructions: String {
        mbLoc("You are Sentinel, the AI agent inside My Business, answering with no internet connection. You can look things up with find, get and report, and nothing else. You cannot add or change anything: if the person asks for a change, say “I’ll need a connection to make that change.” Answer briefly, in the person’s own words, and never invent a number, a name or a date.")
    }
}
