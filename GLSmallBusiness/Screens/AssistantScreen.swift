//
//  AssistantScreen.swift
//  GLSmallBusiness
//
//  The assistant (law 58). The pixels and the loop are GoldLifeAI's `GLAIChatScreen`; this screen
//  is the HOST: it owns the navigation context, the ONE banner stack, the paywall, the sign-in
//  action, the record router, and the handoff sheets.
//
//  Three doors, one conversation: the Assistant tab, the iPad Assistant section, and the sparkles
//  button on every record screen (which passes that record as `onScreen`, so "this invoice" means
//  something). `MBAssistantSession` holds the controller, so leaving and coming back — including
//  through an `open` that navigates away — returns to the same conversation.
//
//  The handoff sheets are mounted HERE, on the screen's own container, which stays on screen for
//  the whole request: a sheet hung on a view that left never reports back.
//

import SwiftUI
import SwiftData
import GoldLifeAI
import GoldLifeUI

struct AssistantScreen: View {
    /// The record the person is looking at, when the assistant was opened from its screen.
    var onScreen: GLAIOnScreen?
    /// True when presented as a sheet from a record screen (it needs its own Done button).
    var isSheet = false
    /// False in the iPad Assistant column: `NavigationSplitView` already supplies that column's
    /// navigation controller, so wrapping another stack would stack two bars — and the Menu
    /// already lives at the bottom of the sidebar. Every other column takes the same flag
    /// (`AllJobsScreen(isTabRoot:)`, `CalendarScreen(ownsStack:)`).
    var ownsStack = true
    /// The claim token, when the thing that PRESENTED this screen owns it (the sparkles sheet, so
    /// it can hand routing back the moment it is dismissed). Nil for the tab root and the iPad
    /// column, which mint their own and live as long as the app.
    var hostToken: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(GoldLifeAuth.self) private var auth: GoldLifeAuth?
    @Environment(AppRouter.self) private var envRouter: AppRouter?
    private var router: AppRouter { envRouter ?? .fallback }

    @State private var session = MBAssistantSession.shared
    @State private var entitlement = MBAIEntitlement.shared
    @State private var subscription = SubscriptionManager.shared
    @State private var path: [MBAssistantDestination] = []
    /// The column's single push, when this screen doesn't own a stack (it drives the enclosing
    /// navigation controller instead of a path of its own).
    @State private var columnPush: MBAssistantDestination?
    @State private var legalSheet: MBAssistantDestination?
    @State private var showingPaywall = false
    @State private var showingMenu = false
    @State private var network = NetworkMonitor.shared
    /// This screen's claim on the shared presenter. Up to three assistant screens can be alive at
    /// once; the newest one on screen is the one that routes and presents (law 44).
    @State private var ownToken = UUID()
    @ObservedObject private var demo = UserDemoMode.shared

    private var token: UUID { hostToken ?? ownToken }

    var body: some View {
        Group {
            if ownsStack {
                NavigationStack(path: $path) {
                    chrome
                        .navigationDestination(for: MBAssistantDestination.self) { destination in
                            MBAssistantDestinationView(destination: destination)
                        }
                }
            } else {
                chrome
                    .navigationDestination(item: $columnPush) { destination in
                        MBAssistantDestinationView(destination: destination)
                    }
            }
        }
        .glAmbientBackground { PrimaryBackground() }
        .task(id: ObjectIdentifier(modelContext)) {
            session.onScreen = onScreen
            await session.attach(modelContext)
            // The launch gate already read both answers (owner ruling 2026-09-25 (8)); this
            // re-reads StoreKit, and asks the server again only if its answer never arrived.
            await entitlement.refreshOnAppear()
            await refreshUsage()
        }
        // Law 80's bar: re-read after every answer (the month's spend just moved) and whenever
        // the gate opens online (a purchase, reconnecting).
        .onChange(of: session.controller?.isRunning ?? false) { _, running in
            if !running { Task { await refreshUsage() } }
        }
        .onChange(of: gate) { _, _ in Task { await refreshUsage() } }
        // Claimed on appear, never released here: a PUSH also fires `onDisappear`, and the stack
        // this screen owns is still perfectly routable behind the record it just pushed. The
        // sparkles sheet — the one door that really goes away — releases from its own `onDismiss`.
        .onAppear { claimRoute() }
        // A purchase made in the paywall has landed by the time it closes; an upgrade from Pro to
        // Pro + AI never moves `isSubscribed`, so the dismissal is the signal that catches it.
        .onChange(of: subscription.isSubscribed) { _, _ in Task { await entitlement.refresh() } }
        .onChange(of: subscription.serverEntitled) { _, _ in Task { await entitlement.refresh() } }
        // No automatic paywall, ever (owner ruling 2026-09-25 (8); A17): someone who isn't
        // subscribed meets the inline Pro + AI gate (ContentUnavailableView + Upgrade), and the
        // paywall opens only from that Upgrade button or the error bubble's Upgrade action.
        .onDisappear { session.onScreen = nil }
    }

    private var chrome: some View {
        content
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(mbLoc("Done")) { dismiss() }
                    }
                } else if ownsStack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingMenu = true } label: { MenuButtonLabel() }
                            .accessibilityLabel(mbLoc("Menu"))
                    }
                }
            }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .sheet(item: $legalSheet) { destination in
                legalContent(destination).glAppearance(colorScheme)
            }
            // The assistant's own paywall: a Pro + AI headline and only the Pro + AI plans —
            // plain Pro never opens the assistant.
            .paywallSheet(isPresented: $showingPaywall, context: .assistant) {
                Task { await entitlement.refresh() }
            }
            .mbAIHandoffs(session.presenter, owner: token)
    }

    /// This screen takes over routing while it is the newest one up; a dismissed sheet hands it
    /// back to whatever is underneath, so a dead stack can never be pushed into.
    private func claimRoute() {
        session.presenter.claim(token) { destination in
            route(destination)
        }
    }

    private func route(_ destination: MBAssistantDestination) {
        if destination.isSheet {
            legalSheet = destination
        } else if !isSheet, case .screen(let name) = destination, router.navigateToRootScreen(name) {
            return
        } else if ownsStack {
            path.append(destination)
        } else {
            columnPush = destination
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.controller != nil, isCheckingSubscription {
            // A first answer is still being read (a launch-gate read that ran past its limit):
            // the neutral spinner, never the "Couldn't confirm Pro + AI" error it used to flash.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glFormBackground()
                .modifier(MBAssistantTitle())
        } else if let controller = session.controller {
            GLAIChatScreen(controller: controller, host: host)
        } else if session.setupFailed {
            // Law 4: never a blank wall — say what happened and give the way forward.
            ContentUnavailableView {
                Label(mbLoc("Sentinel"), systemImage: "sparkles")
            } description: {
                Text(verbatim: mbLoc("Sentinel isn’t available right now."))
            }
            .glFormBackground()
            .modifier(MBAssistantTitle())
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glFormBackground()
                .modifier(MBAssistantTitle())
        }
    }

    private var host: GLAIChatHost {
        GLAIChatHost(
            title: MBAssistantStrings.title,
            appName: MBAssistantSession.appName,
            gate: gate,
            // The app's ONE banner stack, with the assistant's offline sentence in on-device mode
            // (law 5: the same card in the same slot, never a second one).
            bannerStack: { variant in AnyView(MBSystemBannerInset(offlineVariant: variant)) },
            examples: MBAssistantStrings.examples,
            examplesTitle: MBAssistantStrings.examplesTitle,
            composerPlaceholder: MBAssistantStrings.composerPlaceholder,
            activityCardTitle: MBAssistantStrings.activityCardTitle,
            workingLabel: { MBAssistantStrings.workingLabel($0) },
            consentContent: MBAssistantStrings.consentContent,
            presentHandoff: { [presenter = session.presenter] handoff in await presenter.present(handoff) },
            openRecord: { record in open(record) },
            onSignIn: isSignedIn ? nil : { signIn() },
            onUpgrade: { showingPaywall = true },
            // Try Again on "Couldn't confirm Pro + AI" only RE-READS — StoreKit and the server's
            // comp answer — and never opens the paywall: the person may already be paying (A17).
            onRetrySubscriptionCheck: { Task { await entitlement.recheck() } },
            dictationLocale: MBLocalization.currentLocale,
            usage: session.usage,
            connectionStore: .shared)
    }

    /// Only an open, online assistant has a month to show.
    private func refreshUsage() async {
        guard case .open(.online) = gate else { return }
        await session.refreshUsage()
    }

    private var isSignedIn: Bool { auth?.state == .signedIn || DemoMode.isActive }

    /// The AI Assistant is 100% free via BYOK — no subscription check blocks the screen.
    private var isCheckingSubscription: Bool { false }

    private var gate: GLAIGate {
        GLAIGate.resolve(
            isSampleMode: demo.isDemoActive,
            isSignedIn: isSignedIn,
            subscription: .entitled,
            isOnline: network.isConnected,
            onDeviceAvailable: MBAssistantSession.shared.hasOnDeviceModel)
    }

    /// An activity row or Direct Link was tapped: navigate to the record or screen in-app.
    private func open(_ record: GLAIRecordRef) {
        if record.kind == "screen" {
            guard MBOpenTarget(rawValue: record.id) != nil else { return }
            route(.screen(record.id))
            return
        }
        guard let destination = MBAssistantDestination(record: record, in: modelContext) else { return }
        route(destination)
    }

    /// Sample mode's empty state: leaving the sample data lands on the sign-in gate.
    private func signIn() {
        Task {
            await session.cancelAndWait()
            demo.exitDemo()
        }
    }

    @ViewBuilder
    private func legalContent(_ destination: MBAssistantDestination) -> some View {
        if case .screen(let name) = destination, name == MBOpenTarget.termsOfUse.rawValue {
            TermsOfUseSheet()
        } else {
            PrivacyPolicySheet()
        }
    }
}

/// The screen's own title while the chat screen isn't up yet (it titles itself once it is): the
/// law 57 script large title with the per-string descender clearance every titled screen claims.
private struct MBAssistantTitle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationTitle(GLScript.padded(MBAssistantStrings.title))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(MBAssistantStrings.title)),
                            for: .scrollContent)
    }
}

// MARK: - The sparkles button

/// The assistant button every record screen wears, and the sheet it opens with that record as
/// what's on screen. One place, so the nine screens can't drift.
///
/// `resolve` is called in the BUTTON'S ACTION, never while the toolbar is being built: naming a
/// record to the model mints its `syncID` and saves the store (`DomainSyncIdentity.ensure`), and a
/// SwiftData write inside a view update is exactly the out-of-order `@Query` hazard this app
/// already serializes its UI tests for.
struct MBAssistantButton: View {
    let resolve: @MainActor () -> GLAIOnScreen?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false
    @State private var onScreen: GLAIOnScreen?
    /// The sheet's claim on the shared presenter, released the moment it closes — the sheet is the
    /// one assistant screen that really goes away, and its navigation stack goes with it.
    @State private var sheetToken = UUID()

    var body: some View {
        Button {
            onScreen = resolve()
            showing = true
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(GLTheme.accentFill)
        }
        .accessibilityLabel(mbLoc("Sentinel"))
        .sheet(isPresented: $showing,
               onDismiss: { MBAssistantSession.shared.presenter.release(sheetToken) }) {
            // Law 1: a sheet captures its scheme once, so it is handed the app's chosen one.
            AssistantScreen(onScreen: onScreen, isSheet: true, hostToken: sheetToken)
                .glAppearance(colorScheme)
        }
    }
}

extension PersistentModel {
    /// True when this record can be named to the assistant: it is live in a store, so an id can be
    /// minted for it. PURE — reading it writes nothing, so a toolbar may ask during a view update.
    @MainActor
    var canBeNamedToAssistant: Bool { MBFeatureFlags.assistantEnabled && modelContext != nil && !isDeleted }
}

extension GLAIOnScreen {
    /// What the model is told is on screen: the record's kind, its id and a label it can say back.
    @MainActor
    init?(_ kind: MBRecordKind, _ record: some PersistentModel & GLSyncIdentified, label: String,
          in store: ModelContext?) {
        guard let store, let id = try? DomainSyncIdentity.ensure(record, in: store,
                                                                subscription: SubscriptionManager.shared)
        else { return nil }
        self.init(kind: kind.rawValue, id: id.uuidString, label: label)
    }
}
