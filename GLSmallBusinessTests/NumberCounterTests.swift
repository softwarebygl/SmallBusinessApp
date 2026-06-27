//
//  NumberCounterTests.swift
//  GLSmallBusinessTests
//
//  The monotonic invoice/estimate counter (on BusinessProfile) must not reuse a number after the
//  highest-numbered document is deleted.
//

import Testing
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct NumberCounterTests {
    @Test func counterDoesNotReuseANumberAfterDeletingTheHighest() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let profile = BusinessProfile()
        ctx.insert(profile)

        let n1 = Invoice.nextNumber(after: [], profile: profile)
        #expect(n1 == "INV-0001")
        let inv1 = Invoice(number: n1); ctx.insert(inv1)

        let n2 = Invoice.nextNumber(after: [inv1], profile: profile)
        #expect(n2 == "INV-0002")
        let inv2 = Invoice(number: n2); ctx.insert(inv2)

        // Delete the highest-numbered invoice, then mint again with only INV-0001 present.
        ctx.delete(inv2)
        let n3 = Invoice.nextNumber(after: [inv1], profile: profile)
        #expect(n3 == "INV-0003")   // counter remembered 0002 -> 0003, NOT a reused 0002
    }

    @Test func withoutAProfileItStaysPlainMaxPlusOne() {
        // No profile -> no counter -> the old reuse behavior (used by callers that don't pass a profile).
        let inv = Invoice(number: "INV-0005")
        #expect(Invoice.nextNumber(after: [inv]) == "INV-0006")
        #expect(Invoice.nextNumber(after: []) == "INV-0001")
    }
}
