//
//  WhatsNewScreen.swift
//  GLSmallBusiness
//
//  A native "What's New" screen for the menu — the current release's highlights. Update `MBWhatsNew.items`
//  each release; the version line reads the app's own bundle (never typed here).
//

import SwiftUI
import GoldLifeUI

/// The current release's highlights, in ONE place: the What's New screen draws them and the
/// assistant's `help` tool (section whats_new) reads them, so the two can never disagree.
/// Update the list each release. The version is the installed app's own (found 2026-09-29: a
/// typed version number still said 3.0 on 3.1).
enum MBWhatsNew {
    struct Item {
        let icon: String
        let title: String.LocalizationValue
        let body: String.LocalizationValue
        /// When the highlight shows, by the assistant switch (MBFeatureFlags).
        var shown: Shown = .always
    }

    enum Shown { case always, assistantOn, assistantOff }

    /// The version line (e.g. Version 3.2.0) in the app’s language, from the bundle’s CFBundleShortVersionString.
    static var version: String { versionLabel(short: bundleShortVersion) }

    static var bundleShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func versionLabel(short: String) -> String { mbLoc("Version \(short)") }

    static var items: [Item] { items(assistantEnabled: MBFeatureFlags.assistantEnabled) }

    static func items(assistantEnabled: Bool) -> [Item] {
        allItems.filter {
            switch $0.shown {
            case .always: true
            case .assistantOn: assistantEnabled
            case .assistantOff: !assistantEnabled
            }
        }
    }

    private static let allItems: [Item] = [
        // Owner ask 2026-10-03: while the assistant is off, What's New says it's coming.
        .init(icon: "sparkles", title: "Coming soon: the assistant (Beta)",
              body: "Ask in your own words, and the assistant finds, adds and updates your records for you.", shown: .assistantOff),
        .init(icon: "doc.text.fill", title: "Contracts & Change Orders",
              body: "Turn estimates into contracts, preview the PDF before sending, and manage change orders directly on the contract without an invoice."),
        .init(icon: "signature", title: "Sign on Device",
              body: "Customers can physically sign contracts right on your device, or you can mark them signed to send for signature later."),
        .init(icon: "gauge.with.dots.needle.33percent", title: "See your AI use",
              body: "Connect your own API keys, track your daily and monthly AI spend, and set spend limits right inside the assistant.", shown: .assistantOn),
        .init(icon: "lock.shield", title: "Tax IDs stay out of AI",
              body: "Tax IDs are taken out of anything the assistant sends, so they never reach the AI service.", shown: .assistantOn),
        .init(icon: "photo", title: "Remove a logo or photo by asking",
              body: "Ask the assistant to take a logo or photo off a document. It checks with you first.", shown: .assistantOn),
        .init(icon: "building.2", title: "A business name is enough",
              body: "Your business profile saves with just a name. Add the rest whenever you’re ready."),
        .init(icon: "number", title: "Exact prices and rates",
              body: "The assistant now works with your prices, rates, and quantities exactly as you entered them — no rounding.", shown: .assistantOn),
        .init(icon: "rectangle.portrait.and.arrow.right", title: "Sign out, and this device is clear",
              body: "Signing out clears your records from this device. Sign back in and they come back from your Gold Life ID. If something hasn’t backed up yet, the Menu warns you first. Tax IDs stay in this device’s Keychain, and your business Tax ID can only be read while you’re signed in. Deleting your Gold Life ID erases them all."),
        .init(icon: "eye.slash", title: "Hidden in the app switcher",
              body: "With Hide when switching apps on, your records are covered the moment you leave for the app switcher."),
        .init(icon: "slider.horizontal.3", title: "Clearer logo settings",
              body: "Each logo switch in Settings now says exactly where your logo appears — documents and texts, or emails."),
    ]
}

struct WhatsNewScreen: View {
    // Resolved in the app's chosen language here (mbLoc reads it, so a language switch
    // re-renders this body); the resolved text is handed to GLHighlight as its key, which
    // finds no entry and draws the text as given.
    private var highlights: [GLHighlight] {
        MBWhatsNew.items.map {
            GLHighlight(icon: $0.icon, title: LocalizedStringKey(mbLoc($0.title)), body: LocalizedStringKey(mbLoc($0.body)))
        }
    }

    var body: some View {
        GLWhatsNewScreen(title: mbLoc("What’s New"), version: MBWhatsNew.version, highlights: highlights)
            // Outside the package screen, so its own title margins never reach the card.
            .mbSystemBanners()
    }
}
