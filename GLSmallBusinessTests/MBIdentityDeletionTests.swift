//
//  MBIdentityDeletionTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 C17: the GoldLifeID package's deletion screen deletes the Gold Life ID and
//  then tells My Business (`GoldLifeIDConfig.onIdentityDeleted` → `MBIdentityDeletion.finish()`).
//  Before, nothing told it: the person stayed inside a signed-in My Business for an identity that
//  no longer existed, with the assistant's consent still on record. The teardown must end the
//  session and reset the consent, WITHOUT calling the server a second time.
//

import Foundation
import Testing
import GoldLifeCloud
import GoldLifeID
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MBIdentityDeletionTests {

    /// My Business hands the package its step-two hook at launch.
    @Test func theAppHandsThePackageItsTeardown() {
        #expect(GoldLifeID.shared.hasIdentityDeletedHook, "GLSmallBusinessApp.init must pass onIdentityDeleted")
    }

    /// The teardown the hook runs: signed out, the AI consent gone, the gate's remembered door
    /// held back. Everything global it touches is put back afterwards for the suites that follow.
    @Test func theTeardownSignsOutAndResetsTheAIConsent() async throws {
        let defaults = UserDefaults.standard
        let pendingWipe = defaults.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        let scope = SecureTINStore.accountScope
        let subs = SubscriptionManager.shared
        let entitlement = (source: subs.serverSource, entitled: subs.serverEntitled, answered: subs.serverAnswered,
                           tier: subs.tier, standing: subs.standing)
        defer {
            if let pendingWipe { defaults.set(pendingWipe, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { defaults.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            SecureTINStore.setAccountScope(scope)
            subs.setTestEntitlement(serverSource: entitlement.source, serverEntitled: entitlement.entitled,
                                    tier: entitlement.tier, standing: entitlement.standing,
                                    serverAnswered: entitlement.answered)
            MBIdentityDeletion.auth = nil
        }
        // A throwaway account, so the Keychain purge can't reach an item another suite keeps.
        SecureTINStore.setAccountScope("identity-deletion-\(UUID().uuidString)")

        let consent = MBAssistantSession.shared.consent
        consent.grant()
        #expect(consent.isGranted)

        let auth = GoldLifeAuth()
        MBIdentityDeletion.auth = auth
        await MBIdentityDeletion.finish()

        #expect(auth.state == .signedOut, "the person must land on the sign-in gate, not a signed-in shell")
        #expect(!consent.isGranted, "the AI consent goes with the session (law 74)")
        #expect(auth.consumeAutoDoorSuppression(), "the remembered door must not mint a new Gold Life ID straight away")
        #expect(!auth.isBusy)
    }
}
