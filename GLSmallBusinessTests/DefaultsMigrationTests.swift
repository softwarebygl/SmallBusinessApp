//
//  DefaultsMigrationTests.swift
//  GLSmallBusinessTests
//
//  The one-shot rename of legacy UserDefaults keys into the mb.* namespace
//  (DefaultsMigration.swift, law 26). Runs against an isolated suite so the host
//  app's own defaults are never touched.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct DefaultsMigrationTests {

    /// The rename table, pinned. `DefaultsMigration.renames` is private on purpose; if a
    /// key is added or dropped there, this list changes in the same turn — that is the point.
    private static let renames: [(old: String, new: String)] = [
        ("useCompanyLogo", "mb.useCompanyLogo"),
        ("scheduleWorkdaysMask", "mb.scheduleWorkdaysMask"),
        ("scheduleOneJobAtATime", "mb.scheduleOneJobAtATime"),
        ("requireBiometricUnlock", AppLockPrefs.key),
        ("didGrandfatherReceiptReviewLink_v1", "mb.didGrandfatherReceiptReviewLink_v1"),
        ("didBackfillJobsFirstClass_v1", "mb.didBackfillJobsFirstClass_v1"),
    ]
    /// Dead-feature residue: removed, never copied anywhere.
    private static let deleteOnly = "goldLifeIDPromptShown"

    /// A fresh, empty suite. `name` is what `persistentDomain(forName:)` reads back;
    /// the suite is wiped first and again when the test ends.
    private struct Suite {
        let defaults: UserDefaults
        let name: String
        func wipe() { defaults.removePersistentDomain(forName: name) }
        /// Exactly what this suite holds right now — nothing inherited from other domains.
        var stored: NSDictionary { NSDictionary(dictionary: defaults.persistentDomain(forName: name) ?? [:]) }
    }

    private func isolatedSuite() throws -> Suite {
        let name = "GLTests.DefaultsMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let suite = Suite(defaults: defaults, name: name)
        suite.wipe()
        return suite
    }

    @Test func everyOldKeyMovesToItsNewNameAndIsRemoved() throws {
        let suite = try isolatedSuite()
        defer { suite.wipe() }
        let defaults = suite.defaults

        // Distinct values per key, so a crossed wire (A's value under B's key) is visible.
        for (index, rename) in Self.renames.enumerated() {
            defaults.set(100 + index, forKey: rename.old)
        }
        defaults.set(true, forKey: Self.deleteOnly)

        DefaultsMigration.runIfNeeded(defaults)

        for (index, rename) in Self.renames.enumerated() {
            #expect(defaults.integer(forKey: rename.new) == 100 + index, "\(rename.old) → \(rename.new)")
            #expect(defaults.object(forKey: rename.old) == nil, "\(rename.old) should be gone")
        }
        #expect(defaults.object(forKey: AppLockPrefs.key) != nil,
                "the Face ID preference must survive under its new home")
        #expect(suite.stored.count == Self.renames.count, "only the new keys remain")
    }

    @Test func theDeleteOnlyKeyIsRemovedWithNothingWritten() throws {
        let suite = try isolatedSuite()
        defer { suite.wipe() }
        let defaults = suite.defaults
        defaults.set(true, forKey: Self.deleteOnly)
        #expect(defaults.object(forKey: Self.deleteOnly) != nil)

        DefaultsMigration.runIfNeeded(defaults)

        #expect(defaults.object(forKey: Self.deleteOnly) == nil)
        #expect(defaults.object(forKey: "") == nil, "an empty new key must not be written")
        #expect(suite.stored.count == 0, "a delete-only rename writes nothing at all")
    }

    @Test func anExistingNewKeyValueIsNotOverwritten() throws {
        let suite = try isolatedSuite()
        defer { suite.wipe() }
        let defaults = suite.defaults
        defaults.set(1, forKey: "useCompanyLogo")
        defaults.set(99, forKey: "mb.useCompanyLogo")   // already migrated (or freshly chosen)

        DefaultsMigration.runIfNeeded(defaults)

        #expect(defaults.integer(forKey: "mb.useCompanyLogo") == 99)
        #expect(defaults.object(forKey: "useCompanyLogo") == nil, "the stale old key still goes away")
    }

    @Test func aSecondRunIsANoOp() throws {
        let suite = try isolatedSuite()
        defer { suite.wipe() }
        let defaults = suite.defaults
        for (index, rename) in Self.renames.enumerated() {
            defaults.set(200 + index, forKey: rename.old)
        }
        defaults.set(true, forKey: Self.deleteOnly)

        DefaultsMigration.runIfNeeded(defaults)
        let afterFirst = suite.stored
        #expect(afterFirst.count == Self.renames.count)

        DefaultsMigration.runIfNeeded(defaults)
        let afterSecond = suite.stored
        #expect(afterSecond == afterFirst, "the second run must change nothing")
        for (index, rename) in Self.renames.enumerated() {
            #expect(defaults.integer(forKey: rename.new) == 200 + index)
            #expect(defaults.object(forKey: rename.old) == nil)
        }
    }

    /// Audit 2026-10-03 F38: the retired per-app profile cache (name, phone, home address and
    /// photo) is removed on the first launch of this version, whoever is signed in or not.
    /// Gold Life ID owns that record now (law 48), and its own cache follows the wipe rules.
    @Test func theRetiredProfileCacheIsRemoved() throws {
        let suite = try isolatedSuite()
        defer { suite.wipe() }
        let defaults = suite.defaults
        defaults.set(["first_name": "Former", "phone": "5550100", "address_city": "Miami",
                      "avatar": "AAEC"], forKey: "gl_profile_cache")

        DefaultsMigration.runIfNeeded(defaults)

        #expect(defaults.object(forKey: "gl_profile_cache") == nil)
        #expect(suite.stored.count == 0, "nothing is copied anywhere")
    }
}
