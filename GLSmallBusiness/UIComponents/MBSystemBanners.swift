//
//  MBSystemBanners.swift — My Business's state for the ONE slot every standing notice shares.
//
//  The slot itself — its order (sample data, offline, lapsed), its suppressions in sample data,
//  its cards and its chrome — is GoldLifeUI's `GLSystemBannerStack` (moved there by audit
//  2026-10-03 F158). What stays here is
//  only what is My Business's: whether sample data is on, the connection, the lapse, the Exit
//  action and the paywall Reactivate opens.
//
//  MOUNTED PER SCREEN, INSIDE the navigation context, never around the navigation stacks:
//  build 44's outside mount painted its opaque inset straight over the toolbar row.
//

import SwiftUI
import GoldLifeUI

extension View {
    /// Attach to a SCREEN's content (or ride in via the house background modifiers) — inside
    /// its NavigationStack, so the toolbar stays above.
    ///
    /// `capsContent` (default true) also holds the screen's list/form to the fleet's 640 pt
    /// readable column (`glReadableWidth`), so on a wide screen (iPad, iPhone landscape) the
    /// banner card and the rows/cards under it share the same two edges (audit C66). Only the
    /// full-width surfaces (the iPad split panes, Calendar, Stats) pass `false`.
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

/// Internal (not private) because the assistant screen mounts it by hand: the chat screen owns
/// its own `safeAreaInset` and asks for the `.assistant` offline sentence — the SAME single card
/// in the SAME slot, never a second one (law 5).
struct MBSystemBannerInset: View {
    /// Which sentence the stack's one offline card says.
    var offlineVariant: GLOfflineBanner.Variant = .standard

    @ObservedObject private var demo = UserDemoMode.shared
    /// The singleton rather than the environment, for MBShareLink's reason: hosts render in
    /// previews and test harnesses that inject nothing.
    @State private var subscription = SubscriptionManager.shared
    /// Local, so Reactivate presents the paywall from the slot's own context.
    @State private var showingPaywall = false

    var body: some View {
        GLSystemBannerStack(
            isSampleData: demo.isDemoActive,
            isOffline: !NetworkMonitor.shared.isConnected,
            lapsed: subscription.isLapsed ? .entered : nil,
            offlineVariant: offlineVariant,
            // The lapse is announced in the app's chosen language (audit 2026-10-03 F55).
            announcementLocale: MBLocalization.currentLocale,
            onExitSample: { demo.exitDemo() },
            onResubscribe: { showingPaywall = true })
        .paywallSheet(isPresented: $showingPaywall)
    }
}
