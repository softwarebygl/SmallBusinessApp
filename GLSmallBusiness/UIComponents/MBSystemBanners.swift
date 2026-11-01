//
//  MBSystemBanners.swift — My Business's state for the ONE slot every standing notice shares.
//

import SwiftUI
import GoldLifeUI
import GoldLifeID
import GoldLifeCloud

extension View {
    func mbSystemBanners(capsContent: Bool = true) -> some View {
        Group {
            if capsContent {
                glReadableWidth()
            } else {
                self
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { MBSystemBannerInset() }
    }
}

struct MBSystemBannerInset: View {
    var offlineVariant: GLOfflineBanner.Variant = .standard

    @ObservedObject private var demo = UserDemoMode.shared
    @State private var subscription = SubscriptionManager.shared
    @State private var vaultUnlock = GLVaultUnlockCoordinator.shared
    @State private var showingPaywall = false
    @State private var showingVaultUnlock = false

    var body: some View {
        GLSystemBannerStack(
            isSampleData: demo.isDemoActive,
            isOffline: !NetworkMonitor.shared.isConnected,
            lapsed: subscription.isLapsed ? .entered : nil,
            isVaultLocked: vaultUnlock.isVaultLocked,
            offlineVariant: offlineVariant,
            announcementLocale: MBLocalization.currentLocale,
            onExitSample: { demo.exitDemo() },
            onResubscribe: { showingPaywall = true },
            onUnlockVault: { showingVaultUnlock = true }
        )
        .paywallSheet(isPresented: $showingPaywall)
        .goldLifeVaultUnlockSheet(isPresented: $showingVaultUnlock)
    }
}
