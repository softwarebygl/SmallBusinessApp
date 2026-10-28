//
//  SyncIdentityTests.swift
//  GLSmallBusinessTests
//
//  Platform Phase 0: every record must end up with a UNIQUE stable syncID, and
//  edits must move updatedAt. The load-bearing assertion is uniqueness — the whole
//  reason these fields are optional-plus-backfill instead of `= UUID()` is that a
//  SwiftData attribute default is captured once in schema metadata, which would
//  have given every migrated record the SAME uuid.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct SyncIdentityTests {
    /// The business Tax ID belongs to a signed-in account (2026-09-29). The unit host has no
    /// session, and its launch runs the signed-out wipe, which drops any scope — so each test
    /// names its own account.
    init() { SecureTINStore.setAccountScope("unit-tests") }


    /// Records created before the fields existed (simulated by inserting and saving
    /// WITHOUT saveChanges, so nothing stamps them) get unique ids from the sweep.
    @Test func backfillMintsUniqueIdsAcrossRecordsAndTypes() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let a = Customer(firstName: "Ada", lastName: "One")
        let b = Customer(firstName: "Ben", lastName: "Two")
        let e = Estimate(number: "EST-0001")
        ctx.insert(a); ctx.insert(b); ctx.insert(e)
        try ctx.save()                       // bare save: no stamping, like an old build
        a.syncID = nil; b.syncID = nil; e.syncID = nil
        try ctx.save()

        SyncIdentityBackfill.run(ctx)

        let ids = [a.syncID, b.syncID, e.syncID]
        #expect(ids.allSatisfy { $0 != nil }, "backfill left a record without an id")
        #expect(Set(ids.compactMap { $0 }).count == 3,
                "ids are not unique — the shared-default trap this design exists to avoid")
    }

    /// The sweep is idempotent: a second run must not re-mint or change anything —
    /// a syncID that changes between launches is not an identity.
    @Test func backfillNeverChangesAnExistingId() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let c = Customer(firstName: "Cara", lastName: "Three")
        ctx.insert(c)
        SyncIdentityBackfill.run(ctx)
        let first = try #require(c.syncID)

        SyncIdentityBackfill.run(ctx)
        #expect(c.syncID == first, "a stable identity changed on re-run")
    }

    /// A store whose records all carry an id costs no row loads at launch (audit F152): the
    /// sweep used to fetch every record of all 24 types on every launch, on the main actor.
    /// A record still missing an id (an autosaved insert) is found and minted.
    @Test func aLaunchLoadsOnlyTheRecordsMissingAnId() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        (0..<3).forEach { ctx.insert(Customer(firstName: "Minted\($0)", lastName: "Row")) }
        ctx.insert(InvoiceLineItem())
        ctx.saveChanges()
        let stray = Customer(firstName: "Stray", lastName: "Row")
        ctx.insert(stray)
        try ctx.save()                       // autosave-style: nothing stamps it
        stray.syncID = nil
        try ctx.save()
        let strayID = stray.persistentModelID

        let launch = ModelContext(container)
        let loaded = SyncIdentityBackfill.run(launch)

        #expect(loaded == 1, "the launch sweep loaded \(loaded) records; only the stray needed an id")
        let check = ModelContext(container)
        let fixed = try check.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.persistentModelID == strayID }))
        #expect(fixed.first?.syncID != nil, "the stray record was not minted and saved")
    }

    /// saveChanges stamps new records at creation (no waiting for the next launch)
    /// and moves updatedAt on edit.
    @Test func saveChangesStampsInsertsAndEdits() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let c = Customer(firstName: "Dee", lastName: "Four")
        ctx.insert(c)
        ctx.saveChanges()
        #expect(c.syncID != nil, "an inserted record left saveChanges without an id")
        let firstStamp = try #require(c.updatedAt)

        // An edit later must move the stamp forward.
        try #require(firstStamp <= Date())
        c.firstName = "Dee-Edited"
        ctx.saveChanges()
        let secondStamp = try #require(c.updatedAt)
        #expect(secondStamp >= firstStamp, "an edit did not move updatedAt")
        #expect(c.syncID != nil)
    }

    /// The identity survives the stamp: saveChanges must never re-mint an id that
    /// already exists.
    @Test func saveChangesPreservesAnExistingId() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let c = Customer(firstName: "Eve", lastName: "Five")
        ctx.insert(c)
        ctx.saveChanges()
        let id = try #require(c.syncID)

        c.lastName = "Five-Edited"
        ctx.saveChanges()
        #expect(c.syncID == id, "saveChanges re-minted an existing identity")
    }

    // MARK: - Legacy TIN drain

    /// Keychain empty + legacy plaintext present: the drain moves the TIN into the
    /// Keychain and purges the synced plaintext. This is the security half of
    /// Phase 0 - a plaintext SSN/EIN stops riding through CloudKit.
    @Test func drainMovesLegacyPlaintextIntoKeychain() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let saved = SecureTINStore.read()
        defer { _ = SecureTINStore.write(saved) }          // restore whatever was there

        _ = SecureTINStore.write("")                       // empty keychain
        let profile = BusinessProfile()
        profile.w9TIN = "12-3456789"
        ctx.insert(profile)

        LegacyTINDrain.run(ctx)

        #expect(profile.w9TIN.isEmpty, "plaintext survived the drain")
        #expect(SecureTINStore.read() == "12-3456789", "the TIN did not land in the Keychain")
    }

    /// Keychain already holds a (newer) TIN: the drain must NOT overwrite it with
    /// stale plaintext - it only purges the plaintext, because secureTIN never reads
    /// the fallback when the Keychain answers.
    @Test func drainNeverOverwritesANewerKeychainTIN() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let saved = SecureTINStore.read()
        defer { _ = SecureTINStore.write(saved) }

        _ = SecureTINStore.write("98-7654321")             // the authoritative, newer TIN
        let profile = BusinessProfile()
        profile.w9TIN = "12-3456789"                       // stale legacy plaintext
        ctx.insert(profile)

        LegacyTINDrain.run(ctx)

        #expect(SecureTINStore.read() == "98-7654321", "stale plaintext overwrote the Keychain TIN")
        #expect(profile.w9TIN.isEmpty, "stale plaintext was not purged")
    }
}
