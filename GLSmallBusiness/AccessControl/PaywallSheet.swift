//
//  PaywallSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The upgrade paywall, shown as a sheet the moment a free user reaches a FreeTier cap, and from
//  Settings → Upgrade. Uses Apple's compliant `SubscriptionStoreView` (title / length / price plus
//  Terms-of-Use and Privacy-Policy links), with Restore Purchases and Apple offer-code redemption.
//  When there is nothing to sell, a branded retry state replaces the store so the user isn't left
//  staring at an empty sheet — worded from the REASON there is nothing (unreachable vs.
//  reached-but-empty), never assuming the connection. A gold grabber tops the sheet per the app's
//  drag-indicator convention. Everything the user already created stays usable behind this sheet —
//  subscribing only unlocks creating more.
//
//  THREE THINGS THIS SHEET MUST NEVER DO AGAIN (audit, 2026-09-04):
//  - Stay up after a SUCCESSFUL purchase. `.onInAppPurchaseCompletion` dismisses on success;
//    without it the person paid, was left staring at the sheet re-rendering as Apple's "current
//    plan" screen, and the action they came here to perform was silently abandoned.
//  - Render an empty store. "Loaded" is not the same as "has something to sell": handing
//    SubscriptionStoreView an id set the storefront can't fill drew a sheet with no Retry, no
//    Restore and no close control on it — a dead end with the person's blocked action behind it.
//  - Swallow a failed Restore. It was `try? await AppStore.sync()`: offline, the button spun and
//    did nothing, forever, with no sentence saying why. Every failure is an alert AND a log line.
//

import GoldLifeUI
import OSLog
import StoreKit
import SwiftUI

/// Which doorway opened the paywall — the header must be true for whichever it
/// was. `.atCap` is the default because every cap-refusal site presents it that
/// way; Settings' voluntary Upgrade passes `.upgrade`. Lapsed is not a case
/// here: it outranks those two and is derived from the subscription itself, so
/// no call site can present a lapsed person with the wrong claim.
///
/// `.assistant` is kept for compatibility; the AI Assistant is 100% free via BYOK
/// (GoldLifeAI), so Gold Life sells no AI subscription.
enum PaywallContext {
    case atCap, upgrade, assistant
}

struct PaywallSheet: View {
    var context: PaywallContext = .atCap
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subs

    @State private var retrying = false
    @State private var restoring = false
    /// The outcome of a Restore tap in the fallback state — nil = no alert. The same shape
    /// SubscriptionScreen uses, because it is the same two sentences from the same two calls.
    @State private var restoreAlert: RestoreAlert?

    private struct RestoreAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// What the sheet is actually showing. Three answers rather than a raw `loadState`, because
    /// "loaded" is not the same as "has something to sell" — and the two empty cases are different
    /// sentences, only one of which is allowed to mention the person's connection.
    enum Presentation { case store, unreachable, nothingToSell }

    private var presentation: Presentation {
        Self.presentation(loadState: subs.loadState, loadedIDs: Set(subs.products.map(\.id)),
                          selling: Self.productIDs(for: context))
    }

    /// "Has something to sell" means something THIS sheet sells: a storefront that hasn't loaded
    /// the products this sheet sells must never hand SubscriptionStoreView an id set it can't fill
    /// — the empty, close-less sheet this file promises never to draw again.
    static func presentation(loadState: SubscriptionManager.LoadState, loadedIDs: Set<String>,
                             selling: [String]) -> Presentation {
        let hasSomething = !loadedIDs.isDisjoint(with: selling)
        switch loadState {
        case .loading:
            // The store view draws its own loading UI; short-circuiting it here would flash an
            // intermediate loader. Wait until the store *says* it's ready.
            return .store
        case .loaded, .unavailable:
            return hasSomething ? .store : .nothingToSell
        case .failed:
            // A retry that fails AFTER a good load keeps the products it already has, so there is
            // still a real store to show.
            return hasSomething ? .store : .unreachable
        }
    }

    /// The plans this sheet sells: the AI Assistant is 100% free via BYOK (GoldLifeAI), so
    /// `.assistant` sells nothing (`SubscriptionManager.aiProductIDs` is empty) and `.atCap` /
    /// `.upgrade` sell only the Unlimited (Pro) plans.
    static func productIDs(for context: PaywallContext) -> [String] {
        switch context {
        case .assistant:
            return []
        case .atCap, .upgrade:
            // AI Assistant is 100% free via BYOK (GoldLifeAI); .atCap and .upgrade sell only Pro.
            return SubscriptionManager.shared.entitlingProductIDs.keys
                .filter { !SubscriptionManager.aiProductIDs.contains($0) }
                .sorted()
        }
    }

    private var storeUnavailable: Bool { presentation != .store }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(GLTheme.accentFill.opacity(0.6))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 2)

            switch presentation {
            case .unreachable:
                storeProblem(for: .unreachable)
            case .nothingToSell:
                // The store answered — it just isn't offering this subscription. Nothing here is
                // wrong with the person's connection, so nothing here may tell them to go check it.
                storeProblem(for: .nothingToSell)
            case .store:
                subscriptionStore
            }
        }
        .overlay(alignment: .topTrailing) {
            // SubscriptionStoreView supplies its own close button — only the fallback state needs
            // ours, otherwise the paywall shows two X's stacked in the corner. Driven by
            // `storeUnavailable`, so EVERY state that isn't the store carries a way out.
            if storeUnavailable {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(GLTheme.textSecondary)
                        .padding(12)
                }
                .accessibilityLabel("Close")
            }
        }
        // `loadProducts()` runs ONCE, in SubscriptionManager's init: an app launched with no
        // connection pinned that failure for the whole session, so the paywall stayed broken until
        // relaunch no matter how many times it was opened. Re-ask on every open instead.
        .task {
            if storeUnavailable { await subs.loadProducts() }
        }
        .alert(restoreAlert?.title ?? "", isPresented: Binding(
            get: { restoreAlert != nil },
            set: { if !$0 { restoreAlert = nil } }
        ), presenting: restoreAlert) { _ in
            Button("OK", role: .cancel) { restoreAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .glAppearance(colorScheme)
    }

    // MARK: - The store

    private var subscriptionStore: some View {
        SubscriptionStoreView(productIDs: Self.productIDs(for: context)) {
            header
        }
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .redeemCode)   // Apple offer-code redemption (compliant)
        // Law 52: the policy links open the app's OWN in-app legal sheets, not Safari. (The
        // `url:` overload hands the address to the system browser.)
        .subscriptionStorePolicyDestination(for: .privacyPolicy) { PrivacyPolicySheet() }
        .subscriptionStorePolicyDestination(for: .termsOfService) { TermsOfUseSheet() }
        // Without this the sheet stayed up after a successful purchase, re-rendering as Apple's
        // "current plan" screen while the action the person came here to perform was never resumed.
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success) = result { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            GLScriptText("My Business", size: 56)
                .foregroundStyle(GLTheme.accentFill)
            // Both sentences take the height they need, at every text size: the store's header
            // slot used to cut the subline after two lines ("…Every…", QA 2026-10-03 L17).
            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subline)
                .font(.callout)
                .foregroundStyle(GLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    static func headline(context: PaywallContext, isLapsed: Bool) -> String {
        switch context {
        case .atCap:
            return isLapsed ? mbLoc("Your subscription ended") : mbLoc("You’ve reached the free limit")
        case .upgrade, .assistant:
            return isLapsed ? mbLoc("Your subscription ended") : mbLoc("Subscribe to My Business")
        }
    }

    static func subline(context: PaywallContext = .atCap, isLapsed: Bool) -> String {
        if isLapsed {
            return mbLoc("Reactivate to add and change records again. Everything you created is still here and stays yours.")
        }
        return mbLoc("Subscribe to add unlimited customers, estimates, invoices, jobs, and receipts. Everything you’ve already created stays yours either way.")
    }

    var headline: String {
        Self.headline(context: context, isLapsed: subs.isLapsed)
    }

    var subline: String {
        Self.subline(context: context, isLapsed: subs.isLapsed)
    }

    // MARK: - Nothing to sell

    /// Shown when there is no product to sell — the house §10 failure contract (a symbol, a
    /// sentence, and Try Again), never an empty store. Sentences come from GoldLifeUI's
    /// `GLStoreProblem`.
    private func storeProblem(for problem: GLStoreProblem) -> some View {
        var title = problem.title()
        title.locale = MBLocalization.shared.locale
        var message = problem.message()
        message.locale = MBLocalization.shared.locale
        return storeProblem(symbol: problem.symbol, title: String(localized: title), message: String(localized: message))
    }

    private func storeProblem(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            header
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(message)
            } actions: {
                Button {
                    retrying = true
                    Task { await subs.loadProducts(); retrying = false }
                } label: {
                    // The spinner joins; the words stay (law 16 — a bare-spinner
                    // label loses its VoiceOver name mid-flight).
                    HStack(spacing: 8) {
                        if retrying { ProgressView().tint(GLTheme.onAccent) }
                        Text("Try Again").fontWeight(.semibold)
                    }
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(GLTheme.accentFill)
                .disabled(retrying)   // a second tap mid-flight would stack loadProducts tasks

                Button {
                    restore()
                } label: {
                    HStack(spacing: 8) {
                        if restoring { ProgressView() }
                        Text("Restore Purchases")
                    }
                }
                .font(.callout)
                .disabled(restoring)
            }
        }
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical)
        // Scroll when it doesn't fit: at accessibility text sizes the header, the message and both
        // buttons overran the sheet and hid Try Again / Restore below the fold — a dead end in the
        // exact state where those two buttons are the only way forward. (The store path is safe:
        // SubscriptionStoreView scrolls itself.)
        .mbFitOrScroll(alignment: .top)
    }

    /// Restore Purchases from the fallback state — the one place on this sheet where the person is
    /// told what happened, since the fallback has no StoreKit chrome of its own to tell them.
    private func restore() {
        restoring = true
        Task {
            defer { restoring = false }
            do {
                try await AppStore.sync()
                // A restore that lands is usually also the moment the store became reachable —
                // re-ask, so success doesn't leave the person parked on the failure state.
                await subs.loadProducts()
                restoreAlert = RestoreAlert(
                    title: mbLoc("Purchases restored"),
                    message: mbLoc("Your purchases have been restored. If you have an active subscription, it’s now active on this device."))
            } catch {
                // nil message = the person backed out of the App Store's own sign-in sheet. That is
                // a decision, not a failure: no alert, and nothing to log.
                guard let message = SubscriptionActions.restoreFailureMessage(for: error) else { return }
                restoreAlert = RestoreAlert(title: mbLoc("Couldn’t restore purchases"), message: message)
                // Resolved to a local first: the log interpolation takes an escaping autoclosure,
                // and evaluating a MainActor-isolated call inside one is exactly the shape Swift 6
                // rejects.
                let reason = Self.restoreLogReason(for: error)
                Logger.access.error(
                    "paywall restore failed: reason=\(reason, privacy: .public) surface=paywall_fallback")
            }
        }
    }

    /// The developer half of a failed restore, named from the CLOSED StoreKitError set the
    /// user-facing mapping already switches on — so the line carries a stable word and never an
    /// error string a person's own data could reach.
    nonisolated static func restoreLogReason(for error: Error) -> String {
        guard let storeKitError = error as? StoreKitError else { return "other" }
        switch storeKitError {
        case .userCancelled: return "user_cancelled"
        case .networkError: return "network"
        case .notAvailableInStorefront: return "not_in_storefront"
        default: return "other"
        }
    }
}

extension View {
    /// Presents the upgrade paywall as a sheet when `isPresented` becomes true.
    /// `onDismiss` runs when the sheet closes — a purchase made in it has landed by then, so a
    /// screen gated on an entitlement can re-read it instead of waiting for the next appear.
    func paywallSheet(isPresented: Binding<Bool>, context: PaywallContext = .atCap,
                      onDismiss: (() -> Void)? = nil) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { PaywallSheet(context: context) }
    }
}
