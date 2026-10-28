//
//  ProfileDedupTests.swift
//  GLSmallBusinessTests
//
//  Launch-time duplicate-profile collapse. The dangerous edge is the blank check: any user-set
//  field it misses turns a real profile into a "blank" that dedup deletes after a multi-device
//  sync (phone-only owner profile, Stripe-only business profile, …). These tests run the real
//  ProfileDedup.run against an isolated in-memory container (see TestStore) and assert that
//  single-field profiles survive while truly-empty duplicates still collapse.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ProfileDedupUserTests {
    @Test func populatedUserProfilesBothSurvive() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        let first = UserProfile()
        first.useMyNameInEmails = true
        let second = UserProfile()
        second.useMyNameInEmails = true
        ctx.insert(first)
        ctx.insert(second)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<UserProfile>())
        #expect(remaining.count == 2)   // both hold real data — neither may be deleted
        #expect(remaining.allSatisfy { $0.useMyNameInEmails })
    }

    @Test func trulyBlankUserDuplicateIsDeleted() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        ctx.insert(UserProfile())   // untouched — the initial-sync-window duplicate
        let populated = UserProfile()
        populated.useMyNameInEmails = true
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<UserProfile>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.useMyNameInEmails == true)
    }

    @Test func allBlankUserProfilesKeepExactlyOne() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        ctx.insert(UserProfile())
        ctx.insert(UserProfile())
        ctx.insert(UserProfile())

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<UserProfile>())
        #expect(remaining.count == 1)
    }
}

@MainActor
struct ProfileDedupBusinessTests {
    @Test func stripeAccountIdOnlyProfileSurvives() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        // The StripeConnectScreen.ensureProfile path: a fresh profile holding only the connection.
        let stripeOnly = BusinessProfile()
        stripeOnly.stripeConnectedAccountId = "acct_1ABC"
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        ctx.insert(stripeOnly)
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 2)   // the durable resume key must never be deleted
        #expect(remaining.contains { $0.stripeConnectedAccountId == "acct_1ABC" })
    }

    @Test func stripeClaimOnlyProfileSurvives() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        let claimOnly = BusinessProfile()
        claimOnly.stripeAccountClaim = "hmac-claim"
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        ctx.insert(claimOnly)
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.stripeAccountClaim == "hmac-claim" })
    }

    @Test func legacyTINOnlyProfileSurvives() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        // For a pre-Keychain user, w9TIN can be the LAST copy of their SSN/EIN.
        let tinOnly = BusinessProfile()
        tinOnly.w9TIN = "123456789"
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        ctx.insert(tinOnly)
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.w9TIN == "123456789" })
    }

    @Test func nonDefaultPayLinkToggleProfileSurvives() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        let toggled = BusinessProfile()
        toggled.payLinkDefaultOn = false   // user-set: off is not the default
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        ctx.insert(toggled)
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 2)
        #expect(remaining.contains { !$0.payLinkDefaultOn })
    }

    @Test func trulyBlankBusinessDuplicateIsDeleted() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        ctx.insert(BusinessProfile())   // untouched — the initial-sync-window duplicate
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.businessName == "Gold Life LLC")
    }

    @Test func blankDuplicateStillCarriesCountersBeforeDeletion() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        // Counters deliberately do NOT count as "populated" (carryCounters moves them), so a
        // counter-only duplicate collapses — but the survivor must keep the highest numbers.
        let counterOnly = BusinessProfile()
        counterOnly.lastInvoiceNumber = 42
        counterOnly.lastEstimateNumber = 7
        let populated = BusinessProfile()
        populated.businessName = "Gold Life LLC"
        populated.lastInvoiceNumber = 10
        ctx.insert(counterOnly)
        ctx.insert(populated)

        ProfileDedup.run(ctx)

        let remaining = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.lastInvoiceNumber == 42)
        #expect(remaining.first?.lastEstimateNumber == 7)
    }
}
