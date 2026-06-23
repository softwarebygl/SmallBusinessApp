//
//  RecordSearchTests.swift
//  GLSmallBusinessTests
//
//  Covers the matchesSearch predicates behind the new search fields: an empty/whitespace query matches
//  everything, matching is case-insensitive and substring-based, and each model searches the right fields.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct RecordSearchTests {

    // MARK: - People directories

    @Test func customerMatchesNameBusinessEmailPhone() {
        let c = Customer(firstName: "Danielle", lastName: "Carter", email: "dani@reed.com",
                         phoneNumber: "850-555-0148", businessName: "Reed Contracting")
        #expect(c.matchesSearch("carter"))            // last name, lower-cased
        #expect(c.matchesSearch("Reed"))              // business
        #expect(c.matchesSearch("dani@"))             // email fragment
        #expect(c.matchesSearch("0148"))              // phone fragment
        #expect(!c.matchesSearch("zzz"))              // no match
    }

    @Test func emptyOrWhitespaceQueryMatchesEveryone() {
        let c = Customer(firstName: "A", lastName: "B")
        #expect(c.matchesSearch(""))
        #expect(c.matchesSearch("   "))
    }

    @Test func employeeMatchesNameAndEmail() {
        let e = TS.employee(first: "Jason", last: "Garcia", email: "jason@x.com", phone: "555-0110")
        #expect(e.matchesSearch("garcia"))
        #expect(e.matchesSearch("jason@x"))
        #expect(!e.matchesSearch("nope"))
    }

    @Test func subcontractorMatchesBusiness() {
        let s = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing")
        #expect(s.matchesSearch("plumbing"))
        #expect(s.matchesSearch("mendoza"))
    }

    // MARK: - Record ledgers

    @Test func subPaymentMatchesDetailMethodAmount() {
        let s = TS.subcontractor(first: "Luis", last: "Mendoza")
        let p = TS.paySub(s, 1800, method: .check, detail: "Rough-in plumbing")
        #expect(p.matchesSearch("rough"))             // detail
        #expect(p.matchesSearch("check"))             // method label ("Check")
        #expect(p.matchesSearch("1800"))              // amount
        #expect(!p.matchesSearch("xyz"))
    }

    @Test func timeEntryMatchesCustomerAndHours() {
        let c = Customer(firstName: "Marcus", lastName: "Reed")
        let entry = TS.logHours(TS.employee(), 9, customer: c)
        #expect(entry.matchesSearch("reed"))          // tagged customer
        #expect(entry.matchesSearch("9"))             // hours
    }

    @Test func paycheckMatchesMethodAndGross() {
        let check = TS.paycheck(TS.employee(), gross: 1824, periodStart: .now, periodEnd: .now,
                                payDate: .now, method: .transfer)
        #expect(check.matchesSearch("transfer"))      // method label ("Bank transfer")
        #expect(check.matchesSearch("1824"))          // gross
    }
}
