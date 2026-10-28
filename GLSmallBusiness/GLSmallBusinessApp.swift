//
//  GLSmallBusinessApp.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData
import OSLog
import GoldLifeUI
import GoldLifeID
import GoldLifeCloud
import GoldLifeAI
import StytchCore
import GoogleSignIn
#if canImport(UIKit)
import UIKit
#endif

// wipeSwiftDataStore lives in Services/StoreRecovery.swift. It only removes a store
// that must go (the account-deletion mark below); store recovery never wipes —
// it moves an unreadable store aside and rescues its unsent changes (F63).

// The former private `PrivacyScreen` root overlay was DELETED 2026-08-31. It was
// a second, subtly different copy of the app-switcher cover — exactly what
// GLPrivacyShield's header warns against — and it had three faults of its own:
// it ignored "Hide when switching apps" entirely (so turning the setting OFF
// changed nothing), a SwiftUI root overlay sits UNDER any presented `.sheet` (so
// the Menu ▸ Settings sheet went into the snapshot fully legible — the
// TestFlight report on 3.0.0 (61)). GLPrivacyShield (a window above `.alert`
// level) is the ONE cover now, in both apps; since the owner ruling of
// 2026-09-29 it goes up on inactive as well as background when the setting is
// ON (law 38).

@main
struct GLSmallBusinessApp: App {
    /// The Gold Life Setting appearance pattern (law 29): Gold Life Setting /
    /// System / Light / Dark, account-synced. Reading it in `body` registers
    /// Observation, so a pick re-renders the root immediately.
    @State private var appearance = AppearanceStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The Gold Life ID session behind the HARD gate (law 11): nobody reaches
    /// the app without resolving it. A stored `@State` is built BEFORE this
    /// App's init body runs — i.e. before StytchClient.configure() below — so
    /// GoldLifeAuth reads no session in its init; it resolves later from a task.
    @State private var goldLifeAuth = GoldLifeAuth()

    /// Appearance actually applied to the app. Normal runs honor the user's stored Light/Dark/Auto
    /// preference. DEBUG demo/screenshot runs pin a deterministic appearance so marketing captures
    /// never depend on the simulator's global Light/Dark setting: `-demoDark` forces dark, otherwise
    /// light. Compiled out of release builds, and never active unless `-demoMode` is passed.
    private var effectivePreferredColorScheme: ColorScheme? {
        #if DEBUG
        if DemoMode.isActive {
            return ProcessInfo.processInfo.arguments.contains("-demoDark") ? .dark : .light
        }
        #endif
        return appearance.colorScheme
    }

    /// Local-only store. CloudKit mirroring is gone as of the GLSync cutover (GLSYNC-SPEC.md §7):
    /// gl-business-api is the backup now, and leaving `cloudKitDatabase: .automatic` on would run two
    /// replication systems against one store. The CloudKit CONTAINER itself is deliberately NOT
    /// deleted (owner ruling: keep it ≥12 months) — it is the only copy of anything we fail to
    /// upload, and it costs nothing to leave sitting there.
    let sharedModelContainer: ModelContainer = {
        // Versioned schema + migration plan so future model changes upgrade existing
        // customers' data safely. See GLSchema.swift for the rules before changing any @Model.
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        // An account deletion could not wipe the default store while this container
        // held it open — it marked it instead. This runs before the container
        // exists, the one safe moment (CRUD audit 2026-09-02).
        if UserDefaults.standard.bool(forKey: UserScopedStore.pendingDefaultStoreWipeKey) {
            wipeSwiftDataStore(at: ModelConfiguration(schema: schema).url)
            UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        }
        #if DEBUG
        // UI tests that need a deterministic, pristine dataset launch with -uiTestChangeOrder → use a
        // throwaway in-memory store so the demo seed runs fresh every launch (the persistent demo store is
        // idempotent and wouldn't pick up test-only fixtures), and the real store is never touched.
        // EVERY demo / UI-test launch runs on a throwaway store (suite review
        // 2026-09-02): plain -demoMode used to hit the persistent simulator store,
        // so every UI run mutated it and seed changes never reached it.
        if DemoMode.isActive,
           let memory = try? ModelContainer(
               for: schema,
               configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)) {
            return memory
        }
        #endif
        let local = ModelConfiguration(schema: schema)
        // No crash path, and no wipe (QA 2026-10-03 F63). A store that won't open
        // (the Aug 22 3.0.0 (40) launch crash) is classified: a full disk keeps it
        // and runs this session in memory; a store this build can't read moves to
        // `Application Support/Recovered/`, its unsent changes are copied into the
        // rebuilt store, and sync re-downloads the rest. StoreRecovery logs it and
        // queues the root alert.
        return StoreRecovery.openContainer(schema: schema,
                                           migrationPlan: GLMigrationPlan.self,
                                           configuration: local,
                                           label: "launch")
    }()

    /// The GLSync engine, held for the app's lifetime. It has to live somewhere: its foreground and
    /// connectivity monitors capture `self` weakly, so dropping this reference would stop sync
    /// silently rather than loudly. Nothing reads it — `@State` is the lifetime, not a view input.
    init() {
        // Gold Life ID: one Stytch project shared with every Gold Life app, so one
        // person = one Gold Life ID. A 30-day rolling session (extended by the SDK's
        // heartbeat) is the "signed in until you say otherwise" behavior people
        // expect; must stay <= the Stytch dashboard's Frontend SDK session duration.
        // Configuring THIS (rather than calling StytchClient.configure directly)
        // also wires up GoldLifeID's shared identity/profile engine — the ONE
        // backend record every Gold Life app reads and writes (owner ruling
        // 2026-09-19, the cross-app profile-divergence fix). This app still owns
        // its own Apple/Google/email sign-in buttons (StytchClient.oauth.apple.start
        // is this app's own Stytch OAuth slot — see GoldLifeAuth.swift); only the
        // shared identity surface (the ID screen, its profile, deletion, and
        // account settings) has moved into the package so far.
        GoldLifeID.shared.configure(GoldLifeIDConfig(
            stytchPublicToken: LocalSecrets.stytchPublicToken,
            sessionDurationMinutes: 43_200,
            // Empty: this app attests Apple through its own native
            // oauth.apple.start slot, not the package's Trusted-Auth-attest
            // door — see the header comment above.
            appleTrustedAuthProfileID: "",
            googleTrustedAuthProfileID: LocalSecrets.googleTrustedAuthProfileId,
            // Read from Info.plist's GIDClientID — the Google SDK already
            // configures itself from it, so this app has never needed to pass
            // it explicitly. Kept here for the package's future Google door.
            googleClientID: Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "",
            identityBaseURL: LocalSecrets.workerURL,
            appID: MBHostDataErase.appID,
            // My Business's own row on the package's deletion screen erases in place
            // (audit 2026-10-03 F1): without it, that row could only say "open that app",
            // the app the person is already in, and the Gold Life ID could never go.
            eraseHostAppData: { try await MBHostDataErase.erase() },
            // Step two: once the package has deleted the Gold Life ID, My Business ends its own
            // session too (sign-in gate, sync, AI consent, local copy; audit 2026-10-03 C17).
            onIdentityDeleted: { await MBIdentityDeletion.finish() }
        ))
        GoldLifeID.shared.onExitSampleMode = {
            if UserDemoMode.shared.isDemoActive {
                UserDemoMode.shared.exitDemo()
            }
        }
        #if DEBUG
        // UI tests only: a fixed deletion inventory and Gold Life ID, so the deletion screen can be
        // walked with no account and no network. Its eraser runs the shipping erase on the mounted
        // demo store, with only the network step replaced (`MBHostDataErase.debugStubSteps`).
        if DemoMode.isActive { MBHostDataErase.debugDemoContainer = sharedModelContainer }
        if ProcessInfo.processInfo.arguments.contains("-uiTestStubGoldLifeIDDeletion") {
            GoldLifeID.shared.debugDeletionStub = .init(goldLifeID: "4821-9037", rows: [
                .init(appID: MBHostDataErase.appID, name: "My Business", holdsData: true),
                .init(appID: "my_ai", name: "Sentinel", holdsData: false),
            ])
        }
        if let email = ProcessInfo.processInfo.environment["GL_TEST_REMEMBERED_EMAIL"] {
            UserDefaults.standard.set(email, forKey: "gl_gate_remembered_email")
            UserDefaults.standard.set(email, forKey: "gl.gate.rememberedEmail")
            UserDefaults.standard.set(true, forKey: "mb.rememberDoor")
            UserDefaults.standard.set(true, forKey: "gl_gate_remember_door")
        }
        #endif
        // Law 59: GoldLifeUI's remote reads (About's app catalog + icons) ride
        // GoldLifeCloud's one road. Unset = GoldLifeUI makes no request at all.
        GLRemoteData.fetchData = { try await GLCloudTransport.fetchPublicData(from: $0) }
        GLAISystemBannersConfig.bannerBuilder = { AnyView(MBSystemBannerInset()) }
        // Before anything reads a preference: the law-26 key renames.
        DefaultsMigration.runIfNeeded()
        // Law 13 (owner ruling 2026-09-26): My Business's step in the fleet's one sign-out
        // wipe, registered before any session can end (GoldLifeCloud GLSessionWipe).
        MBSessionPurge.registerWipe()
        // The pre-v2 assistant consent key goes on first launch (contract §4): consent to the
        // OLD disclosure is not consent to this one.
        MBAssistantSession.removeLegacyConsent()
        // The launch lock is the app's ONE authentication now (2026-08-31), so
        // it defaults ON — seeded once, never overriding a deliberate choice.
        #if DEBUG
        // Under XCTest the unit host inherits the simulator's UserDefaults and
        // Keychain — two suites' worth of leftover state (suite review 2026-09-02).
        // Start each test process from a clean defaults domain and a private
        // Keychain service. Compiled out of Release.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            SecureTINStore.service = "GLSecureTIN.tests.\(ProcessInfo.processInfo.processIdentifier)"
            // The business Tax ID is keyed to a signed-in account; the unit host has none.
            SecureTINStore.setAccountScope("unit-tests")
        }
        // The screenshot harness runs with the gate off (no Gold Life ID), and its seed writes
        // a sample EIN; give it an account of its own so it never touches a real one.
        if DemoMode.isActive { SecureTINStore.setAccountScope("demo-mode") }
        // UI tests: XCUITest waits out every SwiftUI animation (~2.7s per event,
        // ~420s per run — suite review 2026-09-02). Compiled out of Release.
        if ProcessInfo.processInfo.arguments.contains("-uiTestNoAnimations") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        AppLockPrefs.seedDefaultIfNeeded()
        // Registers Italianno (from the GoldLifeUI package bundle) AND installs the
        // house nav-bar appearance (script at 48pt large / 28pt inline,
        // Dynamic-Type-scaled) — the shared entry point every Gold Life app calls,
        // replacing this app's former private copy of the same setup.
        GLScript.installNavigationBarAppearance()
        #if DEBUG
        if DemoMode.isActive {
            // Demo/screenshot runs never sync: the seed is fake data, and pushing it would put
            // invented customers in whatever Gold Life account the simulator happens to hold.
            DemoSeed.populate(sharedModelContainer.mainContext)
        }
        #endif
        // No backfills and no sync here any more. Under the hard gate the person's
        // data lives in their OWN store (UserScopedStore, keyed by canonical id),
        // which doesn't exist until they sign in — so the migrations and the sync
        // engine start when SignedInHost (GatePhase.swift) mounts that store, in
        // the same load-bearing order (SyncIdentityBackfill before the first
        // cycle). Running them here against sharedModelContainer worked on the
        // one store that nobody signed-in ever mounts.
    }

    var body: some Scene {
        WindowGroup {
            MBLocalizedRoot {
                GateView()
                // NO root `.tint` — deliberately (fleet rule, found on
                // iPad 2026-08-23): an adaptive Color handed to `.tint` above a
                // NavigationSplitView doesn't bridge to the sidebar's UIKit
                // collection view, which falls back to SYSTEM BLUE for the
                // selected row. The AccentColor asset carries the gold app-wide.
                // If a store had to be wiped-and-rebuilt (or fell back to memory)
                // on this launch, say so in plain English — the log line alone
                // isn't enough (alert AND log, always both).
                .modifier(StoreRecoveryAlert())
                .preferredColorScheme(effectivePreferredColorScheme)
                .environment(SubscriptionManager.shared)
                .environment(goldLifeAuth)
                // Gold Life ID (the HARD gate, law 11): resolve the session on launch and
                // re-check on foreground (the Keychain is only readable once unlocked),
                // route a dead session back to signed-out, and hand Google's OAuth
                // callback to its SDK. GateView walls the whole app on the outcome.
                // Registered with UIKit itself, NOT in GateView's scenePhase
                // handler. Proven on the simulator 2026-08-31: with the scene
                // lookup already fixed, a scenePhase-driven raise still produced
                // a snapshot showing the Menu sheet in full — SwiftUI's
                // `.onChange` runs after the scene delegate returns, which is
                // after iOS has taken the picture. See installAutoCover.
                .task {
                    GLPrivacyShield.installAutoCover(wordmark: "My Business", prefix: "mb") {
                        MBCoverCondition.appIsShowing
                    }
                }
                // iPad windows (F25): a window that comes forward, or is opened, while the
                // app is locked gets its own Face ID cover. Idempotent across windows.
                .task { GLLockWindow.observeScenes() }
                .task { await goldLifeAuth.resolve() }
                // One identity resolve at launch, and one per foreground below. GoldLifeID
                // never runs two identity refreshes at once and, for the same person,
                // refreshes at most once a minute, so the activation that comes with the
                // launch itself sends nothing more (audit 2026-10-03 F93).
                .task { await GoldLifeID.shared.resolve() }
                .task { GoldLifeAPI.onSessionExpired = { await goldLifeAuth.handleSessionExpired() } }
                .task { MBIdentityDeletion.auth = goldLifeAuth }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await goldLifeAuth.resolve() }
                        Task { await GoldLifeID.shared.resolve() }
                    }
                }
                .onChange(of: GoldLifeID.shared.sessionState) { _, state in
                    if state == .signedIn {
                        Task { await goldLifeAuth.resolve() }
                    }
                }
                .onOpenURL { _ = GoldLifeID.shared.handleOpenURL($0) }
                // The app-switcher cover is GLPrivacyShield (registered above) —
                // a window above `.alert` level, so it covers presented sheets
                // too. Deliberately NOT an overlay here.
            }
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - Erasing My Business's data from the Gold Life ID deletion screen

/// What My Business's own row on the GoldLifeID package's deletion screen runs (handed over as
/// `GoldLifeIDConfig.eraseHostAppData`; audit 2026-10-03 F1, REQUIREMENTS law 73). Step one of the
/// two-level deletion: My Business's data goes, the person stays signed in, and the Gold Life ID
/// itself (step two) unlocks once every app reads empty.
///
/// ORDER IS THE WHOLE POINT. Sync stops FIRST, so no cycle can push a record back up after the
/// backup is erased; the backup goes next (gl-business-api `DELETE /account`); only a finished
/// erase empties this iPhone's copy. A backup erase that did not finish (or a sync cycle that would
/// not stop) changes nothing here: sync starts again and the error reaches the screen, which says
/// the app still has the data. The local copy is emptied with the signed-in screens TAKEN DOWN
/// (`MBStoreRemount`, GatePhase.swift): emptying it under live screens trapped (C17 review
/// 2026-10-04). The same, now empty, store then mounts again with a fresh sync, and Delete Account
/// opens again for step two.
@MainActor
enum MBHostDataErase {
    /// Each step, injectable so the order can be tested without a network or a mounted store.
    struct Steps {
        /// Stop starting cycles and wait for one already running to finish. Throws when it would
        /// not finish in time: the backup is never erased under a cycle that is still pushing.
        var pauseSync: @MainActor () async throws -> Void
        /// Erase the server copy. Throws when it did not finish.
        var deleteBackup: @MainActor () async throws -> Void
        /// The erase did not go ahead: start syncing again, nothing else changed.
        var resumeSync: @MainActor () async -> Void
        /// The backup is gone: drop the session's sync token and caches.
        var endSync: @MainActor () async -> Void
        /// Empty this iPhone's copy (records, Tax IDs, the Stripe token, generated files), with the
        /// signed-in screens down, then mount the empty store again.
        var wipeLocalCopy: @MainActor () async -> Void
    }

    /// A sync cycle was still running when the erase wanted to start.
    struct SyncStillRunning: Error {}

    static func erase() async throws {
        #if DEBUG
        // UI tests only (-uiTestStubGoldLifeIDDeletion): the SAME sequence and the same local wipe
        // that ship, on the store that is mounted; only the network step (and the sync engine,
        // which a demo run never starts) is replaced (C17 review, 2026-10-04).
        if GoldLifeID.shared.debugDeletionStub != nil {
            try await erase(using: debugStubSteps)
            return
        }
        #endif
        try await erase(using: live)
    }

    #if DEBUG
    /// The store a demo/UI-test run mounts (the root's seeded container; there is no per-person
    /// store under -demoMode). Set once at launch, DEBUG only.
    static var debugDemoContainer: ModelContainer?

    /// `live` with the backup erase swapped for flipping the stubbed inventory row, and no sync
    /// calls. `wipeLocalCopy` is the shipping one.
    static var debugStubSteps: Steps {
        var steps = live
        steps.pauseSync = {}
        steps.resumeSync = {}
        steps.endSync = {}
        steps.deleteBackup = {
            guard var stub = GoldLifeID.shared.debugDeletionStub else { return }
            for index in stub.rows.indices where stub.rows[index].appID == appID { stub.rows[index].holdsData = false }
            GoldLifeID.shared.debugDeletionStub = stub
        }
        return steps
    }
    #endif

    /// The store the signed-in app is showing: the person's own, or (DEBUG demo runs) the seeded one.
    private static var mountedContext: ModelContext? {
        if let context = UserScopedStore.shared.activeMainContext { return context }
        #if DEBUG
        if DemoMode.isActive { return debugDemoContainer?.mainContext }
        #endif
        return nil
    }

    static func erase(using steps: Steps) async throws {
        do {
            try await steps.pauseSync()
            try await steps.deleteBackup()
        } catch {
            await steps.resumeSync()
            throw error
        }
        await steps.endSync()
        await steps.wipeLocalCopy()
    }

    /// The id the identity Worker lists My Business under (the one `GoldLifeIDConfig.appID` names).
    static let appID = "my-business"

    static var live: Steps {
        Steps(
            pauseSync: {
                guard let engine = UserScopedStore.shared.activeEngine else { return }
                await engine.stop()
                // A cycle already running can't be cancelled; give it up to 15 s to land so its
                // push happens BEFORE the erase. One still running after that stops the erase
                // (the person is told it didn't finish and can try again): a push that landed
                // after DELETE /account would put records back on the server.
                for _ in 0..<60 {
                    guard await engine.state == .syncing else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if await engine.state == .syncing { throw SyncStillRunning() }
            },
            deleteBackup: {
                // A one-shot transport: a fresh token provider mints a token for this call.
                try await GLSyncTransport(tokens: GLSyncTokenProvider()).deleteAccountData()
            },
            resumeSync: {
                await UserScopedStore.shared.activeEngine?.begin()
            },
            endSync: {
                await UserScopedStore.shared.activeEngine?.signedOut()
            },
            wipeLocalCopy: {
                // Handed to the gate, which takes the signed-in screens down first, runs this on
                // the now-unobserved store, then mounts it again (empty, with a fresh sync).
                await MBStoreRemount.shared.wipeWithScreensDown {
                    guard let context = mountedContext else { return }
                    // The Keychain items first, while the subcontractors that name their Tax ID
                    // keys can still be read (the same step a Gold Life ID deletion runs).
                    GoldLifeAuth.purgeAccountSecrets(scope: SecureTINStore.accountScope, context: context)
                    MBSessionPurge.clearContents(of: FileManager.default.temporaryDirectory)
                    wipeEveryRecord(in: context)
                }
            })
    }

    /// Every row of every model in the store, sync bookkeeping included, deleted and saved. The
    /// server copy is already erased, so this must NOT queue delete ops (`deleteSynced`) for it;
    /// with the bookkeeping gone too, the next sync starts fresh on an empty store. Run it only
    /// with no screen showing the store (`MBStoreRemount`): a row still on screen over a deleted
    /// record traps.
    static func wipeEveryRecord(in context: ModelContext) {
        func deleteAll<T: PersistentModel>(_ type: T.Type) {
            let rows = (try? context.fetch(FetchDescriptor<T>())) ?? []
            for row in rows { context.delete(row) }   // GLSYNC-LINT-OK: the server copy is already erased; queueing deletes for it would be wrong
        }
        for type in GLCurrentSchema.models { deleteAll(type) }
        do {
            try context.save()
        } catch {
            Logger(subsystem: "com.evolvedbygl.GLSmallBusiness", category: "HostDataErase")
                .error("local wipe after the backup erase could not save: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - The Gold Life ID itself is gone (step two)

/// What `GoldLifeIDConfig.onIdentityDeleted` runs once the GoldLifeID package's deletion screen has
/// deleted the Gold Life ID (audit 2026-10-03 C17). The package signs ITS engine out; My Business
/// keeps its own session (`GoldLifeAuth`), so without this the person stayed inside a signed-in My
/// Business for an identity that no longer exists. `GoldLifeAuth.deleteAccount` runs its teardown
/// only (the server is not called again): sign-in gate, sync stopped, assistant and AI consent
/// ended, entitlement cleared, secrets and the local copy wiped (laws 13, 73, 74).
@MainActor
enum MBIdentityDeletion {
    /// The app's one session, handed over by the root view once it is installed (a `@State` read
    /// from `App.init` would be a different instance).
    static weak var auth: GoldLifeAuth?

    static func finish() async {
        // Cannot throw: with `identityAlreadyDeleted` nothing in it calls the server.
        try? await auth?.deleteAccount(identityAlreadyDeleted: true)
    }
}
