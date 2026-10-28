import SwiftUI
import GoldLifeUI

struct SignInScreen: View {
    let auth: GoldLifeAuth

    @ObservedObject private var demo = UserDemoMode.shared
    @State private var showingPrivacy = false
    @State private var showingGoldLife = false
    @State private var rememberMe = GateMemory.rememberEnabled
    @State private var autoRanDoor = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GLGateScreen(
            wordmark: "My Business",
            isBusy: auth.isBusy,
            isOffline: !NetworkMonitor.shared.isConnected,
            errorMessage: auth.errorMessage,
            rememberDoor: $rememberMe,
            onGoldLifeSignIn: {
                auth.errorMessage = nil
                showingGoldLife = true
            },
            onSampleData: {
                auth.errorMessage = nil
                demo.startDemo()
            },
            onPrivacyPolicy: { showingPrivacy = true }
        )
        .mbFitOrScroll(alignment: .center)
        .sheet(isPresented: $showingPrivacy) { PrivacyPolicySheet() }
        .sheet(isPresented: $showingGoldLife) { GoldLifeEmailSignInSheet(auth: auth) }
        .task { await autoContinueIfRemembered() }
        .onChange(of: rememberMe) { _, newValue in
            GateMemory.rememberEnabled = newValue
        }
        .alert(mbLoc("Couldn’t open sample data"),
               isPresented: Binding(get: { demo.seedError != nil },
                                    set: { if !$0 { demo.seedError = nil } })) {
            Button(mbLoc("OK"), role: .cancel) {}
        } message: {
            Text(mbLoc("Something went wrong preparing the sample business. Try again, or restart the app."))
        }
    }

    private func autoContinueIfRemembered() async {
        guard !autoRanDoor else { return }
        autoRanDoor = true
        // Waits for a sign-out or an expiry still tearing the last session down (audit
        // 2026-10-03 F62): a door run mid-teardown had its new session revoked and its new
        // store wiped by the old teardown. No after a chosen sign-out (law 30).
        guard await auth.mayRunRememberedDoor(), !Task.isCancelled else { return }
        guard let door = GateMemory.rememberedDoor,
              auth.state == .signedOut, !auth.isBusy,
              NetworkMonitor.shared.isConnected else { return }
        switch door {
        case .apple, .google, .gold:
            // Do NOT auto-pop modal on cold launch (feedback AGg9v-nfgb_gZP5VBHAteLc).
            // User taps "Continue with Gold Life ID" to open pre-filled sheet.
            break
        }
    }
}
