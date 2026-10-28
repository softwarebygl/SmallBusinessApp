//
//  MBSessionPurgeTests.swift
//  GLSmallBusinessTests
//
//  Law 13 (owner ruling 2026-09-26): signing out, a session Stytch ended, and a launch with no
//  session wipe My Business's local copy through GoldLifeCloud's ONE `GLSessionWipe`; the AI
//  consent goes with it; the Menu warns first when changes haven't been backed up. And the
//  server is the store of record: the next sign-in pulls everything back.
//

import Foundation
import SwiftData
import Testing
import GoldLifeCloud
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MBSessionPurgeTests {
    private static var retained: [ModelContainer] = []

    private static func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MBPurgeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func consent() throws -> GLAIConsent {
        let defaults = try #require(UserDefaults(suiteName: "MBPurgeTests.\(UUID().uuidString)"))
        return GLAIConsent(key: "mb.ai.consent.version", requiredVersion: 3, defaults: defaults)
    }

    @Test("every way a session ends runs My Business's registered step")
    func theStepIsRegisteredWithTheSharedWipe() throws {
        #expect(GLSessionWipe.shared.stepNames.contains(MBSessionPurge.stepName),
                "registered at launch (GLSmallBusinessApp.init)")
        let auth = try #require(GLSource.file("Services/GoldLifeAuth.swift"))
        for exit in ["signOut", "handleSessionExpired", "deleteAccount"] {
            let body = try #require(GLSource.functionBody(exit, in: auth), "\(exit) not found")
            #expect(body.contains("GLSessionWipe.shared.run(.sessionEnded)"), "\(exit) must wipe (law 13)")
            #expect(!body.contains("endSessionKeepingCache"), "\(exit) still keeps the cache")
        }
        let resolve = try #require(GLSource.functionBody("resolve", in: auth))
        #expect(resolve.contains("GLSessionWipe.shared.run(.launchedWithoutSession)"),
                "a launch with no session wipes too")
        #expect(resolve.contains("if resolved { GLSessionWipe.shared.run(.launchedWithoutSession) }"),
                "only on a trusted 'no session' — a locked Keychain also reads as none")
        let app = try #require(GLSource.file("GLSmallBusinessApp.swift"))
        #expect(app.contains("MBSessionPurge.registerWipe()"))
    }

    @Test("the wipe removes every per-person store, generated documents and the AI consent")
    func theWipeRemovesTheLocalCopy() throws {
        let saved = UserDefaults.standard.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
        }
        let root = Self.tempRoot()
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let w9 = temporary.appendingPathComponent("Generated-W-9", isDirectory: true)
        try FileManager.default.createDirectory(at: w9, withIntermediateDirectories: true)
        try Data("123-45-6789".utf8).write(to: w9.appendingPathComponent("W-9.pdf"))

        let container = UserScopedStore.shared.container(for: "purge-\(UUID().uuidString)", appSupport: root)
        Self.retained.append(container)
        container.mainContext.autosaveEnabled = false
        container.mainContext.insert(Customer(firstName: "Maria", lastName: "Lopez"))
        container.mainContext.saveChanges()
        let consent = try Self.consent()
        consent.grant()

        MBSessionPurge.run(.sessionEnded, store: .shared, consent: consent, appSupport: root, temporary: temporary)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Stores").path),
                "every per-person store folder is gone")
        #expect(UserScopedStore.shared.activeMainContext == nil, "the live store is dropped")
        #expect((try FileManager.default.contentsOfDirectory(atPath: temporary.path)).isEmpty,
                "generated documents (a W-9 with a full Tax ID) are gone")
        #expect(FileManager.default.fileExists(atPath: temporary.path), "the folder itself is iOS's")
        #expect(!consent.isGranted, "the next person on this iPhone is asked again (law 74)")
        #expect(UserDefaults.standard.bool(forKey: UserScopedStore.pendingDefaultStoreWipeKey),
                "the legacy default store goes at the next launch")
    }

    @Test("the server is the store of record: after the wipe, the next sign-in pulls it all back")
    func everythingComesBackAtTheNextSignIn() throws {
        let saved = UserDefaults.standard.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
        }
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = "purge-\(UUID().uuidString)"
        let id = UUID()
        // What the server holds for this account (gl-business-api is the store of record).
        let serverRows = [SyncFix.liveRow(id, type: "customer", version: 3, seq: 7,
                                          payload: ["firstName": "Maria", "lastName": "Lopez"])]

        let before = UserScopedStore.shared.container(for: person, appSupport: root)
        Self.retained.append(before)
        _ = SyncFix.store(before).applyChanges(serverRows)
        #expect(SyncFix.loadCustomer(id, in: before)?.firstName == "Maria")

        MBSessionPurge.run(.sessionEnded, store: .shared, consent: try Self.consent(),
                           appSupport: root, temporary: root.appendingPathComponent("tmp"))

        // Signing in again mounts an EMPTY store for the same person…
        let after = UserScopedStore.shared.container(for: person, appSupport: root)
        Self.retained.append(after)
        #expect(SyncFix.customerCount(after) == 0, "the wipe really emptied this iPhone")
        // …and the first pull brings the account back, same record, same id.
        _ = SyncFix.store(after).applyChanges(serverRows)
        let back = try #require(SyncFix.loadCustomer(id, in: after))
        #expect(back.firstName == "Maria" && back.lastName == "Lopez" && back.syncID == id)
        #expect(SyncFix.storedVersion(id, in: after) == 3)
        UserScopedStore.shared.wipeOnAccountDeletion(appSupport: root)
    }

    @Test("the sign-out alert warns only when changes would be lost, in the app's language")
    func theWarningCountsTheOutbox() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        #expect(MBSessionPurge.unsyncedChangeCount(in: context) == 0)
        #expect(MBSessionPurge.unsyncedChangeCount(in: nil) == 0)
        #expect(MBSessionPurge.signOutMessage(unsyncedChanges: 0) == mbLoc("Are you sure you want to sign out of My Business?"))
        SyncFix.outbox(record: UUID(), type: "customer", in: context)
        SyncFix.outbox(record: UUID(), type: "invoice", in: context)
        #expect(MBSessionPurge.unsyncedChangeCount(in: context) == 2)

        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en
        #expect(MBSessionPurge.signOutMessage(unsyncedChanges: 1)
                == "1 change hasn’t been backed up yet. If you sign out now, it’s lost. Connect to the internet first to keep it.")
        #expect(MBSessionPurge.signOutMessage(unsyncedChanges: 2).hasPrefix("2 changes haven’t been backed up yet."))
        MBLocalization.shared.language = .es
        #expect(MBSessionPurge.signOutMessage(unsyncedChanges: 2).hasPrefix("2 cambios aún no tienen copia de seguridad."))
    }

    @Test("account deletion wipes rememberedEmail unconditionally (Law 73)")
    func accountDeletionWipesRememberedEmail() {
        GateMemory.rememberEnabled = true
        GateMemory.rememberedEmail = "adrian@softwarebygl.com"
        #expect(!GateMemory.rememberedEmail.isEmpty)

        GateMemory.rememberedEmail = ""
        GateMemory.clearDoor()

        #expect(GateMemory.rememberedEmail.isEmpty)
        #expect(UserDefaults.standard.string(forKey: "gl_gate_remembered_email") == nil)
        #expect(UserDefaults.standard.string(forKey: "gl.gate.rememberedEmail") == nil)
    }
}
