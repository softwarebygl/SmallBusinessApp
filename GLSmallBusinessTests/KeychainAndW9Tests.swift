//
//  KeychainAndW9Tests.swift
//  GLSmallBusinessTests
//
//  The BUSINESS profile's TIN and W-9 completeness. (The per-subcontractor TINs — keyed per record,
//  cleared independently, never allocated for a blank — are SubcontractorCoverageTests' rows.)
//
//  Serialized: these tests share one Keychain item (the TIN), so they must not run concurrently.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct KeychainAndW9Tests {
    /// The business Tax ID belongs to a signed-in account (2026-09-29). The unit host has no
    /// session, and its launch runs the signed-out wipe, which drops any scope — so each test
    /// names its own account.
    init() { SecureTINStore.setAccountScope("unit-tests") }

    @Test func secureTINWriteReadClearRoundTrip() {
        let p = BusinessProfile()
        p.updateTIN("12-3456789")
        #expect(p.secureTIN == "12-3456789")
        // A second profile reads the same shared Keychain value.
        #expect(BusinessProfile().secureTIN == "12-3456789")
        p.updateTIN("")
        #expect(p.secureTIN == "")
    }

    @Test func updateTINPurgesLegacyPlaintext() {
        let p = BusinessProfile()
        SecureTINStore.write("")          // ensure a clean keychain
        p.w9TIN = "99-3544594"            // legacy plaintext
        #expect(p.secureTIN == "99-3544594")   // read falls back to legacy
        p.updateTIN("11-1111111")        // migrate
        #expect(p.w9TIN == "")           // legacy copy purged
        #expect(p.secureTIN == "11-1111111")
        SecureTINStore.write("")
    }

    @Test func w9CompleteWhenNameClassificationAndTINPresent() {
        SecureTINStore.write("")
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.w9TaxClassificationRaw = W9TaxClassification.sCorporation.rawValue
        p.w9TINTypeRaw = W9TINType.ein.rawValue
        p.w9TIN = "123456789"
        #expect(p.w9IsComplete)
        #expect(p.w9MissingRequirements.isEmpty)
    }

    /// Audit 2026-10-03 F58 (REQUIREMENTS law 73): deleting the Gold Life ID erases ALL of the
    /// person's data, and the Tax IDs are the most sensitive part of it. At HEAD the deletion path
    /// wiped the store (and with it every subcontractor's `tinKey`) but no Keychain item, so the
    /// business EIN and every subcontractor SSN stayed in iCloud Keychain for good, unreachable.
    @Test func accountDeletionRemovesTheBusinessAndSubcontractorTaxIDs() throws {
        let service = "GLSecureTIN.deletion-tests.\(UUID().uuidString)"
        let stripeService = "GLStripeInstallToken.deletion-tests.\(UUID().uuidString)"
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let ana = TS.subcontractor(first: "Ana", in: context)
        ana.tinKey = UUID().uuidString
        let ben = TS.subcontractor(first: "Ben", in: context)
        ben.tinKey = UUID().uuidString
        _ = TS.subcontractor(first: "Cy", in: context)          // never had a Tax ID: no key
        context.saveChanges()
        let anaAccount = SecureTINStore.subcontractorAccount(ana.tinKey)
        let benAccount = SecureTINStore.subcontractorAccount(ben.tinKey)
        defer {
            for account in [anaAccount, benAccount, SecureTINStore.businessAccount(for: "person-keep"),
                            SecureTINStore.legacyBusinessAccount, SecureTINStore.legacyMigrationMarkerAccount] {
                SecureTINStore.write("", account: account, service: service)
            }
            StripeInstallTokenStore.delete(for: "owner-del", service: stripeService)
        }
        #expect(SecureTINStore.writeBusiness("12-3456789", scope: "owner-del", service: service))
        #expect(SecureTINStore.writeBusiness("98-7654321", scope: "person-keep", service: service))
        #expect(SecureTINStore.write("123-45-6789", account: anaAccount, service: service))
        #expect(SecureTINStore.write("987-65-4321", account: benAccount, service: service))
        // The pre-2026-09-29 unscoped item was copied to THIS account: it is the same Tax ID.
        #expect(SecureTINStore.write("12-3456789", account: SecureTINStore.legacyBusinessAccount, service: service))
        #expect(SecureTINStore.write("owner-del", account: SecureTINStore.legacyMigrationMarkerAccount, service: service))
        #expect(StripeInstallTokenStore.save(.init(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_D"),
                                             for: "owner-del", service: stripeService))

        GoldLifeAuth.purgeAccountSecrets(scope: "owner-del", context: context,
                                         tinService: service, stripeService: stripeService)

        #expect(SecureTINStore.readBusiness(scope: "owner-del", service: service).isEmpty, "the business EIN is gone")
        #expect(SecureTINStore.read(account: anaAccount, service: service).isEmpty, "Ana's SSN is gone")
        #expect(SecureTINStore.read(account: benAccount, service: service).isEmpty, "Ben's SSN is gone")
        #expect(SecureTINStore.read(account: SecureTINStore.legacyBusinessAccount, service: service).isEmpty,
                "the old copy of the same Tax ID is gone too")
        #expect(StripeInstallTokenStore.load(for: "owner-del", service: stripeService) == nil, "the Stripe token is gone")
        #expect(SecureTINStore.readBusiness(scope: "person-keep", service: service) == "98-7654321",
                "another Gold Life ID's Tax ID is not this deletion's")
    }

    /// The order matters: the subcontractors' keys live in the store, so the Keychain purge must run
    /// BEFORE the store wipe, or the keys are gone and the items are orphaned forever.
    @Test func accountDeletionPurgesSecretsBeforeTheStoreWipe() throws {
        let auth = try #require(GLSource.file("Services/GoldLifeAuth.swift"))
        let body = try #require(GLSource.functionBody("deleteAccount", in: auth))
        let purge = try #require(body.range(of: "Self.purgeAccountSecrets("))
        let wipe = try #require(body.range(of: "UserScopedStore.shared.wipeOnAccountDeletion()"))
        #expect(purge.lowerBound < wipe.lowerBound)
    }

    /// A previous account's unscoped item that was copied to SOMEONE ELSE is not this account's.
    @Test func accountDeletionLeavesALegacyItemThatWentToAnotherAccount() throws {
        let service = "GLSecureTIN.deletion-tests.\(UUID().uuidString)"
        let container = try TestStore.makeContainer()
        defer {
            SecureTINStore.write("", account: SecureTINStore.legacyBusinessAccount, service: service)
            SecureTINStore.write("", account: SecureTINStore.legacyMigrationMarkerAccount, service: service)
        }
        #expect(SecureTINStore.write("55-5555555", account: SecureTINStore.legacyBusinessAccount, service: service))
        #expect(SecureTINStore.write("person-keep", account: SecureTINStore.legacyMigrationMarkerAccount, service: service))
        GoldLifeAuth.purgeAccountSecrets(scope: "owner-del", context: container.mainContext,
                                         tinService: service, stripeService: "GLStripeInstallToken.deletion-tests.unused")
        #expect(SecureTINStore.read(account: SecureTINStore.legacyBusinessAccount, service: service) == "55-5555555")
    }

    @Test func w9MissingTINIsReported() {
        SecureTINStore.write("")
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.w9TaxClassificationRaw = W9TaxClassification.individual.rawValue
        p.w9TINTypeRaw = ""           // no TIN type
        p.w9TIN = ""                  // no TIN
        #expect(!p.w9IsComplete)
        #expect(p.w9MissingRequirements.contains { $0.contains("Tax ID") })
    }
}
