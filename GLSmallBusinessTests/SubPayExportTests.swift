//
//  SubPayExportTests.swift
//  GLSmallBusinessTests
//
//  The subcontractor year-end handoff: a 1099 summary CSV + a payment-ledger CSV. Mirrors
//  EmployeePayExportTests — headers, content, the $600 flag, year/paid filtering, sort, and CSV
//  safety (formula-injection guard, comma quoting).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct SubPayExportTests {
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func summary(_ files: [URL]) -> String { files.first { $0.lastPathComponent.contains("1099") }.map(read) ?? "" }
    private func ledger(_ files: [URL]) -> String { files.first { $0.lastPathComponent.contains("Payments") }.map(read) ?? "" }

    @Test func producesSummaryAndLedger() {
        let sub = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing")
        TS.paySub(sub, 1_800, date: TS.day(2026, 5, 1), detail: "Rough-in")
        let files = SubPayExport.files(subcontractors: [sub], year: 2026, business: nil)
        #expect(files.count == 2)

        let s = summary(files)
        #expect(s.contains("Subcontractor,Business,TIN type,TIN,Address,Total paid 2026,1099-NEC required"))
        #expect(s.contains("Mendoza Plumbing"))
        #expect(s.contains("1800.00"))
        #expect(s.contains("Yes"))   // over $600

        let l = ledger(files)
        #expect(l.contains("Subcontractor,Paid on,Amount,Method,For"))
        #expect(l.contains("2026-05-01"))
        #expect(l.contains("Rough-in"))
    }

    @Test func summaryIncludesTIN() {
        let sub = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing")
        sub.w9TINType = .ein
        sub.updateTIN("12-3456789")
        TS.paySub(sub, 1_800, date: TS.day(2026, 5, 1))
        let s = summary(SubPayExport.files(subcontractors: [sub], year: 2026, business: nil))
        #expect(s.contains("12-3456789"))   // full TIN for the accountant to file
        #expect(s.contains("EIN"))
        sub.clearSecureTIN()
    }

    @Test func flagsUnderThresholdAsNo() {
        let sub = TS.subcontractor(first: "Tara", last: "Boyd", business: "Boyd Electric")
        TS.paySub(sub, 425, date: TS.day(2026, 3, 1))
        #expect(summary(SubPayExport.files(subcontractors: [sub], year: 2026, business: nil)).contains(",No"))
    }

    @Test func onlyIncludesSubsPaidThatYear() {
        let paid = TS.subcontractor(first: "P", last: "Aid", business: "Paid Co")
        TS.paySub(paid, 900, date: TS.day(2026, 2, 1))
        let unpaidActive = TS.subcontractor(first: "U", last: "Npaid", business: "Idle Co")  // active, no payments
        let priorYear = TS.subcontractor(first: "O", last: "Ld", business: "Last Year Co")
        TS.paySub(priorYear, 1_000, date: TS.day(2025, 2, 1))

        let s = summary(SubPayExport.files(subcontractors: [paid, unpaidActive, priorYear], year: 2026, business: nil))
        #expect(s.contains("Paid Co"))
        #expect(!s.contains("Idle Co"))      // active but not paid this year → excluded
        #expect(!s.contains("Last Year Co")) // only paid in 2025 → excluded from 2026
    }

    @Test func ledgerFiltersByYearAndSortsByDate() {
        let sub = TS.subcontractor(first: "Multi", last: "Pay")
        TS.paySub(sub, 1_000, date: TS.day(2025, 12, 20), detail: "old")
        TS.paySub(sub, 300, date: TS.day(2026, 3, 15), detail: "later")
        TS.paySub(sub, 200, date: TS.day(2026, 1, 10), detail: "earlier")
        let l = ledger(SubPayExport.files(subcontractors: [sub], year: 2026, business: nil))
        #expect(!l.contains("2025-12-20"))   // prior year excluded
        let lines = l.split(separator: "\n")
        let i1 = lines.firstIndex { $0.contains("2026-01-10") }
        let i2 = lines.firstIndex { $0.contains("2026-03-15") }
        #expect(i1 != nil && i2 != nil && i1! < i2!)   // ascending by date
    }

    @Test func summarySortsPaidSubsByName() {
        // Two paid subs exercises the payee-name sort in files().
        let z = TS.subcontractor(business: "Zephyr Co")
        TS.paySub(z, 700, date: TS.day(2026, 1, 1))
        let a = TS.subcontractor(business: "Acme Co")
        TS.paySub(a, 800, date: TS.day(2026, 1, 1))
        let lines = summary(SubPayExport.files(subcontractors: [z, a], year: 2026, business: nil))
            .split(separator: "\n")
        let ia = lines.firstIndex { $0.contains("Acme Co") }
        let iz = lines.firstIndex { $0.contains("Zephyr Co") }
        #expect(ia != nil && iz != nil && ia! < iz!)   // Acme sorts before Zephyr
    }

    @Test func owedEntriesAreExcludedFromTheHandoff() {
        let sub = TS.subcontractor(business: "Owed Co")
        TS.paySub(sub, 700, date: TS.day(2026, 3, 1))     // paid → in the 1099
        TS.oweSub(sub, 5_000, date: TS.day(2026, 3, 2))   // owed → must not appear or inflate the total
        let files = SubPayExport.files(subcontractors: [sub], year: 2026, business: nil)
        let s = summary(files)
        #expect(s.contains("700.00"))
        #expect(!s.contains("5000.00") && !s.contains("5700.00"))   // owed not added to the total
        #expect(!ledger(files).contains("5000.00"))                  // owed not in the payment ledger
    }

    @Test func neutralizesFormulaInjection() {
        let sub = TS.subcontractor(first: "", last: "", business: "=cmd()")
        TS.paySub(sub, 700, date: TS.day(2026, 1, 1))
        #expect(summary(SubPayExport.files(subcontractors: [sub], year: 2026, business: nil)).contains("'=cmd"))
    }

    @Test func quotesCommasAndIncludesBusinessName() {
        let profile = BusinessProfile()
        profile.businessName = "Gold Life, LLC"
        let sub = TS.subcontractor(first: "Sam", last: "O'Neil, Jr")
        TS.paySub(sub, 800, date: TS.day(2026, 2, 2))
        let s = summary(SubPayExport.files(subcontractors: [sub], year: 2026, business: profile))
        #expect(!s.contains("# Gold Life"))   // no in-band banner row; business name is in the filename
        #expect(s.contains("\"Sam O'Neil, Jr\""))
    }

    @Test func emptyBusinessNameAddsNoHeaderLine() {
        let profile = BusinessProfile()   // businessName defaults to ""
        let sub = TS.subcontractor(first: "Pat", last: "Lee")
        TS.paySub(sub, 650, date: TS.day(2026, 1, 1))
        let s = summary(SubPayExport.files(subcontractors: [sub], year: 2026, business: profile))
        #expect(!s.hasPrefix("#"))
        #expect(s.contains("Pat Lee"))
    }
}
