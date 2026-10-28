//
//  GoldLifeEmailSignInSheet.swift — this app's thin wrapper around the FLEET
//  Gold Life flow (GoldLifeUI's GLGoldLifeEmailFlow, owner ruling 2026-08-30:
//  ONE flow, no segments, no login/create split — "Continue" is universal and
//  the first sign-in creates the Gold Life ID, exactly like Apple and Google).
//
//  This app has no type-your-ID front end yet (gl-business-api doesn't expose
//  the contact lookup), so the sheet is the email flow alone. The wrapper owns
//  only what MUST stay app-side: the NavigationStack, the house form skin and
//  keyboard dismissal INSIDE that stack, and the bar title — always
//  "Gold Life ID", a RESOLVED string through mbLoc (the live-language rule).
//

import SwiftUI
import GoldLifeUI

struct GoldLifeEmailSignInSheet: View {
    let auth: GoldLifeAuth

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                GLGoldLifeEmailFlow(adapter: auth)
            }
            // The house form treatment — skin plus keyboard dismissal — but NOT
            // `glFormBackground()`: its banner mount would print the DEVICE's
            // billing state (lapsed) inside a sheet where nobody is signed in.
            .glGroupedFormSkin()
            .dismissesKeyboardOnInteraction()
            .navigationTitle(GLScript.padded(mbLoc("Gold Life ID")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Gold Life ID"))), for: .scrollContent)
            .toolbar {
                // The house leading ✕ (MM's twin sheet closes the same way).
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The auth seam: what the package flow's buttons actually do in THIS app.
extension GoldLifeAuth: GLGateEmailAuthAdapter {

    func gateSendCode(email: String) async -> String? {
        await sendEmailCode(to: email)
    }

    func gateCompleteCodeSignIn(code: String, methodID: String) async -> Bool {
        await completeCodeSignIn(code: code, methodID: methodID)
    }

    func gateSendPhoneCode(phone: String) async -> String? {
        await sendPhoneCode(to: phone)
    }

    func gateCompletePhoneCodeSignIn(code: String, methodID: String) async -> Bool {
        await completeCodeSignIn(code: code, methodID: methodID)
    }

    var rememberedEmail: String {
        get { GateMemory.rememberedEmail }
        set { GateMemory.rememberedEmail = newValue }
    }

    var gateIsOnline: Bool { NetworkMonitor.shared.isConnected }

    // gateArmRememberedSignIn keeps the protocol's no-op default: this app's
    // law-30 arming happens inside landSignedIn, on every door equally.
}
