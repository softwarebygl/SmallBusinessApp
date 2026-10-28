import SwiftUI
import SwiftData
import StytchCore
import LocalAuthentication
import GoldLifeUI
import GoldLifeID
import GoldLifeAI
#if canImport(UIKit)
import UIKit
#endif

enum GatePhase: Equatable {
    case splash, lock, signIn, app
}

/// Is the real app on screen, unlocked? Read by the app-switcher cover
/// (GLPrivacyShield.installAutoCover's condition) at the moment it would go up.
/// The lock and sign-in faces show no records, and the Face ID sheet itself
/// sends the scene inactive — a cover raised over the lock mid-prompt would
/// flash a second brand screen on every unlock (parity, law 38).
@MainActor
enum MBCoverCondition {
    static var appIsShowing = false
}

/// The WARM relock, ONE for the whole app (QA 2026-10-03, F25). On iPad every
/// My Business window has its own GateView; each used to keep its own lock
/// flag, so one window locked while the other stayed open, and unlocking the
/// locked one left the other's relock latched off for the rest of the session.
/// Any window returning past the grace window locks the app, GLLockWindow covers
/// every window, and unlocking any one of them clears it for all. The lock, the
/// covers and the relock decision are GoldLifeUI's (audit F158); what is My
/// Business's own is the face on the cover and its Light/Dark choice.
@MainActor
enum MBWarmLock {
    static let shared = GLWarmLock { shown, onUnlock in
        GLLockWindow.setShown(shown,
                              colorScheme: { AppearanceStore.shared.colorScheme },
                              onUnlock: onUnlock) { unlock in
            // The same face the cold-launch gate shows at the lock phase, wrapped in
            // MBLocalizedRoot because a fresh window inherits none of the app root's
            // environment.
            MBLocalizedRoot {
                LockScreen(onUnlock: unlock)
                    .tint(GLTheme.accentFill)
            }
        }
    }
}

struct GateView: View {
    @Environment(GoldLifeAuth.self) private var auth
    @AppStorage(UserDemoMode.defaultsKey) private var exploringSampleData = false
    @AppStorage(AppLockPrefs.key) private var requireLock = false
    
    /// COLD-LAUNCH lock only (a gate phase — nothing is mounted behind it to
    /// preserve). The warm relock is `overlayLocked` + GLLockWindow.
    /// The raw latch: read it through `coldLockStands`, never on its own.
    @State private var isLocked = false
    /// WARM relock: Face ID over the RUNNING app, without touching the gate
    /// phase (2026-09-01, the lost-estimate bug: swapping .app → .lock
    /// unmounted SignedInHost — navigation stack and every half-typed form
    /// died for a 60-second trip to Notes). MM's overlayLocked is the
    /// reference; GLLockWindow renders above everything, sheets included.
    /// App-wide, not per window (F25): every window reads the one MBWarmLock.
    @State private var warmLock = MBWarmLock.shared
    private var overlayLocked: Bool { warmLock.isLocked }
    /// When the app last left the foreground — the clock the grace window runs
    /// against. Nil while in the foreground.
    @State private var backgroundedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    /// A quick app-switch shouldn't re-prompt; a phone set down and picked up
    /// should. SIXTY seconds (owner ruling 2026-08-31, superseding the earlier
    /// two minutes): long enough to copy an address out of Mail or take a
    /// photo of a job and come back, short enough that a phone left on a
    /// counter re-locks while you are still walking away. The fleet figure,
    /// `GLRelockPolicy.grace`. DEBUG accepts
    /// `-mb.relockGrace <seconds>` so the warm path is testable without the
    /// wait.
    private static let relockGrace: TimeInterval = {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "mb.relockGrace")
        if override > 0 { return override }
        #endif
        return GLRelockPolicy.grace
    }()

    /// Does the cold lock still stand? The latch alone is not the answer. It is
    /// set when the gate appears — before anybody has proved anything — so on its
    /// own it also catches the person who signed in seconds ago inside Apple's
    /// sheet, Google's sheet or an emailed code, and asks them for a face right
    /// on top of the identity check they just passed (audit 2026-09-04). A
    /// session that was merely RESTORED from the Keychain still gets the lock on
    /// a cold launch — that is the whole point of the setting.
    private var coldLockStands: Bool {
        requireLock && isLocked && !auth.didSignInThroughDoor
    }

    private var gatePhase: GatePhase {
        // DEBUG screenshot/UI-test harness (-demoMode): the gate is off and the
        // app runs on the persistent store the launch seed filled — the hard
        // gate would otherwise have silently killed the whole marketing-shot
        // pipeline (hard-false in Release, so no user path skips sign-in).
        if DemoMode.isActive { return .app }
        switch auth.state {
        case .undetermined: return exploringSampleData ? .app : .splash
        case .signedIn: return coldLockStands ? .lock : .app
        case .signedOut: return exploringSampleData ? .app : .signIn
        }
    }

    var body: some View {
        ZStack {
            GLTheme.background.ignoresSafeArea()
            switch gatePhase {
            case .splash:
                // The brand, not a blank wall: the Keychain wait + Stytch
                // round-trip can take a beat on cold launch, and a bare
                // background reads as a hang. The FLEET wordmark hero — the
                // same title as the sign-in screen, eyebrow off (owner ruling
                // 2026-08-30: no app icon on splash surfaces, the wordmark IS
                // the splash).
                GateSplash()
                    .task { await auth.resolve() }
            case .signIn:
                SignInScreen(auth: auth)
                    .background(GLTheme.background.ignoresSafeArea())
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            case .lock:
                LockScreen {
                    isLocked = false
                }
                .background(GLTheme.background.ignoresSafeArea())
                .zIndex(1)
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
            case .app:
                if DemoMode.isActive {
                    // DEBUG screenshot/UI-test harness: the persistent seeded
                    // store the root already mounts.
                    DemoAppHost()
                } else if exploringSampleData, auth.state != .signedIn {
                    // Sample mode runs the WHOLE app on a throwaway in-memory
                    // container seeded with the rich demo dataset — the person's
                    // real (empty) store is never mounted, so nothing they poke
                    // at can touch it, and Exit simply drops the container.
                    //
                    // `auth.state != .signedIn` is load-bearing (audit
                    // 2026-09-04): a real session and the fictional dataset are
                    // mutually exclusive. GoldLifeAuth clears sample mode the
                    // moment a session lands; this is the second belt, so a
                    // defaults flag that somehow outlives it can never strand a
                    // signed-in person inside the sample app — where SignedInHost
                    // never mounts, so no migration or backfill runs, GLSyncEngine
                    // never attaches, and the person is signed in backing up
                    // NOTHING.
                    SampleDataHost()
                } else {
                    // A real sign-in runs on that PERSON's store (namespaced by
                    // canonical id), with sync attached to it — never the shared
                    // default store, which under the hard gate holds nothing.
                    //
                    // Removal is .identity ON PURPOSE (the 6:41 PM sign-out
                    // crash, build 43): with the default cross-fade, the
                    // signed-in subtree kept animating out after sign-out, and
                    // its @Query views took one more update pass against the
                    // store being torn down — a SwiftData trap inside the view
                    // -graph diff. Unmount instantly; only the incoming gate
                    // fades.
                    SignedInHost()
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: gatePhase)
        .task {
            // Not in demo mode: the gate phase ignores the cold lock there, but a
            // LATCHED isLocked also blocked the warm-relock stamp forever — the
            // screenshot harness could never exercise the relock overlay. Not
            // after a door sign-in either — `coldLockStands` carries the reason,
            // and this guard keeps the latch itself honest if the gate reappears.
            if requireLock, !DemoMode.isActive, !auth.didSignInThroughDoor { isLocked = true }
        }
        .onChange(of: gatePhase == .app && !overlayLocked, initial: true) { _, showing in
            MBCoverCondition.appIsShowing = showing
        }
        .onChange(of: auth.state) { _, state in
            // Every way out of the session drops the lock windows — they must
            // never outlive what they guard (sign-out lands on the gate).
            if state != .signedIn { warmLock.unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // The app-switcher cover is INDEPENDENT of the Face ID lock —
                // it is a privacy setting of its own, so it must not sit behind
                // `requireLock`. The snapshot iOS stores UNENCRYPTED can be a
                // revealed Tax ID, a W-9 printing a full SSN, or the year-end
                // CSV; My Business had no cover at all until 2026-08-31.
                // (Raised by GLPrivacyShield.installAutoCover off UIKit's own
                // scene notifications — willDeactivate and didEnterBackground —
                // because a scenePhase change arrives too late to make the
                // app-switcher snapshot.)
                // Stamp the departure; the DECISION happens on return. Locking
                // here unconditionally is what made stepping out to Mail for
                // ten seconds cost a Face ID — and it
                // swapped the gate phase and tore down the whole signed-in
                // subtree, losing the navigation stack and any half-typed edit.
                // Only over a REAL session, and never in sample mode (audit
                // 2026-09-04) — a stamp taken on the sign-in screen or in the
                // sample app is a Face ID prompt waiting to be raised over
                // something that guards nothing.
                if requireLock, auth.state == .signedIn, !exploringSampleData,
                   !overlayLocked, !coldLockStands { backgroundedAt = Date() }
            case .active:
                // Unconditional, and before anything else — becoming active is
                // by itself sufficient reason for the cover to be gone. A cover
                // that outlives its condition reads as a frozen app.
                GLPrivacyShield.hideNow()
                // A glance at another app leaves the session alone; a phone set
                // down and picked up later re-locks. 60 seconds, the fleet
                // figure `GLRelockPolicy.grace` carries.
                // GLLockWindow renders above everything, sheets included, so it
                // is raised ONLY over a real signed-in session: over the sign-in
                // screen there is nothing behind it to unlock, and over the
                // sample app it demands a face to get back to fictional data.
                if auth.state == .signedIn, !exploringSampleData,
                   GLRelockPolicy.shouldRelock(backgroundedAt: backgroundedAt, now: Date(),
                                             grace: Self.relockGrace, requireLock: requireLock) {
                    warmLock.lock()
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }
}

/// Hosts the app on the SIGNED-IN person's own store: the container namespaced
/// by their canonical id, migrations run against it, and the sync engine
/// attached to it — the launch sequence that used to run in App.init against the
/// shared store, moved to where the user's store actually exists. Order is
/// load-bearing: SyncIdentityBackfill mints the syncID every op is addressed by,
/// so sync attaches strictly last.
private struct SignedInHost: View {
    @State private var container: ModelContainer?
    @State private var remount = MBStoreRemount.shared

    var body: some View {
        ZStack {
            if remount.screensDown {
                // My Business's data is being erased (Gold Life ID deletion, step one): nothing
                // that shows the store may be on screen while it empties (C17 review 2026-10-04).
                GateSplash()
            } else if let container {
                AppGate()
                    .modelContainer(container)
            } else {
                // Still the launch gate: the same wordmark splash the cold launch opened on, while
                // the store mounts and the entitlement is read (owner ruling 2026-09-25 (8)).
                GateSplash()
                    .task { container = await mount() }
            }
        }
        // Dropping the container makes `mount()` run again once the wipe is done: the same
        // (now empty) store, its migrations, and a fresh sync attached to it.
        .onChange(of: remount.screensDown) { _, down in if down { container = nil } }
        .modifier(MBReopensDeletionAfterErase(ready: container != nil && !remount.screensDown))
    }

    @MainActor
    private func mount() async -> ModelContainer {
        // Whose session this is, settled BEFORE anything is read for it: a different account
        // than the cached one clears the departed person's entitlement word and assistant
        // consent (Zero Account Bleed). Idempotent — the landing's own call is then a no-op.
        GoldLifeAuth.reconcilePrefOwner()
        // Owner ruling 2026-09-25 (8): the entitlement is known BEFORE the person lands. The
        // reads are asked now and waited on at the end of this function; their ~3 s limit
        // counts from now, so the splash lasts the longer of the mount and that limit, never
        // their sum. Whatever is still out lands silently afterwards.
        let entitlementKnown = await MBLaunchEntitlement.startDuringMount { await MBLaunchEntitlement.resolve() }
        let canonicalID = StytchClient.sessions.session?.userId.rawValue
        // The business Tax ID is this account's Keychain item, never the last person's
        // (2026-09-29) — set before anything below reads or drains it.
        SecureTINStore.setAccountScope(canonicalID)
        // Bind AIConnectionStore to this Gold Life ID so saved API keys load for this user only.
        AIConnectionStore.shared.setActiveUser(canonicalID)
        let store = UserScopedStore.shared.container(for: canonicalID)
        let context = store.mainContext
        JobMigration.runIfNeeded(context)
        ContractMigration.runIfNeeded(context)
        // The flats are what every reader (isBlank included) sees now, so legacy
        // composites must be forward-copied before dedup.
        AddressFlatsBackfill.run(context,
                                 storeURL: store.configurations.first?.url)
        ProfileDedup.run(context)
        ReviewLinkBackfill.runIfNeeded(context)
        SyncIdentityBackfill.run(context)
        LegacyTINDrain.run(context)

        // The ONE Gold Life ID record, shared by every app in the fleet (owner ruling
        // 2026-09-19; law 48). Screens read the identity from the package (MBIdentity),
        // never from this store.
        Task {
            // Resolved here too, not just at the app root: this app's own doors sign in
            // through Stytch directly, so after a fresh sign-in (or a launch whose Keychain
            // was still locked) this call is what tells GoldLifeID there is a session. When
            // the root's resolve already landed this person, it sends nothing: GoldLifeID
            // refreshes the identity once at a time and at most once a minute (F93).
            await GoldLifeID.shared.resolve()
        }

        // Held strongly by UserScopedStore — GLSyncEngine.current is weak, and an
        // unheld engine stops syncing silently.
        UserScopedStore.shared.activeEngine = GLSyncEngine.attach(to: store)
        _ = await entitlementKnown.value
        return store
    }
}

/// The DEBUG screenshot/UI-test harness's host (-demoMode, hard-false in Release): the root's
/// seeded store, taken down and put back around an erase exactly as `SignedInHost` does it.
private struct DemoAppHost: View {
    @State private var remount = MBStoreRemount.shared

    var body: some View {
        ZStack {
            if remount.screensDown {
                GateSplash()
            } else {
                AppGate()
            }
        }
        .modifier(MBReopensDeletionAfterErase(ready: !remount.screensDown))
    }
}

/// Erasing My Business's data in place (the Gold Life ID deletion screen, step one; audit
/// 2026-10-03 F1) with nothing on screen that shows it. Deleting every record under the live tabs,
/// split view and pushed details trapped: SwiftUI re-rendered a row over a deleted record
/// (`Employee.payType`, C17 review 2026-10-04). Sign-out's pattern instead: take the signed-in
/// screens down, let the unmount become real, wipe, and mount the same (now empty) store again.
@MainActor
@Observable
final class MBStoreRemount {
    static let shared = MBStoreRemount()

    /// The signed-in screens (tabs, split view, the Menu sheet and everything pushed in it) are
    /// down while this is true; the host shows the launch splash in their place.
    private(set) var screensDown = false
    /// Bumped once per finished wipe: the host puts Delete Account back on screen for step two.
    private(set) var completedWipes = 0

    /// Takes the screens down, waits until nothing presented is left, runs `wipe` on the now
    /// unobserved store, and puts the screens back. One at a time: a second request while one
    /// runs waits for it.
    func wipeWithScreensDown(_ wipe: @MainActor () -> Void) async {
        while screensDown { await Self.nextRunLoopTurn() }
        screensDown = true
        await Self.waitForScreensToLeave()
        wipe()
        completedWipes += 1
        screensDown = false
    }

    /// One trip around the main run loop (GoldLifeAuth's sign-out uses the same step), then
    /// however long a sheet that was up takes to finish leaving (at most 2 s): a sheet's screens
    /// stay alive until its dismissal ends.
    private static func waitForScreensToLeave() async {
        await nextRunLoopTurn()
        #if canImport(UIKit)
        for _ in 0..<40 where somethingIsPresented {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #endif
        await nextRunLoopTurn()
    }

    #if canImport(UIKit)
    private static var somethingIsPresented: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
    #endif

    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// After the erase the person was on Delete Account, and the remount took that screen away.
/// Puts it back (a sheet over the remounted app) so they land on step two, the Gold Life ID
/// itself, with My Business's row now reading empty.
private struct MBReopensDeletionAfterErase: ViewModifier {
    /// The remounted app is on screen (a sheet needs a presenter).
    let ready: Bool
    @State private var remount = MBStoreRemount.shared
    @State private var reopen = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .onChange(of: remount.completedWipes) { _, _ in reopen = true }
            .sheet(isPresented: Binding(get: { reopen && ready }, set: { if !$0 { reopen = false } })) {
                MBDeletionSheet()
                    .glAppearance(colorScheme)
            }
    }
}

/// The GoldLifeID package's deletion screen as a sheet of its own.
private struct MBDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GoldLifeIDDeletionScreen()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                }
        }
    }
}

/// The launch gate's face: the fleet wordmark hero with a spinner. One view, so the cold-launch
/// splash and the signed-in mount (which also waits for the entitlement) look identical and the
/// hand-off between them is seamless.
private struct GateSplash: View {
    var body: some View {
        VStack(spacing: 14) {
            GLGateHero(wordmark: "My Business", eyebrowVisible: false)
            ProgressView()
                .tint(GLTheme.accentFill)
        }
    }
}

/// Hosts the app on the demo container while "Explore with sample data" is on.
/// Also covers the cold-relaunch case: the flag persists in UserDefaults, but the
/// in-memory container doesn't — so re-seed on appear rather than mounting the
/// person's real, empty store under a banner that promises sample data.
private struct SampleDataHost: View {
    @ObservedObject private var demo = UserDemoMode.shared

    var body: some View {
        if let container = demo.demoContainer {
            AppGate()
                .modelContainer(container)
        } else {
            ProgressView()
                .onAppear { demo.startDemo() }
        }
    }
}

struct LockScreen: View {
    let onUnlock: () -> Void
    @State private var authenticating = false

    var body: some View {
        ZStack {
            GLTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(GLTheme.accentFill)
                Text("My Business is locked")
                    .font(.title3.weight(.semibold))
                Button {
                    Task { await unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(GLTheme.accentFill)
                .disabled(authenticating)
            }
        }
        .task { await unlock() }
    }

    /// One Face ID prompt at a time across every window (F25): with two iPad windows locked,
    /// both covers appear at once, and only the first asks; the other waits on its Unlock button.
    private static var promptIsUp = false

    private func unlock() async {
        guard !authenticating, !Self.promptIsUp else { return }
        authenticating = true
        Self.promptIsUp = true
        defer {
            authenticating = false
            Self.promptIsUp = false
        }

        if await BiometricGate.authenticate(reason: mbLoc("Unlock My Business")) {
            onUnlock()
        }
    }
}
