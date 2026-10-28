//
//  MBHelpTool.swift
//  GLSmallBusiness — AI
//
//  `help`: how the app works, in the app's own words and the app's current language — the
//  InfoLabel / InfoButton explanations the screens show, What's New (`MBWhatsNew`, the same list
//  the What's New screen draws) and the version (contract §5). Tap-by-tap steps come from the
//  "App guide" in the server-side instructions (R3, written from these screens and this string
//  catalog), so the tool tells the model to answer from that guide, and to offer `open how_to`
//  (the web How To) only for more.
//
//  `MBHelpCatalog.topics` repeats the screens' info texts as the SAME catalog keys (so no new
//  translation exists or can drift); `HelpCatalogTests` scans the screens and fails if one of
//  their InfoLabel / InfoButton texts is missing here.
//

import Foundation
import GoldLifeAI

/// Every in-app explanation (InfoLabel / InfoButton), as its catalog keys.
enum MBHelpCatalog {
    struct Topic {
        let topic: String.LocalizationValue
        let text: String.LocalizationValue
        /// Where it is shown, in English (model-facing).
        let place: String
    }

    static let topics: [Topic] = [
        .init(topic: "Appearance", text: "System, Light, or Dark, for My Business on this device. Your Gold Life ID holds the setting every Gold Life app follows.", place: "Settings"),
        .init(topic: "Language", text: "English or Español, for My Business on this device. Your Gold Life ID holds the setting every Gold Life app follows.", place: "Settings"),
        .init(topic: "What customers see", text: "Everything that shows up on the estimates, invoices, receipts and emails you send. Your logo in emails uses the light version — email backgrounds are white.", place: "Settings"),
        .init(topic: "In the app", text: "Personalizes the Menu button and the faint background watermark. This device only — it changes nothing your customers see.", place: "Settings"),
        .init(topic: "Scheduling", text: "Warns you before you double-book a day.", place: "Settings"),
        .init(topic: "Workdays", text: "Set your workdays and hours, the holidays you take off, and any time off — these drive your next available date and the gaps between jobs.", place: "Settings"),
        .init(topic: "Security", text: "Require Face ID (or your device passcode) to open My Business, and again if you have been away for a minute. Hiding when switching apps covers your records in the app switcher, where your device stores the picture it takes — turn it off if you want to see this app beside another one. Your records are encrypted on this device either way, and your Gold Life backup can only be reached by signing in.", place: "Settings"),
        .init(topic: "Reference Certificate of Insurance", text: "Optional. A spare, blank Certificate of Insurance kept only for your own records — it’s never sent to customers or added to a package.", place: "Compliance documents"),
        .init(topic: "Import from Phone Contacts", text: "Pull a name, phone, and email straight from your phone's contacts.", place: "Employee form"),
        .init(topic: "Import from Phone Contacts", text: "Pull a name, phone, email, and address straight from your phone's contacts.", place: "Customer form"),
        .init(topic: "Import from Phone Contacts", text: "Pull a name, business, phone, email, and address from your phone's contacts.", place: "Subcontractor form"),
        .init(topic: "Photo", text: "Optional. A photo of you for your personal profile.", place: "Gold Life ID profile"),
        .init(topic: "Logo", text: "Optional. Appears on your estimates and invoices, and customizes the app.", place: "My Business Details"),
        .init(topic: "Tax details (for W-9)", text: "Optional. Used to generate a W-9. Your Tax ID is stored securely in your Keychain, not the synced database. Sign and date the form by hand after you print or send it.", place: "My Business Details"),
        .init(topic: "Exemption codes", text: "Optional W-9 exemption codes. Most small businesses leave these blank.", place: "My Business Details"),
        .init(topic: "Service Address", text: "The specific job site or lot this estimate is for. Optional — leave blank if it's at the customer's own address.", place: "Estimate form"),
        .init(topic: "Totals", text: "On: everything adds into one total. Off: each group is its own priced option the customer can choose from.", place: "Estimate form"),
        .init(topic: "Receipt Photo", text: "Scan with the camera or upload an existing image. The vendor, date, and total are read from it automatically.", place: "Receipt form"),
        .init(topic: "Assignment", text: "Leave as Business for general expenses, or assign this receipt to a customer and, optionally, a specific job.", place: "Receipt form"),
        .init(topic: "Stripe", text: "Connect a Stripe account to let your customers pay your invoices by card. This is for charging your customers — it is not related to your My Business subscription. Payments go straight to your Stripe account; we never hold your money.", place: "Card payments"),
        .init(topic: "Pay button on invoices", text: "Sets the default for new invoices. Every invoice keeps its own Pay-button toggle, so you can turn it on or off for any single invoice.", place: "Card payments"),
        .init(topic: "Service Address", text: "The specific job site or lot this invoice is for. Optional — leave blank if it's at the customer's own address.", place: "Invoice form"),
        .init(topic: "Deposit or milestone", text: "Bill a deposit or a milestone now instead of the whole job. Leave it at $0 to request the full balance.", place: "Invoice form"),
        .init(topic: "Change Order", text: "Set an item to Credit to subtract for removed work.", place: "Change order form"),
        .init(topic: "Pay rate", text: "Optional. If set, you can log what you owe as “hours × rate.” Leave at $0 to enter flat amounts.", place: "Subcontractor form"),
        .init(topic: "Tax details (for their 1099-NEC)", text: "Optional. The SSN/EIN from the W-9 they gave you. Stored securely in your Keychain, not the synced database — used to generate their 1099-NEC.", place: "Subcontractor form"),
        .init(topic: "Your signature", text: "Stored privately in your Gold Life account and protected by Face ID. Used to sign documents like your W-9.", place: "Signature"),
        .init(topic: "Sentinel", text: "Sentinel sends what you type and the records needed to answer when using a connected cloud AI. Turn this off and Sentinel will ask again before sending.", place: "Settings (only while sharing is on)"),
        .init(topic: "Backup", text: "Your records back up to your Gold Life account. This device stopped because another one deleted an unusual number of items at once.", place: "Settings (only while the backup is paused)"),
        .init(topic: "Automated Payment Reminders", text: "Automatically emails friendly payment reminders to clients from noreply@softwarebygl.com based on invoice due dates.", place: "Document Settings"),
        .init(topic: "Service Address", text: "The job site or property address where work is performed. When different from billing, this will auto-fill into new estimates and contracts.", place: "Customer form"),
        .init(topic: "Full Balance Invoice", text: "Generates an invoice for 100% of the remaining contract balance and all approved change orders.", place: "Invoice from contract"),
        .init(topic: "Percentage Invoicing", text: "Invoice a progress payment or deposit as a percentage of the total contract value.", place: "Invoice from contract"),
        .init(topic: "Line Item Invoicing", text: "Pick the exact line items you want to invoice for this billing cycle.", place: "Invoice from contract"),
        .init(topic: "Signer Name", text: "The full legal name of the person signing and authorizing this contract.", place: "Sign contract"),
        .init(topic: "Signature", text: "Draw your signature with your finger or Apple Pencil, or type your name for a generated signature.", place: "Sign contract"),
        .init(topic: "Contract Schedule", text: "Dates scheduled here appear directly in your Calendar tab.", place: "Contract form"),
        .init(topic: "Agreed Price", text: "Optional agreed price. If left off, the contract total is computed from line items and change orders.", place: "Contract form"),
    ]
}

@MainActor
struct MBHelpTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    static let maxTopics = 6

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        let args = MBArguments(json: call.arguments)
        let question = args.string("question") ?? ""
        let budget = MBOutputFit.budget(context)
        let language = MBLocalization.resolvedLanguageCode
        switch args.string("section") ?? "how_to" {
        case "whats_new":
            let items = MBWhatsNew.items.map { item -> GLAIJSON in
                ["title": .string(mbLoc(item.title)), "body": .string(mbLoc(item.body))]
            }
            return .result(MBOutputFit.fit(["section": "whats_new", "language": .string(language),
                                            "version": .string(MBWhatsNew.version), "items": .array(items)],
                                           trimming: ["items"], budget: budget))
        case "about":
            return .result(MBOutputFit.fit(["section": "about", "app": "My Business",
                                            "version": .string(Self.bundleString("CFBundleShortVersionString")),
                                            "build": .string(Self.bundleString("CFBundleVersion")),
                                            "maker": "Gold Life LLC"],
                                           trimming: [], budget: budget))
        case "how_to":
            let matches = Self.topics(for: question)
            let rows = matches.prefix(Self.maxTopics).map { topic -> GLAIJSON in
                ["topic": .string(mbLoc(topic.topic)), "text": .string(mbLoc(topic.text)), "where": .string(topic.place)]
            }
            return .result(MBOutputFit.fit([
                "section": "how_to",
                "language": .string(language),
                "topics": .array(rows),
                "guides": "For how-to and where-is questions, give the steps from the App guide in your instructions: they are the app's own help, naming screens and buttons as quoted there. For more, offer open with target how_to. Don't invent steps that are in neither.",
            ], trimming: ["topics"], budget: budget))
        default:
            return MBToolFailure.invalid("section must be how_to, whats_new or about.")
        }
    }

    /// Topics whose words (in English or the app's language) share a word of 3+ letters with the
    /// question, best match first.
    static func topics(for question: String) -> [MBHelpCatalog.Topic] {
        let words = Set(question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        let scored = MBHelpCatalog.topics.map { topic -> (Int, MBHelpCatalog.Topic) in
            let haystack = [english(topic.topic), english(topic.text),
                            mbLoc(topic.topic), mbLoc(topic.text), topic.place].joined(separator: " ").lowercased()
            let score = words.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return (score, topic)
        }
        return scored.filter { $0.0 > 0 }.sorted { $0.0 > $1.0 }.map(\.1)
    }

    static func english(_ value: String.LocalizationValue) -> String {
        var resource = LocalizedStringResource(value)
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
