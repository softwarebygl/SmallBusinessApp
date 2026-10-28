//
//  RecordSearchTests.swift
//  GLSmallBusinessTests
//
//  THE home of the `matchesSearch` predicates (Models/RecordSearch.swift) — the free-text filters
//  behind the people directories, the record ledgers ("View All" hours / paychecks / sub activity),
//  the document lists, and the Jobs, Receipts and Price Sheet searches — and of the one matcher
//  they all go through, `RecordSearch.matches`. Every predicate is pure, so every test here is
//  too: no container, no render. An empty or whitespace-only query matches everything; every word
//  of the query has to appear (as a substring, case- and accent-insensitive) in some field; and
//  each model searches exactly its own indexed fields.
//

import Testing
import Foundation
import GoldLifeUI
@testable import GLSmallBusiness

@MainActor
struct RecordSearchTests {

    // MARK: - People directories (name / business / email / phone)

    @Test func customerSearchMatchesEveryFieldAndHandlesBlankUnicodeAndMissing() {
        let c = Customer(firstName: "José", lastName: "Núñez", email: "jose@obras.mx",
                         phoneNumber: "(850) 555-0148", businessName: nil)
        // Whitespace-only and empty queries match everyone (callers pass raw field text straight in).
        #expect(c.matchesSearch(""))
        #expect(c.matchesSearch("\n\t  "))
        // Case-insensitive substring, including a non-ASCII name.
        #expect(c.matchesSearch("josé"))
        #expect(c.matchesSearch("NÚÑEZ"))
        #expect(c.matchesSearch("jose@"))             // email fragment
        // A nil business name contributes an empty string rather than crashing.
        #expect(!c.matchesSearch("acme"))
        // Punctuation is NOT normalized — a digits-only phone query does not match a formatted number.
        #expect(c.matchesSearch("555-0148"))
        #expect(!c.matchesSearch("8505550148"))
        // The business name is indexed too.
        let business = TS.customer()                  // Marcus Reed of Reed General Contracting
        #expect(business.matchesSearch("general contracting"))
        #expect(!business.matchesSearch("zzz"))
        // A completely blank customer still answers (and matches only the empty query).
        let blank = Customer()
        #expect(blank.matchesSearch("   "))
        #expect(!blank.matchesSearch("x"))
    }

    /// Mirrors the employee-list filter: name, email, and phone, with an empty query passing all.
    @Test func employeeSearchMatchesNameEmailAndPhone() {
        let employee = TS.employee(first: "Hannah", last: "Whitfield",
                                   email: "hannah.whitfield@example.com", phone: "(850) 555-0121")
        #expect(employee.matchesSearch(""))
        #expect(employee.matchesSearch("whit"))
        #expect(employee.matchesSearch("HANNAH"))
        #expect(employee.matchesSearch("example.com"))
        #expect(employee.matchesSearch("555-0121"))
        #expect(!employee.matchesSearch("caldwell"))

        let nameless = TS.employee(first: "", last: "", email: "", phone: "")
        #expect(nameless.matchesSearch(""))                 // empty query still matches
        #expect(!nameless.matchesSearch("anything"))
    }

    @Test func subcontractorSearchMatchesEveryIndexedField() {
        let sub = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing",
                                   email: "luis@mendozaplumbing.com", phone: "(850) 555-0164")
        #expect(sub.matchesSearch(""))            // empty query matches everything
        #expect(sub.matchesSearch("   "))
        #expect(sub.matchesSearch("luis"))        // case-insensitive
        #expect(sub.matchesSearch("MENDOZA"))
        #expect(sub.matchesSearch("Plumbing"))
        #expect(sub.matchesSearch("mendozaplumbing.com"))
        #expect(sub.matchesSearch("555-0164"))
        #expect(!sub.matchesSearch("Boyd"))
    }

    // MARK: - Record ledgers (the "View All" sheets)

    @Test func subPaymentSearchMatchesDetailCustomerMethodAndAmount() {
        let customer = Customer(firstName: "Marcus", lastName: "Reed")
        let sub = TS.subcontractor()
        let entry = TS.paySub(sub, 1_250, date: TS.day(2026, 3, 3), method: .transfer,
                              detail: "Fixture set", customer: customer)
        #expect(entry.matchesSearch(""))
        #expect(entry.matchesSearch("  "))
        #expect(entry.matchesSearch("fixture"))
        #expect(entry.matchesSearch("Reed"))               // tagged customer
        #expect(entry.matchesSearch("Bank transfer"))      // method label
        #expect(entry.matchesSearch("1250"))               // raw amount
        #expect(!entry.matchesSearch("zelle"))

        // An untagged, detail-less owed entry still matches on method + amount, never on nil customer.
        let bare = TS.oweSub(sub, 77, date: TS.day(2026, 3, 4))
        #expect(bare.matchesSearch("77"))
        #expect(bare.matchesSearch("Check"))
        #expect(!bare.matchesSearch("Reed"))
    }

    @Test func timeEntrySearchMatchesNoteCustomerAndHours() {
        let customer = Customer(firstName: "Marcus", lastName: "Reed")
        let employee = TS.employee(hourlyRate: 25)
        let entry = TS.logHours(employee, 7.5, customer: customer)
        entry.note = "Grout haze removal"

        #expect(entry.matchesSearch(""))                    // empty query matches everything
        #expect(entry.matchesSearch("   "))                 // whitespace-only too
        #expect(entry.matchesSearch("GROUT"))               // case-insensitive on the note
        #expect(entry.matchesSearch("reed"))                // the tagged customer
        #expect(entry.matchesSearch("7.5"))                 // the raw hours string
        #expect(!entry.matchesSearch("plumbing"))
    }

    @Test func timeEntrySearchHandlesNoCustomerAndUnicodeNotes() {
        let employee = TS.employee(hourlyRate: 25)
        let untagged = TS.logHours(employee, 3)
        untagged.note = "Café — piso de baño 🚿"
        #expect(untagged.customer == nil)
        #expect(untagged.matchesSearch("café"))
        #expect(untagged.matchesSearch("🚿"))
        #expect(untagged.matchesSearch("BAÑO"))
        #expect(untagged.matchesSearch("3"))                // whole-number hours
        #expect(!untagged.matchesSearch("kitchen"))
    }

    @Test func paycheckSearchMatchesMethodNoteAndGross() {
        let employee = TS.employee()
        let check = TS.paycheck(employee, gross: 1_234.5, periodStart: TS.day(2026, 3, 1),
                                periodEnd: TS.day(2026, 3, 7), payDate: TS.day(2026, 3, 8),
                                method: .zelle)
        check.note = "Includes $100.00 bonus."
        #expect(check.matchesSearch(""))
        #expect(check.matchesSearch("bonus"))
        #expect(check.matchesSearch("1234.5"))
        #expect(check.matchesSearch(check.method.label.lowercased()))
        #expect(!check.matchesSearch("mileage"))

        // A fragment of a multi-word method label matches too ("transfer" in "Bank transfer").
        let transfer = TS.paycheck(employee, gross: 1_824, periodStart: TS.day(2026, 3, 8),
                                   periodEnd: TS.day(2026, 3, 14), payDate: TS.day(2026, 3, 15),
                                   method: .transfer)
        #expect(transfer.matchesSearch("transfer"))
        #expect(transfer.matchesSearch("1824"))
    }

    // MARK: - Documents (job title / number / customer snapshot / status)

    @Test func invoiceSearchMatchesTitleNumberCustomerAndStatus() {
        let invoice = TS.invoice(number: "INV-LC-57", status: .sent)
        invoice.jobTitle = "Master Bath — Porcelain Tile"
        invoice.customerFirstName = "Marcus"
        invoice.customerLastName = "Reed"

        #expect(invoice.matchesSearch(""))                 // empty query matches everything
        #expect(invoice.matchesSearch("   "))              // whitespace-only too
        #expect(invoice.matchesSearch("master bath"))      // case-insensitive title, across a word break
        #expect(invoice.matchesSearch("PORCELAIN"))
        #expect(invoice.matchesSearch("lc-57"))            // number, case-insensitive
        #expect(invoice.matchesSearch("Marcus"))           // customer snapshot
        #expect(invoice.matchesSearch("Reed"))
        #expect(invoice.matchesSearch("Sent"))             // status label
        #expect(!invoice.matchesSearch("Draft"))
        #expect(!invoice.matchesSearch("zzz-no-match"))
    }

    @Test func invoiceSearchOnAnInvoiceWithNoCustomerNameFallsBackToTheGenericLabel() {
        let invoice = TS.invoice(number: "INV-LC-58")
        invoice.customer = nil
        invoice.customerFirstName = ""
        invoice.customerLastName = ""
        invoice.customerBusinessName = nil
        #expect(invoice.customerDisplayName == "Customer")
        #expect(invoice.matchesSearch("Customer"))
        #expect(!invoice.matchesSearch("Marcus"))
    }

    @Test func documentSearchUsesSnapshotNameAndStatus() {
        // An invoice with no live customer AND no snapshot displays "Customer" — and therefore
        // matches that word, and nothing of a name it never had.
        let orphan = TS.invoice(number: "INV-7001")
        orphan.jobTitle = ""
        #expect(orphan.customer == nil)
        #expect(orphan.customerDisplayName == "Customer")
        #expect(orphan.matchesSearch("customer"))
        #expect(!orphan.matchesSearch("Marcus"))
        #expect(orphan.matchesSearch("INV-7001"))
        #expect(orphan.matchesSearch("draft"))            // default status label
        #expect(!orphan.matchesSearch("sent"))

        // The snapshot, not the live relationship, is what the list searches.
        let est = TS.estimate(number: "EST-7001", status: .accepted)
        est.customerFirstName = "Danielle"
        est.customerLastName = "Carter"
        #expect(est.matchesSearch("danielle carter"))
        #expect(est.matchesSearch("accepted"))
        #expect(!est.matchesSearch("draft"))

        // A business-only snapshot falls through to the business name; the number, the job title,
        // and the default status are indexed alongside it.
        let bizEst = TS.estimate(number: "EST-7002")
        bizEst.jobTitle = "Garage Floor Coating"
        bizEst.customerBusinessName = "Nguyen Property Management"
        #expect(bizEst.customerDisplayName == "Nguyen Property Management")
        #expect(bizEst.matchesSearch("nguyen property"))
        #expect(bizEst.matchesSearch("EST-7002"))         // number
        #expect(bizEst.matchesSearch("garage floor"))     // job title
        #expect(bizEst.matchesSearch("draft"))            // default status label
        #expect(!bizEst.matchesSearch("zzz"))
    }

    @Test func changeOrderSearchToleratesAMissingInvoice() {
        let co = ChangeOrder(number: "CO-7001", title: "Add second coat")
        #expect(co.invoice == nil)
        #expect(co.matchesSearch("CO-7001"))
        #expect(co.matchesSearch("second"))
        #expect(co.matchesSearch("pending"))          // default status label
        #expect(co.matchesSearch("  "))               // blank matches everything
        #expect(!co.matchesSearch("INV-0001"))        // no parent invoice number to match

        let linked = TS.changeOrder(TS.invoice(number: "INV-7002"), number: "CO-7002")
        #expect(linked.matchesSearch("INV-7002"))     // matches through the parent invoice
    }

    // MARK: - Every word, any field (`RecordSearch.matches`, the one matcher)

    /// The matcher on its own: blank matches all, words split on any whitespace, each word must
    /// sit inside ONE field (never straddle two), and accents and case never matter.
    @Test func theMatcherNeedsEveryWordInSomeField() {
        #expect(RecordSearch.matches("", in: []))
        #expect(RecordSearch.matches(" \n\t ", in: ["x"]))
        #expect(!RecordSearch.matches("a", in: []))
        #expect(RecordSearch.matches("tile grout", in: ["Grout", "Tile"]))
        #expect(RecordSearch.matches("tile\tgrout", in: ["Grout", "Tile"]))
        #expect(!RecordSearch.matches("tile grout", in: ["Grout"]))
        #expect(!RecordSearch.matches("johnsmith", in: ["John", "Smith"]), "a word never straddles two fields")
        #expect(RecordSearch.matches("crème", in: ["CREME brulee"]))
        #expect(RecordSearch.matches("CREME", in: ["crème brûlée"]))
    }

    /// The bug the assistant's find hit: "John Smith" was matched WHOLE against one field at a
    /// time, and first and last names are separate fields, so it found nobody.
    @Test func aFullNameMatchesAcrossTheFirstAndLastNameFields() {
        let john = TS.customer(first: "John", last: "Smith", email: "", phone: "", business: nil)
        #expect(john.matchesSearch("John Smith"))
        #expect(john.matchesSearch("smith john"))                 // any order
        #expect(john.matchesSearch("  JOHN \t smith\n"))          // any case, any whitespace
        #expect(john.matchesSearch("jo smi"))                     // each word is still a substring
        #expect(!john.matchesSearch("John Rivera"), "one matching word is not a match")
        #expect(!john.matchesSearch("Mike Smith"))

        let mike = TS.employee(first: "Mike", last: "Rivera")
        #expect(mike.matchesSearch("Mike Rivera"))
        #expect(mike.matchesSearch("rivera mike"))
        #expect(!mike.matchesSearch("John Rivera"))

        let sub = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing")
        #expect(sub.matchesSearch("luis mendoza plumbing"))
        #expect(!sub.matchesSearch("luis mendoza electric"))
    }

    /// José = jose, both ways — the query's accents and the record's are both ignored.
    @Test func accentsAreIgnoredBothWays() {
        let accented = Customer(firstName: "José", lastName: "Núñez")
        #expect(accented.matchesSearch("jose"))
        #expect(accented.matchesSearch("Jose Nunez"))
        #expect(accented.matchesSearch("JOSÉ núñez"))
        let plain = Customer(firstName: "Jose", lastName: "Nunez")
        #expect(plain.matchesSearch("José"))
        #expect(plain.matchesSearch("núñez josé"))
        #expect(!plain.matchesSearch("José Rivera"))
    }

    /// A business name, a document number, and a name all combine — every word has to land.
    @Test func businessNamesAndDocumentNumbersCombineWithOtherWords() {
        let reed = TS.customer()                                  // Marcus Reed of Reed General Contracting
        #expect(reed.matchesSearch("Reed General Contracting"))
        #expect(reed.matchesSearch("marcus contracting"))
        #expect(!reed.matchesSearch("marcus plumbing"))

        let invoice = TS.invoice(number: "INV-0042", status: .sent)
        invoice.jobTitle = "Master Bath"
        invoice.customerFirstName = "John"
        invoice.customerLastName = "Smith"
        #expect(invoice.matchesSearch("INV-0042"))
        #expect(invoice.matchesSearch("inv-0042 smith"))
        #expect(invoice.matchesSearch("John Smith"))
        #expect(invoice.matchesSearch("smith john bath sent"))
        #expect(!invoice.matchesSearch("INV-0042 rivera"))
        #expect(!invoice.matchesSearch("INV-0043"))

        let estimate = TS.estimate(number: "EST-0012", status: .accepted)
        estimate.customerBusinessName = "Nguyen Property Management"
        #expect(estimate.matchesSearch("nguyen management EST-0012"))
        #expect(!estimate.matchesSearch("nguyen EST-0013"))

        let order = TS.changeOrder(TS.invoice(number: "INV-7002"), number: "CO-7002")
        #expect(order.matchesSearch("CO-7002 INV-7002 pending"))
        #expect(!order.matchesSearch("CO-7002 approved"))
    }

    /// The ledgers ("View All" sheets) take several words too.
    @Test func ledgerEntriesMatchEveryWord() {
        let customer = Customer(firstName: "Marcus", lastName: "Reed")
        let sub = TS.subcontractor()
        let entry = TS.paySub(sub, 1_250, date: TS.day(2026, 3, 3), method: .transfer,
                              detail: "Fixture set", customer: customer)
        #expect(entry.matchesSearch("fixture reed marcus"))
        #expect(!entry.matchesSearch("fixture smith"))

        let employee = TS.employee(hourlyRate: 25)
        let hours = TS.logHours(employee, 7.5, customer: customer)
        hours.note = "Grout haze removal"
        #expect(hours.matchesSearch("grout removal reed"))
        #expect(!hours.matchesSearch("grout install"))

        let check = TS.paycheck(employee, gross: 1_824, periodStart: TS.day(2026, 3, 8),
                                periodEnd: TS.day(2026, 3, 14), payDate: TS.day(2026, 3, 15),
                                method: .transfer)
        #expect(check.matchesSearch("bank transfer 1824"))
        #expect(!check.matchesSearch("transfer 999"))
    }

    /// The Jobs, Receipts and Price Sheet searches used their own matchers before; now they go
    /// through the same one, words and accents included.
    @Test func jobsReceiptsAndPriceItemsMatchEveryWord() {
        let john = TS.customer(first: "John", last: "Smith", email: "", phone: "", business: nil)
        let job = TS.job("Deck repair", start: TS.day(2026, 9, 1), customer: john)   // name snapshot "Smith, John"
        #expect(job.matchesSearch("Deck"))
        #expect(job.matchesSearch("deck john smith"))
        #expect(!job.matchesSearch("deck rivera"))

        let receipt = Receipt(vendor: "Home Depot", date: TS.day(2026, 9, 2), total: 42, category: "Materials")
        receipt.notes = "Grout for the bath"
        #expect(receipt.matchesSearch("home depot grout"))
        #expect(!receipt.matchesSearch("home depot lumber"))
        #expect(!receipt.matchesSearch("business"), "the assistant passes no stand-in for an untagged receipt")
        #expect(receipt.matchesSearch("depot business", untaggedLabel: "Business"), "the list's untagged label")
        receipt.customer = john
        #expect(receipt.matchesSearch("depot smith john", untaggedLabel: "Business"))
        #expect(!receipt.matchesSearch("business", untaggedLabel: "Business"), "a tagged receipt searches its customer")

        let item = PriceSheetItem(name: "Grout", details: "sanded", category: "Tile")
        #expect(item.matchesSearch("tile sanded grout"))
        #expect(!item.matchesSearch("tile epoxy"))
        #expect(PriceSheetService.search([item], query: "grout tile").map(\.name) == ["Grout"])
        #expect(PriceSheetService.search([item], query: "grout plumbing").isEmpty)
    }

    // MARK: - The fleet's matcher

    /// `RecordSearch.matches` IS GoldLifeUI's `GLSearchMatch`:
    /// same answer on every shape of query, so the apps can't drift apart.
    @Test func recordSearchAnswersThroughTheFleetMatcher() {
        let cases: [(String, [String])] = [
            ("", []), ("  ", ["x"]), ("white marble", ["Carrara White", "Italian Marble"]),
            ("johnsmith", ["John", "Smith"]), ("John Rivera", ["John", "Smith"]),
            ("mármol", ["Marmol"]), ("o\u{2019}brien", ["O'Brien"]), ("8505550148", ["(850) 555-0148"]),
        ]
        for (query, fields) in cases {
            #expect(RecordSearch.matches(query, in: fields) == GLSearchMatch.matches(query: query, fields: fields),
                    "\(query)")
        }
    }

    // MARK: - Line-item name autocomplete (Estimate and Invoice forms)

    @Test func lineItemNameCountsTrimAndDropBlanks() {
        let counts = LineItemNameSuggestions.counts(["Grout", " Grout ", "", "   ", "Tile install\n"])
        #expect(counts == ["Grout": 2, "Tile install": 1])
        #expect(LineItemNameSuggestions.counts([]).isEmpty)
    }

    /// The type-ahead used to match the whole typed text as one substring ("tile install" never
    /// offered "Install porcelain tile"); it now takes every word, like the searches.
    @Test func lineItemSuggestionsMatchEveryWordAndRankByUse() {
        let counts = ["Install porcelain tile": 5, "Porcelain tile install": 5, "Tile removal": 2,
                      "Café tile": 1, "Grout": 9]
        #expect(LineItemNameSuggestions.matching("tile install", counts: counts)
                == ["Install porcelain tile", "Porcelain tile install"])
        // Most-used first, ties A to Z.
        #expect(LineItemNameSuggestions.matching("tile", counts: counts)
                == ["Install porcelain tile", "Porcelain tile install", "Tile removal", "Café tile"])
        #expect(LineItemNameSuggestions.matching("cafe", counts: counts) == ["Café tile"], "accents never matter")
        #expect(LineItemNameSuggestions.matching("TILE REM", counts: counts) == ["Tile removal"])
        #expect(LineItemNameSuggestions.matching("tile epoxy", counts: counts).isEmpty, "every word has to land")
    }

    @Test func lineItemSuggestionsStayQuietWhenBlankOrAlreadyTyped() {
        let counts = ["Grout": 9, "Grout sealing": 1]
        #expect(LineItemNameSuggestions.matching("", counts: counts).isEmpty)
        #expect(LineItemNameSuggestions.matching(" \n ", counts: counts).isEmpty)
        // The name exactly as typed is never offered back (case and spacing ignored)...
        #expect(LineItemNameSuggestions.matching("grout", counts: counts) == ["Grout sealing"])
        #expect(LineItemNameSuggestions.matching("  GROUT ", counts: counts) == ["Grout sealing"])
        // ...but a longer name that starts with it is.
        #expect(LineItemNameSuggestions.matching("grout seal", counts: counts) == ["Grout sealing"])
        #expect(LineItemNameSuggestions.matching("grout sealing", counts: counts).isEmpty)
    }

    @Test func lineItemSuggestionsAreCapped() {
        let counts = Dictionary(uniqueKeysWithValues: (1...9).map { ("Tile \($0)", $0) })
        #expect(LineItemNameSuggestions.matching("tile", counts: counts) == ["Tile 9", "Tile 8", "Tile 7", "Tile 6"])
        #expect(LineItemNameSuggestions.matching("tile", counts: counts, limit: 2) == ["Tile 9", "Tile 8"])
        #expect(LineItemNameSuggestions.matching("tile", counts: counts, limit: 0).isEmpty)
        #expect(LineItemNameSuggestions.matching("tile", counts: counts, limit: -1).isEmpty)
    }
}
