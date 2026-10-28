//
//  StripeTokenScopeProofTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F2, visual proof on the simulator: owner A connects Stripe on this iPhone and
//  signs out; person B signs in. Get Paid by Card must show B's own state, never "Connected — ready
//  to get paid" on A's token. Renders the real StripeConnectScreen through the shared harness and
//  writes PNGs. Runs ONLY when MB_PROOF_DIR is set (it moves the process-wide signed-in scope).
//

import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import GLSmallBusiness

@Suite(.serialized, .enabled(if: !(ProcessInfo.processInfo.environment["MB_PROOF_DIR"] ?? "").isEmpty))
@MainActor
struct StripeTokenScopeProofTests {

    private func capture(_ name: String, container: ModelContainer) {
        GLTestHost.render(StripeConnectScreen(), container: container, scheme: .light) { controller in
            guard let window = controller.view.window,
                  let dir = ProcessInfo.processInfo.environment["MB_PROOF_DIR"], !dir.isEmpty else {
                Issue.record("\(name): nothing to capture")
                return
            }
            for _ in 0..<8 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 3
            let png = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    @Test func personBAfterOwnerASignsOutNeverSeesAsStripeAccount() throws {
        let savedScope = SecureTINStore.accountScope
        defer { SecureTINStore.setAccountScope(savedScope) }
        let saved = UserDefaults.standard.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
        }
        let ownerA = "proof-owner-a", personB = "proof-person-b"
        defer {
            StripeInstallTokenStore.delete(for: ownerA)
            StripeInstallTokenStore.delete(for: personB)
        }
        // Nothing from an older build waiting on this simulator (it would be settled first).
        StripeInstallTokenStore.deleteLegacy()
        UserDemoMode.shared.isDemoActive = false

        // Owner A connected Stripe on this iPhone.
        SecureTINStore.setAccountScope(ownerA)
        #expect(StripeInstallTokenStore.save(.init(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_A"),
                                             for: ownerA))
        let worldA = try TestStore.demoWorld()
        worldA.profile.stripeConnectedAccountId = "acct_A"
        worldA.profile.stripeChargesEnabled = true
        capture("F2-1-ownerA-connected", container: worldA.container)

        // A signs out: the session wipe runs with A's account.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StripeTokenScopeProof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "StripeTokenScopeProof.\(UUID().uuidString)"))
        MBSessionPurge.run(.sessionEnded, store: .shared,
                           consent: .init(key: "mb.ai.consent.version", requiredVersion: 3, defaults: defaults),
                           appSupport: root, temporary: root.appendingPathComponent("tmp"),
                           stripeTokenScope: ownerA)
        #expect(StripeInstallTokenStore.load(for: ownerA) == nil)

        // B signs in with a fresh business: "Connect Stripe account".
        SecureTINStore.setAccountScope(personB)
        let worldB = try TestStore.demoWorld()
        worldB.profile.stripeConnectedAccountId = ""
        worldB.profile.stripeChargesEnabled = false
        capture("F2-2-personB-fresh-connect", container: worldB.container)

        // B's business connected Stripe elsewhere (acct_B, charges on), and A's token is still on this
        // device (A signed out on an older build): B is told to reconnect, never "ready to get paid".
        #expect(StripeInstallTokenStore.save(.init(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_A"),
                                             for: ownerA))
        worldB.profile.stripeConnectedAccountId = "acct_B"
        worldB.profile.stripeChargesEnabled = true
        capture("F2-3-personB-acctB-reconnect", container: worldB.container)
    }
}
