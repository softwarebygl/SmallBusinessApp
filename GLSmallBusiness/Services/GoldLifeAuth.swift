//
//  GoldLifeAuth.swift — the Gold Life ID session for My Business.
//
//  HARD-gated as of v3.0 (owner ruling 2026-08-28): the app opens on the sign-in
//  screen, and this session decides whether GateView shows the doors or the app.
//  Doors: Apple, Google, Gold Life ID (email one-time code — see
//  GoldLifeEmailSignInSheet), plus the isolated sample-data mode.
//
//  The session logic uses the shared Stytch project and
//  debugged Keychain-restore dance. Sign-out/expiry KEEP the synced per-user
//  cache behind the gate and drop only unsaved in-flight work; account deletion
//  is the one exit that wipes (UserScopedStore owns both). Face-ID app lock is
//  GatePhase.LockScreen's job, not this file's.
//

import GoldLifeAI
import GoldLifeCloud
import GoldLifeUI
import SwiftData
import SwiftUI
import StytchCore
import AuthenticationServices
import GoogleSignIn
import OSLog
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class GoldLifeAuth {
    /// `undetermined` is a real answer, not a placeholder for "no". Collapsing it
    /// into signed-out is what would turn a locked Keychain into a false "signed
    /// out" — and fire the one-time nudge at someone who never signed out.
    enum State { case undetermined, signedIn, signedOut }

    private(set) var state: State = .undetermined
    var isSignedIn: Bool { state == .signedIn }
    /// How the CURRENT session arrived: true only when a door in THIS launch
    /// minted it — the person proved who they are seconds ago inside Apple's
    /// sheet, Google's sheet or an emailed code. False for a session restored
    /// from the Keychain. GateView's COLD Face ID lock reads it (audit
    /// 2026-09-04): asking for a face right after Apple already asked is the
    /// same question twice, while a restored session on a cold launch still
    /// gets the lock — that is the whole point of the setting.
    private(set) var didSignInThroughDoor = false
    var isBusy = false
    var errorMessage: String?

    /// The answer is settled — stop asking. Only ever set after a read that could
    /// actually see the Keychain.
    private var resolved = false
    /// A resolve is in flight. Separate from `resolved` and set BEFORE the first
    /// await: this class is main-actor isolated, but isolation is not a lock — the
    /// actor is free during a suspension, so a second caller (the foreground
    /// retry) would walk straight through a guard that only checks `resolved`.
    private var resolving = false

    // Nothing Stytch-related in init, deliberately: a stored `@State` property is
    // built BEFORE the App's init body — i.e. before StytchClient.configure() has
    // run — so reading the session here would answer nil for an intact session.

    /// What `resolve()` asks Stytch: is a session stored on this phone, and does Stytch's
    /// server still accept it. A seam so the launch's bounded wait is testable without Stytch.
    struct SessionSource {
        var hasPersistedSession: @MainActor () -> Bool
        /// Asks Stytch's server about the stored session. Stytch clears the stored copy itself
        /// when it refuses it; a network failure leaves it in place.
        var authenticate: @MainActor () async -> Void
        /// Stytch refused the session after the launch had already landed on it: the
        /// session-expiry teardown, exactly as when the Worker refuses it.
        var refusedAfterLanding: @MainActor (GoldLifeAuth) async -> Void

        static let live = SessionSource(
            hasPersistedSession: { GoldLifeAuth.hasPersistedSession },
            authenticate: { _ = try? await StytchClient.sessions.authenticate(parameters: .init(sessionDurationMinutes: Minutes(rawValue: 43_200))) },
            refusedAfterLanding: { await $0.handleSessionExpired() })
    }
    @ObservationIgnored var sessionSource: SessionSource = .live
    /// The longest a cold launch waits for Stytch's server before it lands on the stored
    /// session (platform rule: gates never wait on the network; law 70's ~3 s).
    nonisolated static let sessionCheckLimit: Duration = .seconds(3)
    @ObservationIgnored var sessionCheckLimit: Duration = GoldLifeAuth.sessionCheckLimit

    /// Find out whether a real session exists, from a task rather than an
    /// initializer. Two things make an early read lie: configure() may not have
    /// run yet, and on a cold launch the Keychain is still locked
    /// (`isProtectedDataAvailable == false`), so every Stytch read throws silently
    /// under `try?`. Waiting for the Keychain — not moving configure() — fixes it.
    func resolve() async {
        guard !resolved, !resolving else { return }
        resolving = true
        defer { resolving = false }
        // Try the read before waiting on anything. Stytch keeps its token
        // AfterFirstUnlock, but isProtectedDataAvailable tracks the stricter
        // "unlocked right now" — a phone merely locked in a pocket reads the token
        // fine while that flag is false. Waiting on the flag first burns the whole
        // timeout on a condition this code never needed.
        let source = sessionSource
        if !source.hasPersistedSession() {
            await Self.waitForProtectedData()
        }
        let hasSession = source.hasPersistedSession()

        // Latch only an answer that can be trusted. Seeing a session IS proof the
        // Keychain was readable, whatever the flag says. The one untrustworthy
        // answer is "no session" while still locked — that alone stays unlatched,
        // so a later foreground asks again instead of mislabeling a returning user.
        if hasSession || UIApplication.shared.isProtectedDataAvailable { resolved = true }
        guard hasSession else {
            state = .signedOut
            // A launch with no session (it ended while the app was closed): nothing of the
            // last person may stay (law 13). Only on a TRUSTED "no session" — a locked
            // Keychain also reads as none, and wiping then would throw away a signed-in
            // person's unsynced work.
            if resolved { GLSessionWipe.shared.run(.launchedWithoutSession) }
            return
        }
        // Confirm it against Stytch. A session revoked or expired server-side still
        // leaves its cached copy behind; authenticate() clears the stored session
        // itself when the failure is unrecoverable — so its verdict decides, not
        // the throw (going by the throw would sign out anyone opening the app on a
        // plane).
        //
        // At most `sessionCheckLimit` (audit 2026-10-03 F22): on one bar of signal or captive
        // Wi-Fi the request runs to its 60 s timeout, and the splash waited all of it. At the
        // limit the launch lands on the stored session (weak signal never ends a session, owner
        // ruling 2026-09-28) and the check keeps going: a refusal that arrives later still runs
        // the session-expiry teardown. Everything here is on the main actor, so the check
        // either finished before the line below reads the session, or it sees `landed`.
        let check = SessionCheckLanding()
        let answeredInTime = await GLDeadline.wait(atMost: sessionCheckLimit) { [weak self] in
            await source.authenticate()
            guard check.landed, let self else { return }
            await self.sessionCheckAnsweredLate(source)
        }
        if !answeredInTime { check.landed = true }
        if source.hasPersistedSession() {
            // Belt to GateView's braces (audit 2026-09-04): a real session and the
            // fictional sample dataset are mutually exclusive. Left on, the sample
            // flag keeps the gate rendering SampleDataHost, so SignedInHost never
            // mounts — no migration, no backfill, no GLSyncEngine.attach — and the
            // person is signed in backing up NOTHING.
            UserDemoMode.shared.exitDemo()
            state = .signedIn
            // Restored, not walked through: the cold lock still applies.
            didSignInThroughDoor = false
            kickAppLink()
            Task { await Self.migrateLegacyStripeToken() }
            // Session restore is a landing too: pull the account-synced
            // preferences (law 29) so a change made on another device applies.
            Task {
                Self.reconcilePrefOwner()
                await AppearanceStore.shared.syncFromAccount()
                await MBLocalization.shared.syncFromAccount()
            }
        } else {
            // Stytch refused the stored session (revoked or expired server-side) and cleared
            // it: the session ended while the app was closed (law 13).
            state = .signedOut
            GLSessionWipe.shared.run(.launchedWithoutSession)
        }
    }

    /// Stytch answered after the launch had already landed on the stored session. A refusal
    /// (Stytch cleared the stored copy) ends the session the way a Worker refusal does; a
    /// network failure leaves it alone. A sign-out or a new sign-in in the meantime is left
    /// alone too: the state or the stored session then says so.
    private func sessionCheckAnsweredLate(_ source: SessionSource) async {
        guard state == .signedIn, !source.hasPersistedSession() else { return }
        Self.doorLog.info("Stored session refused after the launch landed on it")
        await source.refusedAfterLanding(self)
    }

    private static var hasPersistedSession: Bool {
        StytchClient.sessions.session != nil || StytchClient.sessions.sessionToken != nil
    }

    /// The Keychain is unreadable until first unlock. Polled, not awaited on
    /// `protectedDataDidBecomeAvailableNotification` (that notification never fires
    /// on the simulator, and check-then-await also drops a flip landing in the gap).
    /// Bounded, because the survivable failure is timing out and reading anyway
    /// (at worst a stale "signed out" in Settings, self-heals on foreground), while
    /// waiting forever would stall the answer indefinitely.
    @discardableResult
    private static func waitForProtectedData(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !UIApplication.shared.isProtectedDataAvailable, ContinuousClock.now < deadline {
            // Bail on cancellation rather than letting `try?` swallow it: a
            // cancelled sleep returns instantly, so without this the loop spins hot
            // on the main actor until the deadline.
            guard !Task.isCancelled else { return UIApplication.shared.isProtectedDataAvailable }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return UIApplication.shared.isProtectedDataAvailable
    }

    /// Native Sign in with Apple through Stytch (Gold Life ID). Stytch presents
    /// the system Apple sheet, verifies the identity token, and returns a session.
    /// Sign-in failure copy that says WHY. Offline is by far the most common cause and
    /// is the one the person can act on, so it gets its own words; anything else is
    /// reported as the service being unavailable, which is true and non-technical.
    /// Never surfaces an error type or code (dev builds do that separately, above).
    nonisolated static func signInFailureMessage(_ error: Error?) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                // Curly apostrophe, matching the identical sentence in StripeBackendError — one
                // catalog key, one translation, one house typography.
                return MBLocalization.string("You’re not connected to the internet. Check your connection and try again.")
            case .timedOut:
                return MBLocalization.string("The connection timed out before sign-in finished. Check your connection and try again.")
            default:
                break
            }
        }
        // `MBLocalization.string`, not `mbLoc`: this helper is nonisolated, so it can't hop to the
        // main actor to read the observed language.
        return MBLocalization.string("Sign-in is temporarily unavailable. Please try again in a few minutes.")
    }

    func signInWithApple() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await StytchClient.oauth.apple.start(parameters: .init())
            landSignedIn(via: .apple)
        } catch let error as ASAuthorizationError where error.code == .canceled || error.code == .unknown {
            // Backing out of Apple's sheet is a decision, not a failure — the sheet
            // reports a plain dismissal as .unknown (1000) as often as .canceled
            // (1001), so both read as "changed their mind".
        } catch {
            // Alert AND log: the banner stays plain English; this line is the
            // developer's only client-side trail (the exchange runs device →
            // Stytch, no Worker log exists — TestFlight B2-5). Machine reasons only, no PII.
            let detail = (error as? StytchAPIError).map { "\($0.errorType): \($0.errorMessage)" } ?? "\(error)"
            Self.doorLog.error("Sign in with Apple failed: \(detail, privacy: .public)")
            #if DEBUG
            // Dev builds surface the REAL failure (parity with the Google path below —
            // build 28's audience-mismatch hunt had only the generic copy to go on).
            errorMessage = "Couldn't sign in. [\(detail)]"
            #else
            errorMessage = Self.signInFailureMessage(error)
            #endif
        }
    }

    /// One diagnosable line per door failure (alert+log rule); the doors share it.
    private static let doorLog = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness", category: "Gate")

    /// Native Google Sign-In: Google's OWN sheet (My Business's name on it, never
    /// "stytch.com"), then the id_token is exchanged for the SAME kind of Stytch
    /// session as the Apple flow via a Trusted Auth Token attest. Requires the
    /// dashboard profile id in LocalSecrets; the button stays hidden while empty.
    func signInWithGoogle() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        // GIDSignIn presents from UIKit — find the foreground key window's root.
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController else {
            errorMessage = Self.signInFailureMessage(nil)
            return
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = Self.signInFailureMessage(nil)
                return
            }
            // sessionDurationMinutes is REQUIRED: attest without it verifies the
            // user but mints NO session (data.session = null → decode error).
            _ = try await StytchClient.sessions.attest(parameters: .init(
                profileId: LocalSecrets.googleTrustedAuthProfileId,
                token: idToken,
                sessionDurationMinutes: StytchClient.defaultSessionDuration
            ))
            landSignedIn(via: .google)
        } catch let error as NSError where error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue {
            // Backing out of Google's sheet is a decision, not a failure.
        } catch {
            // Same alert+log pairing as the Apple door.
            let detail = (error as? StytchAPIError).map { "\($0.errorType): \($0.errorMessage)" } ?? "\(error)"
            Self.doorLog.error("Sign in with Google failed: \(detail, privacy: .public)")
            #if DEBUG
            // Dev builds surface the REAL failure (Stytch error_type / GIDSignIn
            // code) right on screen — a device build has no console. StytchAPIError's
            // interpolation hides its fields; unwrap them.
            errorMessage = "Couldn't sign in. [\(detail)]"
            #else
            errorMessage = Self.signInFailureMessage(error)
            #endif
        }
    }

    @ObservationIgnored private var lastAttemptedEmail: String?

    // MARK: - Email (one-time code) — the Gold Life ID door

    /// Send a 6-digit code to `email` — `loginOrCreate`, the ONE flow (owner
    /// ruling 2026-08-30): a known address gets its code, an unknown one is
    /// minted on first contact, exactly like the Apple and Google doors (the
    /// 2026-08-28 two-faces model is retired). Returns the method id the
    /// verify step needs, or nil on failure. No session changes hands here —
    /// only a successful verify does that. The code itself never touches our
    /// state: Stytch generates, delivers, expires, and throttles it
    /// server-side.
    func sendEmailCode(to email: String) async -> String? {
        lastAttemptedEmail = email
        do {
            let response = try await StytchClient.otps.loginOrCreate(
                parameters: .init(deliveryMethod: .email(email: email)))
            return response.methodId
        } catch {
            let detail = (error as? StytchAPIError).map { "\($0.errorType)" }
                ?? String(describing: type(of: error))
            Self.doorLog.error("Email code send failed: \(detail, privacy: .public)")
            return nil
        }
    }

    /// Send a 6-digit SMS code to `phone` — same `loginOrCreate` semantics for phone number sign-in.
    func sendPhoneCode(to phone: String) async -> String? {
        do {
            let response = try await StytchClient.otps.loginOrCreate(
                parameters: .init(deliveryMethod: .sms(phoneNumber: phone)))
            return response.methodId
        } catch {
            let detail = (error as? StytchAPIError).map { "\($0.errorType)" }
                ?? String(describing: type(of: error))
            Self.doorLog.error("Phone code send failed: \(detail, privacy: .public)")
            return nil
        }
    }

    /// Exchange a delivered code for a session and land signed in — the same
    /// landing the Apple and Google doors use, so every way in is identical
    /// from here on. Returns false on a wrong/expired code (the sheet owns the
    /// retry copy; a failed guess must not tear the sheet down).
    func completeCodeSignIn(code: String, methodID: String) async -> Bool {
        do {
            _ = try await StytchClient.otps.authenticate(
                parameters: .init(
                    code: code,
                    methodId: methodID,
                    sessionDurationMinutes: Minutes(rawValue: 43_200)
                )
            )
            landSignedIn(via: .gold)
            return true
        } catch {
            // The sheet owns the words (a wrong code is a normal moment); this
            // line is the trail. errorType only — never the code itself.
            let detail = (error as? StytchAPIError).map { "\($0.errorType)" }
                ?? String(describing: type(of: error))
            Self.doorLog.error("Code sign-in failed: \(detail, privacy: .public)")
            return false
        }
    }

    /// Every door's one landing: state, the remembered door (law 30), and the
    /// account-synced preferences (law 29 — appearance/language follow the
    /// person in, off the main path so sign-in never waits on them).
    private func landSignedIn(via door: GateDoor) {
        // FIRST, before the state flip the gate reacts to: a real session and the
        // fictional sample dataset are mutually exclusive (audit 2026-09-04).
        // Signing in from inside sample mode used to leave the flag set, so the
        // gate kept rendering SampleDataHost and SignedInHost never mounted — the
        // person was signed in, every backfill skipped, sync never attached, and
        // nothing they typed was backed up.
        UserDemoMode.shared.exitDemo()
        state = .signedIn
        // A door, not a restore: this person authenticated moments ago, so the
        // gate's cold Face ID lock must not ask them again.
        didSignInThroughDoor = true
        resolved = true
        kickAppLink()
        Task { await Self.migrateLegacyStripeToken() }
        GateMemory.record(door)
        if let lastAttemptedEmail, !lastAttemptedEmail.isEmpty {
            GateMemory.rememberedEmail = lastAttemptedEmail
        }
        Task {
            Self.reconcilePrefOwner()
            await AppearanceStore.shared.syncFromAccount()
            await MBLocalization.shared.syncFromAccount()
        }
    }

    /// The pref caches belong to ONE account (2026-08-30 audit). When the
    /// session's user differs from the one the caches were built for, clear
    /// them BEFORE syncing — the arriving person must not inherit the departed
    /// one's language/appearance, nor have that person's unpushed edit drained
    /// into their account. Same-user restores keep the offline cache benefit.
    /// Internal, not private, so the account-switch fence is testable without Stytch.
    static func reconcilePrefOwner() {
        let owner = StytchClient.sessions.session?.userId.rawValue
        let key = "mb.account.prefs.owner"
        let previous = UserDefaults.standard.string(forKey: key)
        guard previous != owner else { return }
        MBLocalization.shared.clearAccountPrefState()
        AppearanceStore.shared.clearAccountPrefState()
        // The assistant's consent is one device-global key (law 26, contract §4): the arriving
        // person must not inherit the departed one's yes, or their books would go to Gemini
        // without them ever seeing the disclosure. Same fence as sign-out, on the path that does
        // NOT go through one.
        MBAssistantSession.shared.detachNow()
        MBAssistantSession.shared.consent.reset()
        AIConnectionStore.shared.setActiveUser(owner)
        // The entitlement word is the departed account's too (a session that ended while the app
        // was closed never ran a sign-out): the arriving person must not open the assistant, or
        // lift the free caps, on someone else's comp.
        clearAccountEntitlement()
        UserDefaults.standard.set(owner, forKey: key)
    }

    /// Every way out of a session — sign-out, session expiry, account deletion, an account
    /// switch — clears what the SERVER said this account is entitled to (the comp/owner word
    /// and the plan, persisted as `mb.entitlement`), the assistant's last StoreKit read, and the
    /// legacy `mb.isVip` key. They belong to the account that earned them, never to the device
    /// (Zero Account Bleed). The chat and the assistant consent go through
    /// `MBAssistantSession.endSession()` on the same paths.
    static func clearAccountEntitlement() {
        UserDefaults.standard.removeObject(forKey: "mb.isVip")
        SubscriptionManager.shared.clearServerEntitlement()
        MBAIEntitlement.shared.reset()
    }


    /// One-shot latch (law 30): after a deliberate
    /// sign-out the gate must NOT auto-run the remembered door — that would
    /// sign the person straight back in and make signing out impossible to
    /// complete. A cold launch still auto-continues.
    private var autoDoorSuppressed = false
    func consumeAutoDoorSuppression() -> Bool {
        defer { autoDoorSuppressed = false }
        return autoDoorSuppressed
    }

    // MARK: - Session teardown (audit 2026-10-03 F62)

    /// A sign-out or a session expiry is still tearing the session down: its revoke, its wipe.
    private(set) var isTearingDown = false
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs one session teardown with the gate held for all of it: `isBusy` (the doors are
    /// disabled), the remembered door suppressed, and every `waitForTeardown()` parked until the
    /// body is done. An expiry used to flip to signed-out, then await the network and only then
    /// wipe; the gate's remembered door could sign the person back in during that await, and
    /// the revoke and the wipe then ended the NEW session and deleted the store it had just
    /// mounted (F62).
    ///
    /// `keepDoorSuppressed`: a chosen sign-out leaves the suppression on for the gate to
    /// consume (law 30: signing out must not sign you straight back in). An expiry puts back
    /// what was there, so the remembered door may run — once the wipe has finished.
    func runTeardown(keepDoorSuppressed: Bool, _ body: () async -> Void) async {
        let suppressedBefore = autoDoorSuppressed
        isTearingDown = true
        isBusy = true
        autoDoorSuppressed = true
        await body()
        if !keepDoorSuppressed { autoDoorSuppressed = suppressedBefore }
        isBusy = false
        isTearingDown = false
        let waiters = teardownWaiters
        teardownWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once no teardown is running (at once when none is).
    func waitForTeardown() async {
        guard isTearingDown else { return }
        await withCheckedContinuation { teardownWaiters.append($0) }
    }

    /// The gate asks this before it runs the remembered door (law 30): it waits for a teardown
    /// still running, then answers no right after a chosen sign-out.
    func mayRunRememberedDoor() async -> Bool {
        await waitForTeardown()
        return !consumeAutoDoorSuppression()
    }

    /// True when the session live now is still the one a teardown started for: the same
    /// opaque token, or none left (Stytch already cleared it). A different token means a new
    /// session went live mid-teardown, and the teardown must not revoke or wipe it.
    nonisolated static func isSameSession(_ ending: String?, live: String?) -> Bool {
        live == nil || live == ending
    }

    /// The opaque Stytch token of the live session. Stable for a session's life (the JWT
    /// rotates every few minutes, this does not).
    private static var liveSessionToken: String? { StytchClient.sessions.sessionToken }

    func signOut() async {
        guard !isTearingDown else { return }
        await runTeardown(keepDoorSuppressed: true) {
            // The assistant holds the store and a live conversation: stop it and wait, BEFORE the
            // store unmounts (contract §4). Consent goes with the session.
            await MBAssistantSession.shared.endSession()
            // The last push, before anything stops (audit 2026-10-03 F12): an edit saved seconds
            // ago is still waiting on its debounce, and the wipe below would lose it. At most
            // about 5 s, and only online; the Menu's alert already named what could be lost.
            await Self.flushSync()
            // GLSync next, before the session is revoked. The engine holds a cached 15-minute app
            // token and a cached document key, and neither is invalidated by Stytch losing its
            // session — so without this line the backup kept running under THIS person's identity
            // for up to the rest of that window. Hand the phone to somebody who signs in with their
            // own Gold Life ID inside it and their invoices upload into this account, and any W-9
            // they add is sealed with this account's document key: unreadable to them, forever.
            await Self.stopSync()

            // forceClear so signing out still works with no connection — a sign-out
            // that silently leaves you signed in is the worst kind of failure here.
            _ = try? await StytchClient.sessions.revoke(parameters: .init(forceClear: true))
            GoldLifeIDLink.reset()
            Self.clearAccountEntitlement()
            state = .signedOut

            // ONLY NOW touch the store — after the signed-in subtree has unmounted.
            // Clearing the outbox while it was still on screen fired a persistent
            // -store remote-change notification into @Query views mid-teardown: the
            // 6:41 PM build-43 sign-out crash (SwiftData trap in the view-graph
            // diff). The state flip above removes the subtree instantly (its
            // removal transition is .identity); one main-runloop turn makes that
            // unmount real before the wipe runs. Sign-out WIPES the local copy (law 13,
            // owner ruling 2026-09-26): the fleet's one wipe (GLSessionWipe, MBSessionPurge);
            // the Menu warned first if any change hadn't been backed up.
            await Self.nextRunLoopTurn()
            GLSessionWipe.shared.run(.sessionEnded)
        }
    }

    /// One trip around the main run loop — the cheapest honest way to let
    /// SwiftUI finish removing a subtree before code touches what it rendered.
    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Tear GLSync down for a session that is ending, whichever way it ends. One place, so the
    /// three exits below cannot drift apart — the engine drops its app token, its document key
    /// and its in-session caches, and stops claiming to be backed up.
    @MainActor
    private static func stopSync() async {
        await GLSyncEngine.current?.signedOut()
    }

    /// Sign-out's last push, under the engine's own limit (`GLSyncEngine.signOutFlushLimit`).
    @MainActor
    private static func flushSync() async {
        await GLSyncEngine.current?.flushBeforeSignOut()
    }

    /// The Worker rejected our session even after GoldLifeAPI's one silent refresh
    /// — the token is present but dead. Tear it down and drop to signed-out. State
    /// flips first, synchronously on the main actor, so several in-flight calls
    /// that all 401 at once collapse to one teardown.
    ///
    /// The whole teardown runs held (`runTeardown`, audit 2026-10-03 F62): the doors stay
    /// disabled and the remembered door waits until the wipe has finished, so no new session
    /// can go live in the middle of it. If one is live anyway, its session is left alone: no
    /// revoke, no wipe. The state still flips FIRST, before any await: the signed-in screens
    /// must be gone before the wipe (the build-43 crash), and several 401s at once collapse to
    /// one teardown.
    func handleSessionExpired() async {
        guard state == .signedIn, !isTearingDown else { return }
        let endingSession = Self.liveSessionToken
        await runTeardown(keepDoorSuppressed: false) {
            state = .signedOut
            // The assistant holds the store and a live conversation: stop it and wait, BEFORE the
            // store unmounts (contract §4). Consent goes with the session.
            await MBAssistantSession.shared.endSession()
            await Self.stopSync()
            guard Self.isSameSession(endingSession, live: Self.liveSessionToken) else {
                Self.doorLog.info("Session expiry teardown skipped its revoke and wipe: a new session is live")
                return
            }
            _ = try? await StytchClient.sessions.revoke(parameters: .init(forceClear: true))
            GoldLifeIDLink.reset()
            Self.clearAccountEntitlement()
            // Same as a chosen sign-out: the local copy is wiped (law 13, owner ruling
            // 2026-09-26) — only after the subtree the state flip removed has actually
            // unmounted (the build-43 sign-out crash window). Only a session Stytch itself
            // refused gets here; weak signal never does (owner ruling 2026-09-28).
            await Self.nextRunLoopTurn()
            GLSessionWipe.shared.run(.sessionEnded)
        }
    }

    /// Irreversible: erases the shared Gold Life ID server-side, then tears down
    /// the local session. Throwing keeps the user signed in so they can retry.
    ///
    /// `identityAlreadyDeleted`: the GoldLifeID package's deletion screen (the 5.1.1(v) path
    /// every billing state can reach, law 48a) has ALREADY deleted the Gold Life ID and revoked
    /// its session when it reports back through `GoldLifeIDConfig.onIdentityDeleted`
    /// (`MBIdentityDeletion`, audit 2026-10-03 C17). Then only the teardown below runs: the
    /// server is never called a second time, and nothing here can throw.
    func deleteAccount(identityAlreadyDeleted: Bool = false) async throws {
        isBusy = true
        defer { isBusy = false }
        if !identityAlreadyDeleted {
            try await GoldLifeAPI.shared.deleteAccount()
        }
        // Like a chosen sign-out: the gate must not run the remembered door straight away. On a
        // deleted identity that would mint a NEW Gold Life ID the moment the old one went.
        autoDoorSuppressed = true
        // The assistant holds the store and a live conversation: stop it and wait, BEFORE the
        // store unmounts (contract §4). Consent goes with the session.
        await MBAssistantSession.shared.endSession()
        // The identity is gone, so no token can ever be minted for it again — but the one
        // already in memory outlives it by up to 15 minutes, and a cycle inside that window
        // would keep pushing to an account that no longer exists.
        await Self.stopSync()
        // The package already force-cleared the session it deleted; this path's own call has not.
        if !identityAlreadyDeleted {
            _ = try? await StytchClient.sessions.revoke(parameters: .init(forceClear: true))
        }
        GoldLifeIDLink.reset()
        Self.clearAccountEntitlement()
        state = .signedOut
        // The account is gone server-side; its local copy goes with it — after
        // the subtree unmounts, same crash window as sign-out.
        await Self.nextRunLoopTurn()
        // Its secrets first (law 73, audit 2026-10-03 F58 + F2): the business Tax ID, every
        // subcontractor's Tax ID and the Stripe token — BEFORE the store wipe below, while the
        // subcontractors' Tax ID keys can still be read from it.
        Self.purgeAccountSecrets(scope: SecureTINStore.accountScope,
                                 context: UserScopedStore.shared.activeMainContext)
        UserScopedStore.shared.wipeOnAccountDeletion()
        GLSessionWipe.shared.run(.sessionEnded)
        GateMemory.rememberedEmail = ""
        GateMemory.clearDoor()
    }

    /// Account deletion's Keychain step: everything of this Gold Life ID's that lives outside the
    /// store. Sign-out keeps the Tax IDs (they are never backed up); deletion is the person asking for
    /// everything to be erased (REQUIREMENTS law 73). The services are injectable for the tests.
    static func purgeAccountSecrets(scope: String?, context: ModelContext?,
                                    tinService: String = SecureTINStore.service,
                                    stripeService: String = StripeInstallTokenStore.service) {
        let subcontractors = context.flatMap { try? $0.fetch(FetchDescriptor<Subcontractor>()) } ?? []
        SecureTINStore.deleteAccountItems(scope: scope, subcontractorKeys: subcontractors.map(\.tinKey),
                                          service: tinService)
        StripeInstallTokenStore.delete(for: scope, service: stripeService)
        AIConnectionStore.shared.purgeSavedKeys(forUserID: scope)
    }

    /// The Stripe upgrade path (audit 2026-10-03 F2), on a signed-in landing: a token from before
    /// 3.3.0 moves to this account only if the server proves it is the account this business names,
    /// and is deleted only on proof that it is not. Waits (bounded) for the person's store and for a
    /// business profile that names a Stripe account; until one does, the token is left alone.
    static func migrateLegacyStripeToken() async {
        guard StripeInstallTokenStore.hasLegacyToken, !DemoMode.isActive else { return }
        for _ in 0..<40 {
            guard StripeInstallTokenStore.hasLegacyToken else { return }
            if let context = UserScopedStore.shared.activeMainContext, StripeInstallTokenStore.signedInScope != nil,
               await settleLegacyStripeTokenOnLanding(context: context, migrate: { accountId in
                   await StripeBackendClient.shared.migrateLegacyTokenIfNeeded(profileAccountId: accountId)
               }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// One landing try. The landing runs before the first sync pull, so a missing profile (or the
    /// empty one a screen inserts) is NOT a synced profile that names no account: the token is then
    /// left alone (false) for the Stripe screen and the send path, which only run for a connected
    /// profile; a session end still purges a leftover. Only an account the profile names is sent to
    /// `migrate`, which asks the server to prove it.
    static func settleLegacyStripeTokenOnLanding(context: ModelContext,
                                                 migrate: (_ profileAccountId: String) async -> Void) async -> Bool {
        let profiles = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        guard let accountId = profiles.lazy
            .map({ $0.stripeConnectedAccountId.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return false }
        await migrate(accountId)
        return true
    }

    /// Fire-and-forget the legacy app-link mapping (named for the CloudKit era;
    /// today it only records the Gold Life ID linkage server-side). Bookkeeping
    /// only, so it never blocks or reports back into the sign-in flow.
    private func kickAppLink() {
        Task { await GoldLifeIDLink.runIfNeeded() }
    }
}

/// Whether `resolve()` already landed on the stored session when Stytch's check finishes.
private final class SessionCheckLanding {
    var landed = false
}

// MARK: - The remembered door (law 30)

/// Which of the gate's three doors signed the person in last.
enum GateDoor: String {
    case apple, google, gold
}

/// Law 30's memory: remember the login flow so the next launch leads with it.
/// Device-local by nature (it describes THIS device's habit); the toggle
/// defaults ON — frictionless is the premium default, and the gate shows the
/// switch so opting out is one tap.
enum GateMemory {
    private static let rememberKey = "mb.rememberDoor"
    private static let doorKey = "mb.lastDoor"
    private static let emailKey = "gl.gate.rememberedEmail"

    static var rememberEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: rememberKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: rememberKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: rememberKey)
            if !newValue {
                UserDefaults.standard.removeObject(forKey: doorKey)
                UserDefaults.standard.removeObject(forKey: emailKey)
                UserDefaults.standard.removeObject(forKey: "gl_gate_remembered_email")
            }
        }
    }

    static var rememberedDoor: GateDoor? {
        guard rememberEnabled else { return nil }
        return GateDoor(rawValue: UserDefaults.standard.string(forKey: doorKey) ?? "")
    }

    static var rememberedEmail: String {
        get {
            guard rememberEnabled else { return "" }
            return UserDefaults.standard.string(forKey: emailKey)
                ?? UserDefaults.standard.string(forKey: "gl_gate_remembered_email")
                ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || !rememberEnabled {
                UserDefaults.standard.removeObject(forKey: emailKey)
                UserDefaults.standard.removeObject(forKey: "gl_gate_remembered_email")
            } else {
                UserDefaults.standard.set(trimmed, forKey: emailKey)
                UserDefaults.standard.set(trimmed, forKey: "gl_gate_remembered_email")
            }
        }
    }

    static func record(_ door: GateDoor) {
        guard rememberEnabled else { return }
        UserDefaults.standard.set(door.rawValue, forKey: doorKey)
    }

    static func clearDoor() {
        UserDefaults.standard.removeObject(forKey: doorKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: "gl_gate_remembered_email")
    }
}
