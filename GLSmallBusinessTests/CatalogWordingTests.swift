//
//  CatalogWordingTests.swift
//  GLSmallBusinessTests
//
//  The string catalog's wording rules, read straight off disk (2026-10-03 audit, cluster C26):
//
//  • Law 87 (owner, 2026-10-01 "A"): the Spanish word for "estimate" is "presupuesto" in BOTH
//    apps, with masculine agreement. My Business said "cotización" in 51 values (F69, L1).
//  • Law 23: keys orphaned by a copy change are pruned in the same change. The catalog kept 152
//    stale keys, some stating retired behavior ("Signing out doesn’t delete anything…") (F138).
//    A key a Gold Life package resolves against the app's catalog (Bundle.main), or one the app
//    reads through mbLoc, is not stale: it is kept and marked manual, because Xcode's extractor
//    only sees the app target's own SwiftUI literals.
//  • Law 2: house typography (curly apostrophes) and true Spanish: "Job title" is the title of the
//    job, not a job position; a job's "Time" is the clock time; "Open change order" is an action;
//    an alert quotes a setting by the exact name the setting shows (F133).
//  • Law 4/88: the W-9 screen names the screen as it is called today, My Business Details (L11).
//
//  Every later change that deletes UI code re-runs the prune for the keys it orphans; the
//  stale-key test below fails until it does.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct CatalogWordingTests {

    // MARK: Catalog access

    private static func strings() throws -> [String: [String: Any]] {
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    /// Every stringUnit value under one language, plural/device variations included.
    private static func values(_ entry: [String: Any], language: String) -> [String] {
        guard let loc = (entry["localizations"] as? [String: Any])?[language] else { return [] }
        var out: [String] = []
        var stack: [Any] = [loc]
        while let node = stack.popLast() {
            guard let dict = node as? [String: Any] else { continue }
            if let value = (dict["stringUnit"] as? [String: Any])?["value"] as? String { out.append(value) }
            for group in (dict["variations"] as? [String: Any] ?? [:]).values {
                stack.append(contentsOf: (group as? [String: Any] ?? [:]).values)
            }
        }
        return out
    }

    private static func spanish(_ key: String, in strings: [String: [String: Any]]) -> String? {
        strings[key].flatMap { values($0, language: "es").first }
    }

    // MARK: Law 87 — "presupuesto", never "cotización"

    @Test func spanishSaysPresupuestoNeverCotizacion() throws {
        let strings = try Self.strings()
        let offenders = strings.filter { _, entry in
            Self.values(entry, language: "es").contains { $0.lowercased().contains("cotizaci") }
        }.keys.sorted()
        #expect(offenders.isEmpty, "\(offenders.count) Spanish values still say “cotización”: \(offenders.prefix(5))")

        // The words a Spanish user sees first, with masculine agreement.
        #expect(Self.spanish("Estimates", in: strings) == "Presupuestos")
        #expect(Self.spanish("Estimate", in: strings) == "Presupuesto")
        #expect(Self.spanish("New Estimate", in: strings) == "Nuevo presupuesto")
        #expect(Self.spanish("All Estimates", in: strings) == "Todos los presupuestos")
        #expect(Self.spanish("Delete this estimate?", in: strings) == "¿Eliminar este presupuesto?")
        #expect(Self.spanish("Accepted estimates", in: strings) == "Presupuestos aceptados")
    }

    // MARK: Law 23 — no stale keys, and nothing a package needs is pruned

    @Test func catalogHasNoStaleKeys() throws {
        let stale = try Self.strings().filter { $0.value["extractionState"] as? String == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "\(stale.count) stale keys: \(stale.prefix(5))")
        #expect(try Self.strings()["Signing out doesn’t delete anything. Your business data stays on this iPhone and stops backing up until you sign back in. Your subscription is unaffected."] == nil,
                "a retired sign-out sentence is still in the catalog")
    }

    /// Keys a Gold Life package (GoldLifeUI, GoldLifeAI) resolves against the app's catalog, or the
    /// app reads through mbLoc / a String parameter. Xcode marks them stale because its extractor
    /// never sees those call sites; the prune keeps them, with their Spanish.
    private static let keysUsedOutsideTheExtractor: [String] = [
        "All your accounts and spending in one place.",
        "Asks you to confirm by typing your Gold Life ID.",
        "Asks you to type your Gold Life ID, then confirm it’s you.",
        "Category",
        "Checking what each app still holds…",
        "Checking…",
        "Closing",
        "Continue with",
        "Continue with Apple",
        "Continue with Gold Life ID",
        "Continue with Google",
        "Couldn’t load your Gold Life apps — check your connection.",
        "Delete all %@ data",
        "Delete each app’s data above first. Your Gold Life ID can only go once nothing is left.",
        "Delete everything in %@?",
        "Delete your Gold Life ID?",
        "Deleting an app’s data happens straight away and can’t be undone.",
        "Deleting…",
        "Enter the code we emailed to %@. Codes expire after a few minutes.",
        "Explore with sample data",
        "Get",
        "Gold Life",
        "Loading…",
        "Nothing left to delete",
        "One of your apps couldn’t be checked. Open that app and delete its data there, then come back.",
        "Protected by Gold Life ID",
        "Remember me",
        "Send a new code",
        "Your Gold Life ID identifies your account. It isn’t a password — it can’t be used to sign in.",
        "Sign in",
        "Subject",
        "That code didn’t match or has expired. Try again, or send a new one.",
        "We couldn’t check your apps, so it isn’t safe to delete your Gold Life ID yet. Check your connection and try again.",
        "We couldn’t load your Gold Life ID, and confirming needs it. Check your connection and try again.",
        "Year-End Report",
        "Your Gold Life apps",
        "Your own copy — never sent to customers",
        "Your own reference copy — never sent. Customer certificates live on each customer.",
    ]

    @Test func keysUsedOutsideTheExtractorSurviveThePrune() throws {
        let strings = try Self.strings()
        for key in Self.keysUsedOutsideTheExtractor {
            let entry = strings[key]
            #expect(entry != nil, "pruned a key the app or a package still uses: \(key)")
            #expect(entry.map { !Self.values($0, language: "es").allSatisfy(\.isEmpty) } == true, "\(key) has no Spanish")
        }
    }

    // MARK: Law 2 — curly apostrophes in English

    /// English keys that still carry a straight apostrophe because their call sites live in files
    /// outside this change (each one names them). A ratchet: no NEW straight apostrophe gets in, and
    /// the file's owner deletes its line here when the literal turns curly (the test below fails on
    /// an entry that no longer exists, so the list can only shrink).
    private static let straightApostropheBacklog: [String: String] = [
        "Delete this customer's COI from your records.": "Screens/CustomerInsurance.swift",
        "Delete this customer's workers' comp certificate from your records.": "Screens/CustomerInsurance.swift",
        "Workers' Comp Certificate": "Screens/CustomerInsurance.swift",
        "Don't add a Pay button to invoices.": "Models/PayLinkInclusion.swift",
        "Payments can't be edited. Record a correcting payment instead.": "Sync/GLSyncTransport.swift",
        "Something didn't sync. Updating the app should fix it.": "Sync/GLSyncTransport.swift",
        "Syncing didn't finish. Your work is saved on this device and we'll try again.": "Sync/GLSyncTransport.swift",
        "That status change didn't stick. Reopen the record and set it again.": "Sync/GLSyncTransport.swift",
        "That value can only be set once and can't be changed.": "Sync/GLSyncTransport.swift",
        "This was deleted on another device, so the change wasn't saved.": "Sync/GLSyncTransport.swift",
        "You're offline. Your work is saved here and will sync when you reconnect.": "Sync/GLSyncTransport.swift",
        "That tax document couldn't be backed up. Your other changes were saved.": "Sync/GLSyncDocumentCrypto.swift",
        "That tax document couldn't be opened on this device. The copy on your other device is unaffected.": "Sync/GLSyncDocumentCrypto.swift",
        "The sync bookmark couldn't be read.": "Sync/GLSyncHistory.swift",
        "Pull a name, business, phone, email, and address from your phone's contacts.": "Screens/SubcontractorFormScreen.swift + AI/MBHelpTool.swift",
        "Pull a name, phone, and email straight from your phone's contacts.": "Screens/EmployeeFormScreen.swift + AI/MBHelpTool.swift",
        "Pull a name, phone, email, and address straight from your phone's contacts.": "Screens/CustomerFormScreen.swift + AI/MBHelpTool.swift",
        "The specific job site or lot this estimate is for. Optional — leave blank if it's at the customer's own address.": "Screens/EstimateFormScreen.swift + AI/MBHelpTool.swift",
        "The specific job site or lot this invoice is for. Optional — leave blank if it's at the customer's own address.": "Screens/InvoiceFormScreen.swift + AI/MBHelpTool.swift",
        "What it's for (e.g. Deposit to start)": "Screens/InvoiceFormScreen.swift",
        "Your Tax ID is stored in this device's secure Keychain and stays masked until Face ID confirms it's you.": "Screens/MenuScreen.swift",
    ]

    @Test func englishUsesCurlyApostrophes() throws {
        let strings = try Self.strings()
        let offenders = strings.filter { key, entry in
            (key.contains("'") || Self.values(entry, language: "en").contains { $0.contains("'") })
                && Self.straightApostropheBacklog[key] == nil
        }.keys.sorted()
        #expect(offenders.isEmpty, "\(offenders.count) English strings use a straight apostrophe: \(offenders.prefix(5))")
        let spanishOffenders = strings.filter { _, entry in
            Self.values(entry, language: "es").contains { $0.contains("'") }
        }.keys.sorted()
        #expect(spanishOffenders.isEmpty, "Spanish values with a straight apostrophe: \(spanishOffenders.prefix(5))")
    }

    @Test func theApostropheBacklogOnlyShrinks() throws {
        let strings = try Self.strings()
        for (key, owner) in Self.straightApostropheBacklog {
            #expect(strings[key] != nil, "\(owner) no longer uses “\(key)”: delete its backlog line")
        }
    }

    // MARK: Law 2 — true Spanish (F133)

    @Test func misreadSpanishWordsAreFixed() throws {
        let strings = try Self.strings()
        #expect(Self.spanish("Job title", in: strings) == "Título del trabajo")   // not "Puesto" (a position)
        #expect(Self.spanish("Time", in: strings) == "Hora")                      // the job's clock time
        #expect(Self.spanish("Open change order", in: strings) == "Abrir orden de cambio")   // a button: an action
    }

    /// An alert that names a setting quotes it exactly as the setting's toggle reads, in each language.
    @Test func alertsQuoteTheBookingToggleByItsOwnName() throws {
        let strings = try Self.strings()
        let toggleEN = "Book one job at a time"
        let toggleES = try #require(Self.spanish(toggleEN, in: strings))
        let settings = try #require(GLSource.code("Screens/SettingsScreen.swift"))
        #expect(settings.contains("Toggle(\"\(toggleEN)\""))

        let overlapKey = "“Book one job at a time” is on. All-day jobs warn on the same day; timed jobs warn when the times overlap."
        let jobForm = try #require(GLSource.code("Screens/JobFormScreen.swift"))
        #expect(jobForm.contains("Text(\"\(overlapKey)\")"))
        #expect(Self.spanish(overlapKey, in: strings)?.contains("“\(toggleES)”") == true,
                "the Job form alert quotes the toggle as \(Self.spanish(overlapKey, in: strings) ?? "nil")")

        let sheetKey = "You have “book one job at a time” on. Schedule this on top of the existing job?"
        if let sheetES = Self.spanish(sheetKey, in: strings) {
            #expect(sheetES.contains("“\(toggleES)”"), "the Schedule Job sheet quotes the toggle as \(sheetES)")
        }
    }

    // MARK: Law 4/88 — the W-9 names today's screen (L11)

    @Test func w9NamesMyBusinessDetails() throws {
        let strings = try Self.strings()
        let key = "Your W-9 already uses the business name and address from My Business Details. To complete it, just add:"
        let screen = try #require(GLSource.code("Screens/CompanyDocuments.swift"))
        #expect(screen.contains("Text(\"\(key)\")"))
        #expect(Self.spanish(key, in: strings) == "Tu W-9 ya usa el nombre y la dirección de Detalles de mi negocio. Para completarlo, solo agrega:")
        let stillSaysMyCompany = strings.filter { key, entry in
            key.contains("My Company") || Self.values(entry, language: "es").contains { $0.contains("My Company") }
        }.keys.sorted()
        #expect(stillSaysMyCompany.isEmpty, "the retired screen name is still in: \(stillSaysMyCompany)")
    }
}
