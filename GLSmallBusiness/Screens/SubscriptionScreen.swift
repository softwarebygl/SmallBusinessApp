//
//  SubscriptionScreen.swift
//  GLSmallBusiness
//
//  Menu ▸ Subscription: which plan this account is on, what it includes, and
//  when it renews or expires — rendered through the FLEET skeleton
//  (GLSubscriptionScreenContent; owner ruling 2026-08-30: "pick the best one
//  and move it into the Gold Life swift package"). Purchasing still runs
//  through the one paywall, so the point-of-purchase disclosure stays in a
//  single place.
//
//  Status honesty rules, same as everywhere: renewal facts come from
//  StoreKit's LOCAL entitlements so the screen works offline; nothing here
//  hardcodes a price — with no loaded product the price line simply doesn't
//  render; while status is unknown nothing claims "Not subscribed".
//

import GoldLifeUI
import SwiftUI
import StoreKit
import GoldLifeUI

struct SubscriptionScreen: View {
    @Environment(SubscriptionManager.self) private var subscription
    @State private var managingSubscription = false
    @State private var redeemingCode = false
    @State private var restoring = false
    @State private var showingPaywall = false
    @State private var subscriptionAlert: SubscriptionAlert?   // result of a restore / redeem; nil = no alert

    /// StoreKit's local word on the active term, read on appear (offline-safe).
    @State private var renewal = GLSubscriptionRenewalFacts()

    /// A restore / redeem outcome. Carries its own TITLE so the alert says what happened
    /// ("Purchases restored" / "Couldn't restore purchases") instead of a bare noun.
    private struct SubscriptionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Form {
            GLSubscriptionScreenContent(
                plan: GLSubscriptionPlanData(
                    planTitle: planTitle,
                    statusLabel: statusLabel,
                    statusHighlighted: subscription.isSubscribed || subscription.isVip,
                    priceLine: priceLine,
                    statusDetail: statusDetail),
                benefitsHeader: mbLoc("Unlimited includes"),
                benefits: [
                    // Only what subscribing REMOVES: the free caps (FreeTier). Stripe payments, payroll
                    // and backup are free for everyone (law 88; QA 2026-10-03 F75).
                    mbLoc("Unlimited customers, estimates, invoices, jobs, and receipts"),
                    mbLoc("More than 2 employees and 2 subcontractors"),
                ],
                // The degrade-don't-punish promise is part of the pitch (owner pick 4(c): the
                // first sentence is the truth about everything not listed).
                benefitsFooter: mbLoc("Everything else stays free. If you ever cancel, everything you created stays yours to read."),
                actions: { actions }
            )
        }
        .glFormBackground()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Subscription"))), for: .scrollContent)   // breathing room below the large title's descenders
        .navigationTitle(GLScript.padded(mbLoc("Subscription")))
        .toolbarTitleDisplayMode(.large)
        .paywallSheet(isPresented: $showingPaywall, context: .upgrade)
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .offerCodeRedemption(isPresented: $redeemingCode) { result in
            if case .failure(let error) = result {
                subscriptionAlert = SubscriptionActions.redeemFailureMessage(for: error).map {
                    SubscriptionAlert(title: mbLoc("Couldn’t redeem that code"), message: $0)
                }
            }
        }
        .alert(subscriptionAlert?.title ?? "", isPresented: Binding(
            get: { subscriptionAlert != nil },
            set: { if !$0 { subscriptionAlert = nil } }
        ), presenting: subscriptionAlert) { _ in
            Button("OK", role: .cancel) { subscriptionAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .task { await loadRenewalFacts() }
        // A restore (or purchase) completing while this screen is up flips the
        // badge live — the renewal-date line must follow without a re-visit.
        .onChange(of: subscription.isSubscribed) { _, isSubscribed in
            if isSubscribed { Task { await loadRenewalFacts() } }
        }
    }

    // MARK: - Plan card facts

    /// The one paid plan is "Unlimited" (the paywall's word since launch). A
    /// non-subscriber is on no plan at all, so the card is headed by the app;
    /// a lapsed account is headed by the plan it HAD.
    private var planTitle: String {
        if subscription.isVip || subscription.isSubscribed || subscription.isLapsed { return mbLoc("Unlimited") }
        return "My Business"
    }

    private var statusLabel: String {
        // While the cold-launch entitlement check is still running, say
        // nothing — "Not subscribed" would flash a lie at every subscriber.
        guard subscription.statusKnown || subscription.isVip else { return "—" }
        if subscription.isVip { return mbLoc("Lifetime") }
        if subscription.isSubscribed { return mbLoc("Active") }
        if subscription.isLapsed { return mbLoc("Subscription ended") }
        return mbLoc("Not subscribed")
    }

    private var statusDetail: String {
        if subscription.isVip { return mbLoc("You have unlimited lifetime access.") }
        guard subscription.statusKnown else { return mbLoc("Checking your subscription…") }
        if subscription.isSubscribed {
            if let date = renewal.expirationDate {
                // Three states, not two (GoldLifeUI): auto-renew UNKNOWN must not assert "Renews".
                let day = GLSubscriptionStatusCopy.renewalDay(date, locale: MBLocalization.shared.locale)
                return Self.text(GLSubscriptionStatusCopy.renewal(day: day, willAutoRenew: renewal.willAutoRenew))
            }
            return Self.text(GLSubscriptionStatusCopy.renewalTerms())
        }
        // The lapse, said plainly: lapsed is 100% read-only (Apple 5.1.1(v) —
        // the data stays readable; nothing new can be added or changed).
        if subscription.isLapsed {
            return mbLoc("Your Unlimited plan ended, so My Business is read-only. Everything you already have is still here to read.")
        }
        // The paywall's exact renewal-terms sentence — one string, one truth.
        return Self.text(GLSubscriptionStatusCopy.renewalTerms())
    }

    /// Price + period, both from the store — never a hardcoded figure (wrong
    /// currency abroad) or a hardcoded period: the term the person is ON, by
    /// product id, never `products.first`.
    private var priceLine: String? {
        if subscription.isVip { return nil }
        if subscription.isSubscribed {
            guard let id = renewal.activeProductID,
                  let product = subscription.products.first(where: { $0.id == id }) else { return nil }
            return pricePerPeriod(product)
        }
        guard subscription.statusKnown, !subscription.isSubscribed,
              let entry = subscription.products.first(where: { $0.id == SubscriptionManager.monthlyID }) else { return nil }
        return Self.text(GLSubscriptionStatusCopy.plansStartAt(monthlyPrice: entry.displayPrice))
    }

    private func pricePerPeriod(_ product: Product) -> String {
        let unit = product.subscription?.subscriptionPeriod.unit
        if let copy = GLSubscriptionStatusCopy.pricePerPeriod(price: product.displayPrice, unit: unit) {
            return Self.text(copy)
        }
        return product.displayPrice
    }

    /// A package sentence (a key in this app's catalog) in the app's chosen language.
    private static func text(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = MBLocalization.shared.locale
        return String(localized: resource)
    }

    // MARK: - Actions

    /// The buttons alone — the fleet skeleton supplies the stack, its spacing,
    /// and the clear-row chrome.
    @ViewBuilder
    private var actions: some View {
        Group {
            // Only once status is known, so a subscriber never briefly sees
            // Subscribe on cold launch. The buy runs through the ONE paywall,
            // so the compliant point-of-purchase disclosure stays in a single
            // place.
            if subscription.statusKnown && !subscription.isSubscribed && !subscription.isVip {
                Button {
                    showingPaywall = true
                } label: {
                    // "Reactivate" for somebody coming back — the fleet's word,
                    // already on the lapsed banner and the paywall.
                    Text(subscription.isLapsed ? mbLoc("Reactivate") : mbLoc("Subscribe"))
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(GLTheme.accent)
            }
            if subscription.isSubscribed {
                // Apple's own manage surface, presented IN-APP via the native
                // sheet (parity contract 2026-08-22) — the app's own plan
                // never has to leave the app.
                Button {
                    managingSubscription = true
                } label: {
                    Text("Manage Subscription").frame(maxWidth: .infinity)
                }
                // Explicitly borderless (its automatic look) — inside a List
                // row an unstyled Button can hand its tap to the row.
                .buttonStyle(.borderless)
                .font(.glBody)
                .tint(GLTheme.accent)
            }
            // On the menu path as well as the paywall (App Review expects a
            // reachable Restore outside the purchase interrupt).
            Button {
                restoring = true
                Task {
                    defer { restoring = false }
                    do {
                        try await AppStore.sync()
                        subscriptionAlert = SubscriptionAlert(
                            title: mbLoc("Purchases restored"),
                            message: mbLoc("Your purchases have been restored. If you have an active subscription, it’s now active on this device."))
                    } catch {
                        // nil message = the user cancelled the sign-in sheet — say nothing.
                        subscriptionAlert = SubscriptionActions.restoreFailureMessage(for: error).map {
                            SubscriptionAlert(title: mbLoc("Couldn’t restore purchases"), message: $0)
                        }
                    }
                }
            } label: {
                // The word stays while it works (a bare spinner strips the
                // button's VoiceOver name) — the spinner joins leading.
                HStack(spacing: 8) {
                    if restoring { ProgressView() }
                    Text("Restore Purchases")
                }
            }
            .buttonStyle(.borderless)
            .font(.glBody)
            .tint(GLTheme.accent)
            .disabled(restoring)
            Button {
                redeemingCode = true
            } label: {
                Text("Redeem Code")
            }
            .buttonStyle(.borderless)
            .font(.glBody)
            .tint(GLTheme.accent)
        }
    }

    // MARK: - Data

    /// The active term's expiry + auto-renew intent, from StoreKit's LOCAL caches — works
    /// offline, never blocks the screen (GoldLifeUI: the later expiry wins, so the card prices
    /// the term that will actually bill).
    private func loadRenewalFacts() async {
        renewal = await GLSubscriptionRenewalFacts.load(productIDs: Set(SubscriptionManager.productIDs),
                                                        products: subscription.products)
    }
}

#Preview {
    NavigationStack {
        SubscriptionScreen()
    }
    .environment(SubscriptionManager.shared)
}
