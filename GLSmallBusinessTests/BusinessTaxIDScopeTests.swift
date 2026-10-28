//
//  BusinessTaxIDScopeTests.swift
//  GLSmallBusinessTests
//
//  The business Tax ID's Keychain item belongs to ONE Gold Life ID (2026-09-29). Before, it was
//  one unscoped item per device, so the next person to sign in on the same iPhone read it. Now:
//  another account never reads it; the old unscoped item moves to the first account that reads
//  with none of its own, exactly once, and is never deleted.
//
//  Every test uses its own Keychain service, so nothing here races the rest of the suite.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@Suite(.serialized)
struct BusinessTaxIDScopeTests {
    private static func freshService() -> String {
        "GLSecureTIN.scope-tests.\(UUID().uuidString)"
    }

    /// Removes every item a test wrote under its private service.
    private static func clear(_ service: String, scopes: [String]) {
        for scope in scopes {
            _ = SecureTINStore.write("", account: SecureTINStore.businessAccount(for: scope), service: service)
        }
        _ = SecureTINStore.write("", account: SecureTINStore.legacyBusinessAccount, service: service)
        _ = SecureTINStore.write("", account: SecureTINStore.legacyMigrationMarkerAccount, service: service)
    }

    @Test func anotherAccountNeverReadsTheTaxID() {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a", "person-b"]) }
        #expect(SecureTINStore.writeBusiness("12-3456789", scope: "owner-a", service: service))
        #expect(SecureTINStore.readBusiness(scope: "owner-a", service: service) == "12-3456789")
        #expect(SecureTINStore.readBusiness(scope: "person-b", service: service) == "")
        // B saving its own Tax ID never touches A's.
        #expect(SecureTINStore.writeBusiness("98-7654321", scope: "person-b", service: service))
        #expect(SecureTINStore.readBusiness(scope: "owner-a", service: service) == "12-3456789")
    }

    @Test func signedOutReadsNothingAndWritesNothing() {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        #expect(SecureTINStore.writeBusiness("12-3456789", scope: "owner-a", service: service))
        #expect(SecureTINStore.readBusiness(scope: nil, service: service) == "")
        #expect(SecureTINStore.readBusiness(scope: "", service: service) == "")
        #expect(!SecureTINStore.writeBusiness("11-1111111", scope: nil, service: service))
        #expect(SecureTINStore.readBusiness(scope: "owner-a", service: service) == "12-3456789")
    }

    @Test func theOldUnscopedItemMovesToTheFirstAccountOnceAndIsKept() {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a", "person-b"]) }
        // The pre-2026-09-29 item.
        #expect(SecureTINStore.write("55-5555555", account: SecureTINStore.legacyBusinessAccount, service: service))

        // The first signed-in read with nothing of its own gets it…
        #expect(SecureTINStore.readBusiness(scope: "owner-a", service: service) == "55-5555555")
        #expect(SecureTINStore.read(account: SecureTINStore.businessAccount(for: "owner-a"), service: service) == "55-5555555")
        // …the old item is never deleted…
        #expect(SecureTINStore.read(account: SecureTINStore.legacyBusinessAccount, service: service) == "55-5555555")
        // …and nobody else ever receives it.
        #expect(SecureTINStore.readBusiness(scope: "person-b", service: service) == "")
        #expect(SecureTINStore.read(account: SecureTINStore.businessAccount(for: "person-b"), service: service) == "")
    }

    @Test func anAccountWithItsOwnTaxIDIsNotOverwrittenByTheOldItem() {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        #expect(SecureTINStore.write("55-5555555", account: SecureTINStore.legacyBusinessAccount, service: service))
        #expect(SecureTINStore.writeBusiness("12-3456789", scope: "owner-a", service: service))
        #expect(SecureTINStore.readBusiness(scope: "owner-a", service: service) == "12-3456789")
    }

    @Test func accountsAreKeyedPathSafeAndDistinct() {
        #expect(SecureTINStore.businessAccount(for: "user-a") != SecureTINStore.businessAccount(for: "user-b"))
        #expect(SecureTINStore.businessAccount(for: "user-a") != SecureTINStore.legacyBusinessAccount)
        #expect(!SecureTINStore.businessAccount(for: "../x").contains("/"))
    }

    /// The wiring: the scope is set when the person's store mounts (before the legacy drain reads
    /// it) and dropped by the sign-out wipe.
    @Test func theScopeFollowsTheSession() throws {
        let gate = try #require(GLSource.file("AccessControl/GatePhase.swift"))
        let mount = try #require(GLSource.functionBody("mount", in: gate))
        let set = try #require(mount.range(of: "SecureTINStore.setAccountScope(canonicalID)"))
        let drain = try #require(mount.range(of: "LegacyTINDrain.run(context)"))
        #expect(set.lowerBound < drain.lowerBound)

        let purge = try #require(GLSource.file("Services/MBSessionPurge.swift"))
        let stepStart = try #require(purge.range(of: "static func registerWipe(_ wipe"))
        let register = try #require(GLSource.functionBody("registerWipe", in: String(purge[stepStart.lowerBound...])))
        #expect(register.contains("SecureTINStore.setAccountScope(nil)"))
    }
}
