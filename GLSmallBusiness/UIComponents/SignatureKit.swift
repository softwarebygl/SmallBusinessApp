//
//  SignatureKit.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  Building blocks for the saved signature: a PencilKit drawing canvas, helpers that turn a
//  drawing / typed name / imported photo into a transparent PNG, and a Face ID gate.

import SwiftUI
import PencilKit
import LocalAuthentication
import GoldLifeDocuments

// MARK: - Canvas & Rendering from GoldLifeDocuments (law 87, Zero Duplication)

public typealias SignatureCanvas = GLSignatureCanvas
public typealias SignatureRender = GLSignatureRender

// MARK: - Biometric gate

enum BiometricGate {

    /// IN-SESSION access to data the launch lock already stands in front of.
    ///
    /// Owner ruling 2026-08-31: "The only time Face ID is ever required is
    /// whenever you launch the app in order to sign in. If we're in, we're in."
    /// Every prompt this replaces defended against exactly one adversary — a
    /// person holding this unlocked phone right now — and the launch lock
    /// already answers that. Re-asking two seconds later proves nothing and
    /// trains people to swat the sheet away, which is its own security cost.
    ///
    /// It is NOT an unconditional `true`: if the person has turned the launch
    /// lock OFF, this session was never proven, so the inner gates go back to
    /// doing the work. Remove the front door and the inner doors start
    /// locking again — the app is never left with no floor at all.
    @MainActor
    static func authenticateInSession(reason: String) async -> Bool {
        if UserDefaults.standard.bool(forKey: AppLockPrefs.key) { return true }
        return await authenticate(reason: reason)
    }

    /// Prompts for Face ID / Touch ID (with passcode fallback) before revealing or applying the
    /// signature. Returns true on success. If the device has no biometrics or passcode set, there
    /// is nothing to gate against, so access is allowed rather than permanently blocked.
    @MainActor
    static func authenticate(reason: String) async -> Bool {
        // Demo/UI-test runs (DEBUG + `-demoMode`) can't drive the system biometric sheet, so bypass
        // it for deterministic automation. Release builds compile this to `false` and always prompt.
        if DemoMode.isActive { return true }
        let context = LAContext()
        context.localizedFallbackTitle = mbLoc("Use Passcode")
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}
