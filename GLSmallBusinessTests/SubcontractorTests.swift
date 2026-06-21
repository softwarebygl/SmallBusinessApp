//
//  SubcontractorTests.swift
//  GLSmallBusinessTests
//
//  The Subcontractor logic added this round: display helpers, payment totals, the $600 1099-NEC
//  threshold, and the year roll-up. Built in memory via the `TS` builders — no container needed.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct SubcontractorDisplayTests {
    @Test func fullNameAndListName() {
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").fullName == "Luis Mendoza")
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").listDisplayName == "Mendoza, Luis")
        #expect(TS.subcontractor(first: "", last: "", business: "Boyd Electric").listDisplayName == "Boyd Electric")
        #expect(TS.subcontractor(first: "", last: "").listDisplayName == "No name")
    }

    @Test func payeeNamePrefersBusiness() {
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing").payeeName == "Mendoza Plumbing")
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").payeeName == "Luis Mendoza")
    }

    @Test func initials() {
        #expect(TS.subcontractor(first: "Luis", last: "Mendoza").initials == "LM")
        #expect(TS.subcontractor(first: "", last: "", business: "Boyd Electric").initials == "B")
        #expect(TS.subcontractor(first: "", last: "").initials == "?")
    }
}

@MainActor
struct SubcontractorPayTests {
    @Test func sortedPaymentsNewestFirst() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 100, date: TS.day(2026, 6, 1))
        TS.paySub(sub, 300, date: TS.day(2026, 6, 3))
        TS.paySub(sub, 200, date: TS.day(2026, 6, 2))
        #expect(sub.sortedPayments.map(\.amount) == [300, 200, 100])
    }

    @Test func totalPaidFiltersByYear() {
        let sub = TS.subcontractor()
        TS.paySub(sub, 500, date: TS.day(2025, 12, 30))
        TS.paySub(sub, 400, date: TS.day(2026, 1, 5))
        TS.paySub(sub, 250, date: TS.day(2026, 7, 1))
        #expect(close(sub.totalPaid(year: 2026), 650))
        #expect(close(sub.totalPaid(year: 2025), 500))
        #expect(close(sub.lifetimePaid, 1_150))
    }

    @Test func requires1099AtThreshold() {
        let under = TS.subcontractor()
        TS.paySub(under, 599.99, date: TS.day(2026, 3, 1))
        #expect(!under.requires1099(year: 2026))

        let exactly = TS.subcontractor()
        TS.paySub(exactly, 600, date: TS.day(2026, 3, 1))
        #expect(exactly.requires1099(year: 2026))   // $600 exactly → required

        let over = TS.subcontractor()
        TS.paySub(over, 400, date: TS.day(2026, 1, 1))
        TS.paySub(over, 400, date: TS.day(2026, 2, 1))
        #expect(over.requires1099(year: 2026))       // 800 total
        #expect(!over.requires1099(year: 2025))      // none in 2025
    }

    @Test func nilPaymentsAreSafe() {
        let sub = Subcontractor()   // payments == nil
        #expect(sub.sortedPayments.isEmpty)
        #expect(close(sub.totalPaid(year: 2026), 0))
        #expect(close(sub.lifetimePaid, 0))
        #expect(!sub.requires1099(year: 2026))
    }

    @Test func defaultYearComputedsUseCurrentYear() {
        let sub = TS.subcontractor()
        let thisYear = Calendar.current.component(.year, from: Date())
        TS.paySub(sub, 700, date: TS.day(thisYear, 1, 10))
        #expect(close(sub.totalPaid(), 700))   // no-arg → current year
        #expect(sub.requires1099())            // no-arg → current year, over $600
    }
}

@MainActor
struct Subcontractor1099SummaryTests {
    @Test func sumsTotalsAndCounts1099() {
        let a = TS.subcontractor(first: "A", last: "Over")
        TS.paySub(a, 1_000, date: TS.day(2026, 4, 1))   // needs 1099
        let b = TS.subcontractor(first: "B", last: "Under")
        TS.paySub(b, 300, date: TS.day(2026, 4, 1))     // under threshold
        let c = TS.subcontractor(first: "C", last: "Prior")
        TS.paySub(c, 5_000, date: TS.day(2025, 4, 1))   // wrong year — excluded from 2026

        let totals = Subcontractor1099Summary.forYear([a, b, c], year: 2026)
        #expect(close(totals.totalPaid, 1_300))
        #expect(totals.count1099 == 1)
    }

    @Test func emptyRosterIsZero() {
        let totals = Subcontractor1099Summary.forYear([], year: 2026)
        #expect(close(totals.totalPaid, 0) && totals.count1099 == 0)
    }
}
