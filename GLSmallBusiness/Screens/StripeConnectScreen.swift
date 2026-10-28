//
//  StripeConnectScreen.swift
//  GLSmallBusiness
//
//  Settings → "Get paid by card (Stripe)". Connect a Stripe account (hosted onboarding via
//  ASWebAuthenticationSession), see whether it can accept charges, and choose which invoices carry a
//  Pay button. Deliberately framed around CHARGING YOUR CUSTOMERS and kept separate from the app's own
//  StoreKit subscription, so it can't read as steering around in-app purchase (App Review §3.1.1).
//

import GoldLifeUI
import OSLog
import SwiftUI
import SwiftData
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

struct StripeConnectScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    /// Observed, not read once: exiting sample data from the banner must re-render this screen.
    @ObservedObject private var demo = UserDemoMode.shared

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GLSmallBusiness",
                                    category: "Payments")

    @State private var auth = WebAuthCoordinator()
    @State private var working = false
    @State private var errorMessage: String?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal BusinessProfileService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var status: StripeConnectStatus?
    /// Sample mode tapped the connect button — say why nothing happened instead of doing it.
    @State private var showingSampleNotice = false
    /// The backend refused to authorize this install (401/403) on the last status check — its token
    /// isn't bound any more. Distinct from `needsDeviceLink` (no token at all): the account is fine,
    /// only this device's link to it is gone, so reconnecting RESUMES the same account.
    @State private var deviceLinkLost = false
    /// The last status check couldn't reach the backend at all. The screen keeps showing what it last
    /// knew (never downgrade on a network blip) and says so, instead of passing stale off as fresh.
    @State private var statusCheckFailed = false
    /// The connect + status poll (audit 2026-10-03 F125). Owned so leaving the screen — which a
    /// sign-out does, by unmounting it — stops it instead of letting it write for ~25 s more.
    @State private var connectTask: Task<Void, Never>?
    /// Bumped after the Keychain changes under the screen (the pre-3.3.0 token was settled), which
    /// SwiftUI can't observe, so `needsDeviceLink` is read again.
    @State private var tokenRevision = 0
    @Environment(\.scenePhase) private var scenePhase

    private var profile: BusinessProfile? { profiles.first }
    /// "Explore with sample data" is on: the business on screen is fictional and lives in a throwaway
    /// in-memory store, so this screen must not touch the live backend at all. Connecting would mint a
    /// REAL install token into the Keychain and open a REAL Stripe Express account — asking someone who
    /// believes they are looking at a demo for their legal name, SSN and bank account. Gated the same
    /// way `SubscriptionManager.isLapsed`, `AccessGate.decide` and `ReadOnlyGate.isReadOnly` gate it.
    private var isSampleData: Bool { demo.isDemoActive }
    private var isConnected: Bool { profile?.stripeIsConnected ?? false }
    private var canCharge: Bool { profile?.stripeChargesEnabled ?? false }
    /// Connected and everything submitted, but Stripe hasn't enabled charges yet — a review is pending,
    /// so there is nothing for the user to "finish." Distinguishes this from a real unfinished-setup state.
    private var isPendingReview: Bool {
        guard let status else { return false }
        return !status.canCharge && status.detailsSubmitted && status.currentlyDueCount == 0
    }
    /// The account is connected (the id synced down via CloudKit) but THIS device holds no install
    /// token — a second device with iCloud Keychain off. The backend can't authorize pay-link calls from
    /// here until the user runs the onboarding "resume" path once, so show that honestly instead of a
    /// green "Connected" that quietly can't mint links. (Demo mode seeds a fake connected account with
    /// no token; it must keep looking connected.)
    private var needsDeviceLink: Bool {
        _ = tokenRevision
        return isConnected && !DemoMode.isActive && (!deviceTokenMatchesProfile || deviceLinkLost)
    }

    /// The signed-in Gold Life ID's token on this device is bound to the account this business names
    /// (audit 2026-10-03 F2). Any other token can't take this business's payments.
    private var deviceTokenMatchesProfile: Bool {
        guard let entry = StripeInstallTokenStore.load(for: StripeInstallTokenStore.signedInScope),
              let accountId = profile?.stripeConnectedAccountId, !accountId.isEmpty else { return false }
        return entry.boundAccountId == accountId
    }
    /// The backend says it can no longer act on the stored account (`needsReconnect`) — it was deleted,
    /// or created under a platform key that has since been rotated. "Finish Stripe setup" would resend
    /// the dead id and fail again, so this state gets its own button that drops the binding first.
    private var needsAccountReconnect: Bool {
        isConnected && !DemoMode.isActive && status?.mustReconnect == true
    }

    var body: some View {
        Form {
            Section {
                if isSampleData {
                    // FIRST branch on purpose: every other state below can start a live backend call,
                    // and the sample business must reach none of them. The button stays tappable (a
                    // dead disabled control explains nothing) — tapping says what to do instead.
                    Button { showingSampleNotice = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mbLoc("Connect Stripe account"))
                                Text(mbLoc("Card payments aren’t part of sample data — sign in with your own account to set them up."))
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "building.columns").foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                } else if working {
                    // Onboarding, or a post-onboarding status poll, is in flight. Stripe can take a few
                    // seconds to enable charges, so we keep checking instead of stranding on "Finish setup."
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(isConnected ? "Finishing your Stripe setup…" : "Opening Stripe…")
                            .foregroundStyle(GLTheme.textSecondary)
                    }
                } else if !isConnected {
                    Button { connect() } label: {
                        Label("Connect Stripe account", systemImage: "building.columns")
                    }
                    .disabled(!StripeConfig.isConfigured)
                } else if needsAccountReconnect {
                    // Ahead of `canCharge` on purpose: the cached flag can still be a synced `true`,
                    // and a green "ready to get paid" seal on an account that cannot charge is the
                    // worst state this screen can show.
                    Button { connect(clearingBinding: true) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reconnect your Stripe account")
                                Text("We can’t reach your Stripe account any more, so invoices are going out without a Pay button. Reconnecting sets it up again — your invoices and payment history stay exactly as they are.")
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(GLTheme.accent)
                        }
                    }
                    .disabled(!StripeConfig.isConfigured)
                } else if needsDeviceLink {
                    // Second device, iCloud Keychain off (or the backend stopped authorizing this
                    // install): the account synced down but this device isn't linked to the backend.
                    // Reconnecting resumes the SAME account (CloudKit-synced id + ownership claim),
                    // it never creates a new one.
                    Button { connect() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reconnect this device")
                                Text("Your Stripe account is connected, but this device isn’t linked to it yet. Until you reconnect, invoices sent from this device won’t include a Pay button.")
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(GLTheme.statusAttention)
                        }
                    }
                    .disabled(!StripeConfig.isConfigured)
                } else if canCharge {
                    // Ready — tap to re-check.
                    Button { Task { await refreshStatus() } } label: {
                        Label {
                            Text("Connected — ready to get paid")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(GLTheme.statusGood)
                        }
                    }
                } else if isPendingReview {
                    // Everything is submitted and nothing is due — Stripe just hasn't enabled charges yet.
                    // Tapping RE-CHECKS status (it does NOT reopen onboarding), so the user can't get stuck
                    // in the finish-setup loop while Stripe finishes reviewing.
                    Button { Task { await refreshStatus() } } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stripe is finishing your setup")
                                Text("Your info is submitted — this can take a few minutes. Tap to check again.")
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "hourglass").foregroundStyle(GLTheme.statusAttention)
                        }
                    }
                } else {
                    // A requirement is genuinely still due — reopen onboarding to finish it.
                    Button { connect() } label: {
                        Label {
                            Text("Finish Stripe setup")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GLTheme.accent)
                        }
                    }
                }
            } header: {
                InfoLabel("Stripe", info: "Connect a Stripe account to let your customers pay your invoices by card. This is for charging your customers — it is not related to your My Business subscription. Payments go straight to your Stripe account; we never hold your money.", topic: "Stripe")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("For charging your customers — separate from your My Business subscription.")
                    if !isConnected {
                        Text("Sign in with your own Stripe email. New to Stripe? We’ll set one up.")
                    }
                    if !StripeConfig.isConfigured {
                        Text("Card payments aren’t available in this build yet.")
                    }
                    if statusCheckFailed {
                        // Say the screen is stale rather than silently passing the last known
                        // answer off as current.
                        Text("Couldn’t check your Stripe status just now — what you see is the last thing we knew. Pull down to try again.")
                            .foregroundStyle(GLTheme.statusAttention)
                    }
                }
                .foregroundStyle(GLTheme.textSecondary)
            }

            if isConnected {
                Section {
                    Toggle("Add a Pay button by default", isOn: payDefaultBinding)
                } header: {
                    InfoLabel("Pay button on invoices", info: "Sets the default for new invoices. Every invoice keeps its own Pay-button toggle, so you can turn it on or off for any single invoice.", topic: "Pay button on invoices")
                } footer: {
                    Text(payDefaultBinding.wrappedValue
                         ? "New invoices include a “Pay this invoice” button. You can turn it off on any invoice."
                         : "New invoices don’t include a Pay button. You can turn it on for any invoice.")
                }
            }
        }
        .glFormBackground()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Connect Stripe"))), for: .scrollContent)
        // A REAL collapsing nav-bar script title (parity ruling 5), as a resolved
        // String so an in-app language switch re-renders the bar.
        // Named like its Menu row (law 22, audit 2026-10-03 F110).
        .navigationTitle(GLScript.padded(mbLoc("Connect Stripe")))
        .toolbarTitleDisplayMode(.large)
        .task { await refreshStatus() }
        // Leaving the screen stops a connect still polling Stripe. A sign-out unmounts this screen,
        // so it stops then too, and `mayApplyResult` refuses anything that lands after it anyway.
        // Not while Stripe's own sheet is up: covering the screen with it is not leaving.
        .onDisappear { if !auth.isPresenting { connectTask?.cancel() } }
        .refreshable { await refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app re-checks, so an account Stripe enabled while we were away updates.
            if phase == .active { Task { await refreshStatus() } }
        }
        // Titled with what failed, like every other failure alert in the app — not with the brand.
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .alert(mbLoc("Couldn’t set up payments"), isPresented: Binding(get: { errorMessage != nil },
                                                                      set: { if !$0 { errorMessage = nil } })) {
            Button(mbLoc("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Not a failure — the honest answer for a fictional business. Titled with the situation, and
        // it names the one thing that actually gets the person card payments.
        .alert(mbLoc("Not available in sample data"), isPresented: $showingSampleNotice) {
            Button(mbLoc("OK"), role: .cancel) { showingSampleNotice = false }
        } message: {
            Text(mbLoc("Card payments aren’t part of sample data — sign in with your own account to set them up."))
        }
    }

    private var payDefaultBinding: Binding<Bool> {
        Binding(
            get: { profile?.payLinkDefaultOn ?? true },
            set: { newValue in
                guard ReadOnlyGate.allows(.saveAppSettings, into: $readOnlyRefusal) else { return }
                // BusinessProfileService finds or creates the profile and saves.
                do {
                    try BusinessProfileService.setPayLinkDefault(newValue, in: modelContext)
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                }
            }
        )
    }

    @discardableResult
    private func ensureProfile() -> BusinessProfile {
        if let profile { return profile }
        let created = BusinessProfile()
        modelContext.insert(created)
        return created
    }

    /// Drop the stored Stripe binding so the next onboard starts from scratch. Called ONLY when the
    /// backend has said the binding is unusable: the account id is the sole resume key, so clearing it
    /// speculatively would strand a live account and let the next connect create a duplicate.
    private func clearStoredBinding() {
        let p = ensureProfile()
        p.stripeConnectedAccountId = ""
        p.stripeAccountClaim = ""
        p.stripeChargesEnabled = false
        status = nil
        deviceLinkLost = false
    }

    /// Onboard (create-or-resume the connected account), open Stripe's hosted setup, then refresh status.
    /// `clearingBinding` starts genuinely fresh — the Reconnect path, for an account the backend can no
    /// longer act on.
    private func connect(clearingBinding: Bool = false) {
        // Sample data never reaches the backend. The body already replaces this button in sample mode,
        // so this is the belt to that suspenders — but it refuses out loud (alert AND log) rather than
        // silently, because a silent return here is exactly the dead control the house rule forbids.
        guard !isSampleData else {
            Self.log.notice("Stripe connect blocked: sample data session")
            showingSampleNotice = true
            return
        }
        // Connecting creates a real Stripe account (or rebinds one) on the owner's behalf — the
        // clearest possible case of the app DOING something, so a lapsed app does not start it.
        guard ReadOnlyGate.allows(.setUpPayments, into: $readOnlyRefusal) else { return }
        working = true
        connectTask?.cancel()
        let startedFor = StripeInstallTokenStore.signedInScope
        connectTask = Task { @MainActor in
            defer { working = false }
            if clearingBinding { clearStoredBinding() }
            let existing = profile?.stripeConnectedAccountId ?? ""
            let existingClaim = profile?.stripeAccountClaim ?? ""
            let response: StripeOnboardResponse
            do {
                response = try await StripeBackendClient.shared.onboard(existingAccountId: existing,
                                                                        accountClaim: existingClaim)
            } catch StripeBackendError.claimRejected where !existing.isEmpty {
                // The stored claim no longer proves ownership (the backend's pepper was rotated, or the
                // claim belongs to an account that's gone). Resending it can only 403 forever, and the
                // backend has already dropped its side of the binding — so drop ours and try once more
                // as a first-time connect, which issues a fresh account and a fresh claim.
                clearStoredBinding()
                do {
                    response = try await StripeBackendClient.shared.onboard(existingAccountId: "",
                                                                            accountClaim: "")
                } catch {
                    errorMessage = friendly(error)
                    return
                }
            } catch {
                errorMessage = friendly(error)
                return
            }
            // Signed out (or the screen left) while Stripe answered: nothing lands on a store that
            // was wiped, or on the next person's.
            guard canApply(startedFor: startedFor) else { return }
            // The account exists on Stripe now (just not necessarily finished) — remember its id + claim.
            let p = ensureProfile()
            p.stripeConnectedAccountId = response.connectedAccountId
            if let claim = response.accountClaim, !claim.isEmpty { p.stripeAccountClaim = claim }
            guard let url = URL(string: response.onboardingUrl) else {
                errorMessage = mbLoc("Stripe’s setup page didn’t open. Try again in a few minutes.")
                return
            }
            do {
                _ = try await auth.start(url: url, callbackScheme: "glsmallbusiness")
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // User dismissed the sheet — not an error; they may simply finish later.
            } catch {
                // Any other browser error is non-fatal; we still re-check status below.
            }
            tokenRevision += 1
            // Stripe can take a few seconds to enable charges after onboarding — poll so the screen
            // updates itself instead of stranding the user on "Finish setup."
            await pollUntilReady()
        }
    }

    /// After onboarding returns, re-check status a few times (≈25s) so the screen flips to "Connected" on
    /// its own once Stripe enables charges, rather than showing a single early "not ready" result.
    private func pollUntilReady() async {
        for attempt in 0..<8 {
            if Task.isCancelled { return }
            await refreshStatus()
            if canCharge || Task.isCancelled { return }
            if attempt < 7 { try? await Task.sleep(for: .seconds(3)) }
        }
    }

    /// A result may land only on the session that asked for it, and only while it is still wanted.
    static func mayApplyResult(startedFor: String?, now: String?, isCancelled: Bool) -> Bool {
        guard !isCancelled, let startedFor, !startedFor.isEmpty else { return false }
        return startedFor == now
    }

    /// `mayApplyResult` for this screen, plus the record: the profile it would write must still be live.
    private func canApply(startedFor: String?) -> Bool {
        guard Self.mayApplyResult(startedFor: startedFor, now: StripeInstallTokenStore.signedInScope,
                                  isCancelled: Task.isCancelled) else { return false }
        guard let profile else { return true }      // ensureProfile() inserts a fresh one
        return profile.modelContext != nil && !profile.isDeleted
    }

    private func refreshStatus() async {
        // Sample data: no backend calls at all. Unattended (this runs from `.task`, `.refreshable` and
        // every foreground), so no alert — and nothing to say anyway: the screen already states it.
        if isSampleData { return }
        // Demo/screenshot runs seed a deterministic connected state; don't let a live status call
        // (which would fail for the fake account) flip it back to "setup not finished."
        if DemoMode.isActive { return }
        let startedFor = StripeInstallTokenStore.signedInScope
        // A token from before 3.3.0 is settled first: moved to this account if the server proves it
        // is this business's, deleted if it proves it is not, kept otherwise (audit 2026-10-03 F2).
        if StripeConfig.isConfigured, isConnected, StripeInstallTokenStore.hasLegacyToken {
            await StripeBackendClient.shared.migrateLegacyTokenIfNeeded(
                profileAccountId: profile?.stripeConnectedAccountId ?? "")
            guard canApply(startedFor: startedFor) else { return }
            tokenRevision += 1
        }
        // Skip when this device holds no token bound to THIS business's account: the call can't be
        // authorized for it, and a bogus "can't charge" result must not clobber the synced
        // stripeChargesEnabled the OTHER device set.
        guard StripeConfig.isConfigured, isConnected, deviceTokenMatchesProfile else { return }
        do {
            let s = try await StripeBackendClient.shared.connectStatus()
            // Signed out, switched account, or left the screen while Stripe answered: drop it.
            guard canApply(startedFor: startedFor) else { return }
            status = s
            deviceLinkLost = false
            statusCheckFailed = false
            // `status` above is screen-local and vanishes with the view — writing
            // `stripeChargesEnabled` is not: it lands on the profile and syncs to every device,
            // and on a first run `ensureProfile()` INSERTS that profile. A lapsed app does neither.
            // Unattended, so no alert (this runs from `.task`, `.refreshable` and every foreground
            // — nobody asked for it) but the log line is not optional.
            guard ReadOnlyGate.allowsUnattended(.saveAppSettings) else { return }
            ensureProfile().stripeChargesEnabled = s.canCharge
        } catch let error as StripeBackendError where error.isBindingLost {
            guard canApply(startedFor: startedFor) else { return }
            // The backend won't authorize this install any more. Swallowing this is what left a green
            // "Connected — ready to get paid" latched on an account that couldn't charge, with no way
            // out; offer Reconnect instead.
            deviceLinkLost = true
            statusCheckFailed = false
        } catch {
            guard canApply(startedFor: startedFor) else { return }
            // Couldn't reach the backend — keep the last known answer (a blip must not flip the Pay
            // button off fleet-wide) and let the footer say the screen is stale.
            statusCheckFailed = true
        }
    }

    /// Only OUR errors are trusted to carry user-facing copy. `LocalizedError` in general is not:
    /// system errors conform to it too, which is how Apple's developer wording ("An SSL error has
    /// occurred…") used to reach this alert.
    private func friendly(_ error: Error) -> String {
        (error as? StripeBackendError)?.errorDescription
            ?? mbLoc("Couldn’t reach Stripe. Check your connection and try again.")
    }
}

/// Presents an `ASWebAuthenticationSession` and bridges its completion to async/await. Holds the
/// presentation anchor so the system can place the auth sheet over the app's key window.
@MainActor
final class WebAuthCoordinator: NSObject {
    private var session: ASWebAuthenticationSession?
    /// Stripe's sheet is on screen (from `start` until its completion).
    private(set) var isPresenting = false
    /// Retained here: the session holds its context provider weakly.
    private var anchorProvider: WebAuthAnchorProvider?

    /// Opens `url` in the secure auth session and resolves with the custom-scheme callback URL, or
    /// throws (including `ASWebAuthenticationSessionError.canceledLogin` when the user dismisses it).
    /// With no window to present over (audit 2026-10-03 F125: the anchor used to index the first
    /// scene unchecked), it says Stripe couldn't open instead of trapping.
    func start(url: URL, callbackScheme: String) async throws -> URL {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = Self.anchorWindow(in: scenes) else { throw StripeBackendError.browserUnavailable }
        let provider = WebAuthAnchorProvider(window: window)
        anchorProvider = provider
        isPresenting = true
        defer { isPresenting = false }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? StripeBackendError.onboardingCancelled)
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: StripeBackendError.browserUnavailable)
            }
        }
    }

    /// The window the auth sheet presents over: the key window, else any window, else a new one on the
    /// first window scene (see ImageCropView.windowTopInset). nil when the app has no window scene.
    static func anchorWindow(in scenes: [UIWindowScene]) -> UIWindow? {
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first {
            return window
        }
        guard let scene = scenes.first else { return nil }
        return UIWindow(windowScene: scene)
    }
}

/// Answers the auth session's anchor request with the window `start` already resolved, so the
/// answer can never be "none".
@MainActor
private final class WebAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
