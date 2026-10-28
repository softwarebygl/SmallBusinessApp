//
//  GLSyncEngine.swift
//  GLSmallBusiness
//
//  GLSYNC-SPEC.md §5, end to end. The engine is deliberately DUMB: it never resolves a
//  conflict, never computes a merge, never decides a winner. It ships changes, applies what
//  comes back, and surfaces what the server says was contested. All policy lives in the
//  Worker (gl-business-api), which is the one place it can be hotfixed without an app update.
//
//  ── SHAPE ────────────────────────────────────────────────────────────────────────────────
//  `GLSyncEngine` is an actor that owns the NETWORK and the schedule. Every line of SwiftData
//  work happens on `GLSyncLocalStore`, a @MainActor class, because this target compiles with
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — the @Models and their mappers are MainActor
//  types, and reaching them from a background actor would be a data race dressed as a
//  warning. Everything crossing between the two is a `Sendable` value type.
//
//  ── TRIGGERS ─────────────────────────────────────────────────────────────────────────────
//  App foreground · connectivity restored · ~5s debounce after an edit. NO POLLING, EVER.
//
//  ── THE FOUR RULES THAT ARE EASY TO GET WRONG ────────────────────────────────────────────
//  1. Pulled rows overwrite CLEAN local records. A record with a pending outbox entry is
//     SKIPPED — it reconciles at the next push, where the server merges per field. This is
//     the one non-obvious client rule in the whole protocol (§5.4).
//  2. Cursor and history token advance TOGETHER, and only after the round trip lands (§5.5).
//     Replaying a history window is free (the outbox coalesces); losing one is not.
//  3. Pulled changes are applied through a context stamped `author = "gl-sync"`. Without it
//     every applied change echoes straight back into the outbox as a fresh local edit
//     (GLSYNC-SPEC.md §2a, trap 1).
//  4. The mass-delete circuit breaker refuses the WHOLE pull rather than half of it. A
//     server bug then costs one paused device, not a wiped business.
//

import CryptoKit
import Foundation
import Network
import OSLog
import os
import SwiftData
import GoldLifeUI
import GoldLifeCloud
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public state

/// Thrown to unwind a cycle that has already set a terminal state (the circuit breaker).
/// Distinct from `CancellationError` so the catch site does not helpfully reset `.paused`
/// back to `.idle`.
nonisolated struct GLSyncHalted: Error {}

nonisolated enum GLSyncTrigger: String, Sendable {
    case foreground, connectivity, edit, manual, bootstrap
}

nonisolated enum GLSyncEngineState: Sendable, Equatable {
    case idle
    case syncing
    /// No Gold Life ID session. NOT an error — the app is fully usable, local-only, and shows
    /// a gentle "Not backed up" (GLSYNC-SPEC.md §4). Never a nag, never a block.
    case signedOut
    /// Offline, or the last attempt failed for a reason time might fix. Work is queued.
    case waiting
    /// The circuit breaker tripped, or the store diverged in a way we refuse to guess about.
    /// Carries the sentence the user sees.
    case paused(String)
}

/// A quiet entry for the Recent Changes list: a field this device lost on last-writer-wins,
/// or a protected money field the server surfaced instead of merging. Never a modal.
nonisolated struct GLSyncRecentChange: Sendable, Identifiable {
    nonisolated enum Kind: Sendable { case lostToOtherDevice, contested }
    let id = UUID()
    let recordID: UUID
    let recordType: String
    let field: String
    let serverValue: String
    let kind: Kind
    let at: Date
}

/// Something the person needs to read, already in plain English.
nonisolated struct GLSyncUserMessage: Sendable, Identifiable {
    let id = UUID()
    let recordID: UUID?
    let recordType: String?
    let text: String
    let at: Date
}

// MARK: - Values crossing the actor boundary

nonisolated struct GLSyncPersistedState: Sendable {
    let cursor: Int
    let historyToken: Data?
    let deviceID: UUID
    let lastSyncAt: Date?
    let lastChecksumAt: Date?
    let bootstrapComplete: Bool
    /// The model shape `historyToken` was written under. A mismatch means the token's history
    /// cannot be READ without trapping inside SwiftData — see GLSyncState.historySchemaFingerprint.
    let historyFingerprint: String?
    /// The Gold Life ID this cursor belongs to, or nil on a store that has never synced.
    let ownerID: String?
    /// Set while the mass-delete breaker is tripped. Survives relaunch on purpose — see
    /// `GLSyncState.breakerTrippedAt`.
    let breaker: GLSyncBreakerTrip?
    /// This store already holds a PREVIOUS owner's records, so the first-run upload must not
    /// run again and push them into the account now signed in.
    let suppressBootstrapUpload: Bool
}

/// What the mass-delete breaker saw when it stopped. Carried to the UI so the sentence the
/// person reads names a number rather than a shrug.
nonisolated struct GLSyncBreakerTrip: Sendable, Equatable {
    let deletions: Int
    let threshold: Int
    let at: Date
}

nonisolated struct GLSyncFoldResult: Sendable {
    let newHistoryToken: Data?
    let enqueued: Int
    /// Deletes history could not name (see `GLSyncLocalStore.fold`). Non-zero means the local
    /// store and the server have silently diverged for those rows.
    let unresolvedDeletes: Int
}

/// Where one cycle's folds have read history up to (QA 2026-10-03 F16). A cycle now folds
/// before EVERY pull it applies, so each fold must start where the previous one stopped, and
/// the cursor commit must carry the newest folded token — not the first.
nonisolated struct GLSyncFoldWindow: Sendable {
    /// What the next fold reads from: the newest token any fold this cycle returned, else
    /// the committed one.
    private(set) var readFrom: Data?
    /// The shape `readFrom` was written under. A token a fold just returned is this build's.
    private(set) var fingerprint: String?
    /// The newest folded token not yet committed with a cursor. Nil = nothing new to commit.
    private(set) var uncommitted: Data?
    /// At least one fold ran this cycle.
    private(set) var hasFolded = false

    init(committed token: Data?, writtenUnder fingerprint: String?) {
        readFrom = token
        self.fingerprint = fingerprint
    }

    /// A nil watermark is read exactly once per cycle, as before this change: that read PURGES
    /// history first (`GLSyncHistory.changes`), so repeating it mid-cycle would destroy edits
    /// saved in between instead of folding them.
    var canFoldAgain: Bool { readFrom != nil || !hasFolded }

    mutating func folded(through token: Data?) {
        hasFolded = true
        guard let token else { return }   // nil = history had nothing new: keep reading from here
        readFrom = token
        uncommitted = token
        fingerprint = GLSyncHistory.schemaFingerprint
    }

    mutating func committed() { uncommitted = nil }
}

nonisolated struct GLSyncBlobUpload: Sendable {
    let recordID: UUID
    let recordType: String
    let field: String
    let sha256: String
    let name: String
    let bytes: Data
}

nonisolated struct GLSyncBlobFetch: Sendable, Hashable {
    let recordID: UUID
    let recordType: String
    let field: String
    let sha256: String
}

nonisolated struct GLSyncPushOutcome: Sendable {
    let messages: [GLSyncUserMessage]
    let recentChanges: [GLSyncRecentChange]
    let cleared: Int
    let parked: Int
    /// Ops refused for a lapsed subscription, HELD (not parked) for a later cycle. The engine
    /// does not offer them again in the cycle that was just refused (QA 2026-10-03 F17).
    var heldOpIDs: Set<UUID> = []
}

nonisolated struct GLSyncPullOutcome: Sendable {
    let applied: Int
    let skipped: Int
    let deleted: Int
    let unknownType: Int
    let blobFetches: [GLSyncBlobFetch]
    let maxSeq: Int
    /// Children whose cascade parent had not arrived yet. Retried after the next page.
    let unlinked: [GLSyncParentLink]
}

/// A pull is all-or-nothing: the breaker judges the WHOLE page before a single row lands.
nonisolated enum GLSyncPullVerdict: Sendable {
    case applied(GLSyncPullOutcome)
    case massDeleteRefused(deletions: Int, threshold: Int)
}

// MARK: - The engine

actor GLSyncEngine {

    // ── THE ENTRY POINT ──────────────────────────────────────────────────────────────────
    //
    /// Build the engine and start listening for triggers. Called **once**, from
    /// `GLSmallBusinessApp.startSync()` — the last step of the launch sequence, after
    /// `SyncIdentityBackfill` has minted the `syncID`s every op is addressed by. WIRED IN as of
    /// the CloudKit-removal release (GLSYNC-SPEC.md §7); the container it is handed is local-only
    /// now, so nothing else replicates the same store.
    ///
    /// The app holds the returned engine for its lifetime (the trigger monitors capture `self`
    /// weakly, so dropping it stops sync silently).
    ///
    /// The app's only other obligations are `noteEdit()` after a user save and
    /// `enqueueDelete(_:)` BEFORE deleting a record (see that method for why it cannot be
    /// after) — neither is wired up yet.
    @MainActor
    @discardableResult
    static func attach(to container: ModelContainer) -> GLSyncEngine {
        let engine = GLSyncEngine(container: container)
        current = engine
        Task { await engine.begin() }
        return engine
    }

    /// The engine this process attached, so the parts of the app that are not the sync layer
    /// can reach it — sign-out, session expiry, account deletion, and the "continue" button on
    /// a tripped circuit breaker. Weak because `GLSmallBusinessApp` owns the lifetime; a strong
    /// static would keep an engine (and its monitors) alive past a test that built one.
    @MainActor private(set) static weak var current: GLSyncEngine?

    // MARK: Configuration

    /// Ops per request. The Worker hard-caps at 200; 50 is the README's chunk size and one
    /// `db.batch()` on the far side.
    private static let opsPerChunk = 50
    /// Snapshot page size. Matches the Worker's own default.
    private static let snapshotPageSize = 500
    /// The pull page size the Worker uses. A FULL page means "probably more", so the engine
    /// immediately goes round again from the new cursor.
    private static let pullPageSize = 500
    /// Extra push rounds a cycle runs for edits folded while it was running (F16).
    private static let maxFoldDrivenRounds = 5
    /// ~5s after an edit, coalescing. Thirty saves while editing an invoice = one cycle.
    private static let editDebounce: Duration = .seconds(5)
    /// ~24h between checksum self-heal comparisons.
    private static let checksumInterval: TimeInterval = 24 * 60 * 60
    /// Carried-over blob downloads retried per cycle. Uploads and downloads share one
    /// `attach:` bucket (300 per 15 minutes), so a backlog is spread instead of spent at once.
    /// New fetches are never capped — a bootstrap must bring every file down in one pass.
    private static let blobRetriesPerCycle = 25
    /// History older than this is pruned after a successful push. Comfortably behind the
    /// persisted token so a long-offline device still finds its window intact — nothing else
    /// trims the table once the CloudKit mirroring delegate is gone (§2a, trap 3).
    private static let historyRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Recent Changes / message ring size. These are a log, not a database.
    private static let logCapacity = 200

    // MARK: State

    private let store: GLSyncLocalStore
    private let tokens: GLSyncTokenProvider
    private let transport: GLSyncTransport

    private(set) var state: GLSyncEngineState = .idle
    private(set) var recentChanges: [GLSyncRecentChange] = []
    private(set) var messages: [GLSyncUserMessage] = []

    // Per-record server versions live in the STORE, not here: `GLSyncRecordVersion` plus the
    // write-through cache in `GLSyncLocalStore`. They were an actor-local dictionary once,
    // which meant the first edit to an already-synced record after every cold launch pushed
    // `base_version: 0` and got its money fields contested for no reason.

    /// The document key and the envelope format for `tax`-class blobs — today exactly
    /// `Subcontractor.w9Data`, the W-9 PDF. Held by the engine and never by the store,
    /// because the key is a network fact with a process lifetime and SwiftData must never see
    /// it. gl-business-api refuses a tax attachment that is not client-encrypted, so this is
    /// what makes a subcontractor's W-9 syncable at all instead of device-only.
    private let documents: GLSyncDocumentCrypto

    /// Blob hashes uploaded during THIS session. R2 is content-addressed and dedupes, so a
    /// repeat upload is correct but wasteful; a relaunch re-uploads once and that is fine.
    /// Encrypted documents seal DETERMINISTICALLY (GLSyncDocumentEnvelope), so their envelope
    /// hash is stable across seals and dedupes here exactly like a plaintext one.
    private var uploadedHashes: Set<String> = []

    /// Blob downloads still owed. A pulled row is applied whether or not its file arrives, and
    /// the row will not be pulled a second time, so a fetch that failed for a reason time
    /// might fix has to be carried forward or the file is missing until that record next
    /// changes on another device. Bounded by the account's blob count: entries are keyed by
    /// record + field + hash, so a repeated pull re-adds the same one.
    private var pendingBlobFetches: Set<GLSyncBlobFetch> = []

    /// Children pulled ahead of their parents. Retried after every page — across pages as
    /// well as within one, because seq is write order, not tree order.
    private var pendingLinks: Set<GLSyncParentLink> = []

    /// A cycle is running. Not a lock — the actor is free during every `await`, so a second
    /// trigger would otherwise walk straight into the middle of the first cycle.
    private var isCycling = false
    /// The running cycle, so signing out can end it (QA 2026-10-03 F18). Its own task, not the
    /// trigger's: cancelling a debounce or a stopped trigger loop must not abort a push half way.
    private var cycle: Task<Void, Error>?
    /// The running cycle's road out, bound to the person it started for. Nil between cycles, so
    /// nothing in a cycle can reach the network except through it.
    private var cycleTransport: GLSyncTransport?
    private var debounce: Task<Void, Never>?
    /// Sign-out's last push (`flushBeforeSignOut`), so `signedOut()` can end it.
    private var signOutFlush: Task<Void, Never>?
    private var monitors: [Task<Void, Never>] = []
    private var pathMonitor: NWPathMonitor?
    private var wasOffline = false

    init(container: ModelContainer) {
        self.init(container: container, tokens: GLSyncTokenProvider(), cloud: .shared,
                  documents: GLSyncDocumentCrypto())
    }

    /// The seam a test drives a whole cycle through: its own token provider (over a stub
    /// session) and its own road out. The app always takes the one above.
    init(container: ModelContainer, tokens: GLSyncTokenProvider, cloud: GLCloudTransport,
         documents: GLSyncDocumentCrypto) {
        self.tokens = tokens
        self.store = GLSyncLocalStore(container: container)
        self.transport = GLSyncTransport(tokens: tokens, cloud: cloud)
        self.documents = documents
    }

    /// The running trigger loops. Read by the teardown tests, which must see every one end.
    var triggerTasks: [Task<Void, Never>] { monitors }

    /// An engine nobody holds any more stops listening (QA 2026-10-03 F150). The loops hold it
    /// weakly and leave when they find it gone, but only on their next notification; the path
    /// monitor may never send one. Every sign-in attaches a new engine, so without this a shared
    /// iPad collected a monitor and four parked loops per sign-in.
    deinit {
        monitors.forEach { $0.cancel() }
        pathMonitor?.cancel()
        debounce?.cancel()
    }

    // MARK: - Triggers

    /// Start the triggers and run one cycle. Idempotent.
    func begin() async {
        guard monitors.isEmpty else { return }
        startForegroundTrigger()
        startConnectivityTrigger()
        startBackgroundFlushTrigger()
        startEditObserver()
        startEntitlementTrigger()
        await sync(trigger: .foreground)
    }

    /// Call after a user-visible save. Coalesces: thirty saves in a minute produce ONE cycle.
    func noteEdit() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.editDebounce)
            guard !Task.isCancelled else { return }
            await self?.sync(trigger: .edit)
        }
    }

    /// Fold the edits saved since the last fold into the outbox, locally (QA 2026-10-03 F12).
    /// The sign-out warning calls this before it counts, so an edit saved a second ago is
    /// counted. No network, no token, and it runs while the breaker is paused too. Returns how
    /// many rows it queued.
    @discardableResult
    func foldNow() async -> Int {
        await store.foldPendingEdits()
    }

    /// How long a sign-out waits for its last push before it wipes anyway.
    static let signOutFlushLimit: Duration = .seconds(5)

    /// Sign-out's last push, BEFORE `signedOut()` and the wipe (QA 2026-10-03 F12). Signing out
    /// used to cancel the pending edit debounce and wipe straight after, so an edit saved
    /// seconds before was never pushed and the wipe lost it.
    ///
    /// Folds first (local), then, when online, waits for a cycle already running and runs one
    /// more, so an edit saved during it goes too. The cycle is bound to the person signing out
    /// (QA 2026-10-03 F18), and gives up at `limit`: a sign-out on weak signal still finishes.
    /// The push carries on past the limit until `signedOut()` cancels it. Answers true when
    /// the push finished in time. Offline, or with the breaker paused, nothing goes out, and
    /// the Menu's warning already counted what is left.
    @discardableResult
    func flushBeforeSignOut(limit: Duration = GLSyncEngine.signOutFlushLimit) async -> Bool {
        debounce?.cancel()
        debounce = nil
        await foldNow()
        let isConnected = await MainActor.run { NetworkMonitor.shared.isConnected }
        guard isConnected else { return false }
        let flush = Task { await self.pushForSignOut() }
        signOutFlush = flush
        return await GLDeadline.wait(atMost: limit) { await flush.value }
    }

    /// The flush's push: after any cycle already running, one more of its own.
    private func pushForSignOut() async {
        while isCycling {
            if Task.isCancelled { return }
            if let running = cycle {
                _ = await running.result
            } else {
                // The running cycle has ended and `sync` is finishing its bookkeeping.
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return }
        await sync(trigger: .manual)
    }

    /// Sign-out, session expiry, or account deletion: stop syncing NOW and forget everything
    /// this session earned.
    ///
    /// Called from `GoldLifeAuth` on all three paths. Until it was wired up, signing out left
    /// the engine running on a cached 15-minute app token: hand the phone to somebody who signs
    /// in with their own Gold Life ID and, for the rest of that window, their invoices uploaded
    /// into the previous owner's account and any W-9 was sealed with the previous owner's
    /// document key — unreadable to them forever.
    ///
    /// Order matters. The pending edit debounce is cancelled first so a save from a second ago
    /// cannot start a cycle behind this call; a cycle already running is cancelled next, so it
    /// stops between rounds and before its next upload instead of carrying on into the next
    /// person's session (QA 2026-10-03 F18 — its requests are bound to this person as well, so
    /// even a request already on its way cannot go out under anybody else). Sign-out's final
    /// push (`flushBeforeSignOut`) runs BEFORE this call; one still running is ended here too.
    /// The token goes after that, which is what makes every
    /// later request answer `.signedOut` instead of presenting a credential for an identity
    /// that no longer has a session.
    func signedOut() async {
        debounce?.cancel()
        debounce = nil
        signOutFlush?.cancel()
        signOutFlush = nil
        cycle?.cancel()
        await tokens.invalidate()
        // The document key is derived from the canonical id, so keeping a cached one across a
        // change of account would seal the next person's W-9 under this person's key.
        await documents.invalidate()
        // Session-scoped caches. `uploadedHashes` in particular is a promise about what THIS
        // account's blob store already holds, and it is not a promise about the next one's.
        uploadedHashes = []
        // The blob-hash cache keeps this person's document bytes as its keys.
        GLSyncBlobHashCache.removeAll()
        pendingBlobFetches = []
        pendingLinks = []
        state = .signedOut
        await MainActor.run {
            GLSyncStatus.shared.clear()
            // The next person on this phone must never read this person's refusals.
            GLSyncStatus.shared.clearMessages()
        }
    }

    /// The person read the pause and asked to carry on. Arms a ONE-TIME override, clears the
    /// pause, and syncs immediately so the answer is visible rather than pending.
    func resumeAfterReview() async {
        await store.armBreakerOverride()
        await MainActor.run { GLSyncStatus.shared.clear() }
        if case .paused = state { state = .idle }
        await sync(trigger: .manual)
    }

    /// Stop, and say why in a sentence a person can act on.
    ///
    /// `announce: false` is the relaunch path — the pause is being restored from disk, and
    /// re-appending the same sentence on every launch would turn one event into a log of them.
    private func pause(deletions: Int, threshold: Int, announce: Bool) {
        let text = Self.pauseMessage(deletions: deletions)
        state = .paused(text)
        if announce {
            note(GLSyncUserMessage(recordID: nil, recordType: nil, text: text, at: .now))
        }
        let trip = GLSyncBreakerTrip(deletions: deletions, threshold: threshold, at: .now)
        Task { @MainActor in GLSyncStatus.shared.setPausedByMassDelete(trip) }
    }

    /// Plain English, and it names the ONE thing to do about it. The old sentence — "Sync
    /// paused — something looked wrong." — told a person nothing and offered nowhere to go.
    nonisolated static func pauseMessage(deletions: Int) -> String {
        MBLocalization.string(
            "Backup is paused. Another device deleted \(deletions) items at once, so this device stopped instead of copying that. Open Settings to review and continue.")
    }

    private func startForegroundTrigger() {
        #if canImport(UIKit)
        let task = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification)
            for await _ in notifications {
                guard let self else { break }
                await self.sync(trigger: .foreground)
            }
        }
        monitors.append(task)
        #endif
    }

    /// A save then an immediate close is a normal move — "entered my name,
    /// closed the app" is exactly how build 48's name save was lost (the edit
    /// debounce was still counting down, and nothing flushes on the way out; a
    /// deleted app then had the only copy). Backgrounding now flushes a PENDING
    /// edit at once, under a background-task assertion so the push can finish
    /// after the screen goes away. No pending edit = no cycle: the foreground
    /// trigger already owns general freshness, and backgrounding must not cost
    /// a network round-trip every time.
    /// ROOT FIX (2026-08-30 night): nothing in the app ever called `noteEdit()` —
    /// the ~5s edit debounce was dead code, so a save only ever synced on the NEXT
    /// foreground. "Set your name, delete the app" never got a push cycle at all.
    /// The engine now watches SwiftData saves itself (one choke point, no call-site
    /// sweep to forget): every save from any context except the engine's own apply
    /// context arms the debounce.
    private func startEditObserver() {
        let task = Task { [weak self] in
            let saves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            for await note in saves {
                guard let self else { break }
                if let saved = note.object as? ModelContext, await self.store.owns(saved) { continue }
                await self.noteEdit()
            }
        }
        monitors.append(task)
    }

    private func startBackgroundFlushTrigger() {
        #if canImport(UIKit)
        let task = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification)
            for await _ in notifications {
                guard let self else { break }
                await self.flushPendingEditOnBackground()
            }
        }
        monitors.append(task)
        #endif
    }

    #if canImport(UIKit)
    private func flushPendingEditOnBackground() async {
        guard debounce != nil else { return }
        debounce?.cancel()
        debounce = nil
        let assertion = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "GLSyncEditFlush")
        }
        await sync(trigger: .edit)
        if assertion != .invalid {
            await MainActor.run { UIApplication.shared.endBackgroundTask(assertion) }
        }
    }
    #endif

    private func startConnectivityTrigger() {
        // Iterating an NWPathMonitor starts it; calling `start(queue:)` as WELL would arm it
        // twice. Cancelling the task ends the monitor.
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let task = Task { [weak self] in
            for await path in monitor {
                guard let self else { break }
                await self.pathChanged(satisfied: path.status == .satisfied)
            }
        }
        monitors.append(task)
        
        let networkRestoredTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Notification.Name("glNetworkRestored")) {
                guard let self else { break }
                await self.sync(trigger: .connectivity)
            }
        }
        monitors.append(networkRestoredTask)
    }

    /// Stop listening: every trigger loop, the path monitor and a pending edit. The session wipe
    /// calls it on the engine it drops (QA 2026-10-03 F150), and account deletion calls it
    /// before erasing. A cycle already running is left to finish (account deletion waits for
    /// it); `signedOut()` is what ends one.
    func stop() {
        debounce?.cancel()
        monitors.forEach { $0.cancel() }
        monitors = []
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// Only the offline→online EDGE triggers a cycle. Wi-Fi handoffs fire this constantly.
    private func pathChanged(satisfied: Bool) async {
        guard satisfied else {
            wasOffline = true
            return
        }
        guard wasOffline else { return }
        wasOffline = false
        await sync(trigger: .connectivity)
    }

    // MARK: - The cycle

    /// One full round: fold → (bootstrap, folding before each page) → push (chunked) → apply
    /// results → fold → apply pulled changes → advance → prune → maybe self-heal. Safe to call
    /// from any trigger at any time.
    func sync(trigger: GLSyncTrigger) async {
        guard !isCycling else { return }
        // The breaker holds until a PERSON says continue (`resumeAfterReview`). It used to hold
        // only until relaunch, which sounds gentler and was in fact the trap: the pause was
        // in-memory, so a relaunch reset to `.idle`, re-pulled the same page from the same
        // un-advanced cursor, and tripped again — forever, with nothing on screen.
        if case .paused = state { return }
        
        // NetworkMonitor is @MainActor (it backs UI observation) and this is an actor, so the
        // read has to hop.
        let isConnected = await MainActor.run { NetworkMonitor.shared.isConnected }
        guard isConnected else {
            state = .waiting
            return
        }
        
        isCycling = true
        defer { isCycling = false }

        state = .syncing
        let run = Task { try await self.runCycle(trigger: trigger) }
        cycle = run
        let outcome = await run.result
        cycle = nil
        cycleTransport = nil
        // Signing out cancelled it. `signedOut()` already set the state; whatever the cycle
        // threw on its way out (a cancelled request reads as a dropped connection) must not
        // overwrite that or put a sentence on screen.
        if run.isCancelled {
            state = .signedOut
            return
        }
        do {
            try outcome.get()
            // Only a cycle that is STILL `.syncing` actually finished one: `runCycle` sets
            // `.signedOut` when there is no session, and the breaker sets `.paused`. Stamping
            // `lastSyncAt` in either case would claim a backup that never happened.
            //
            // And only when nothing is left to send but parked rows (QA 2026-10-03 F88): a
            // cycle whose edits were refused for a lapse, or held back for a document key, or
            // cut off at the round cap, finished without backing them up.
            if state == .syncing {
                state = .idle
                await store.stampSyncedIfDrained()
            }
        } catch is GLSyncHalted {
            // The state is already `.paused`; leaving it alone IS the handling.
        } catch is CancellationError {
            state = .idle
        } catch let error as GLSyncTransportError {
            handle(error)
        } catch let error as GLSyncHistoryError {
            // Both history errors mean the same thing: the saved bookmark cannot be trusted.
            // Drop it and re-bootstrap rather than reporting "nothing changed" forever.
            await store.dropHistoryTokenAndRebootstrap()
            note(GLSyncUserMessage(recordID: nil, recordType: nil,
                                   text: error.errorDescription
                                       ?? MBLocalization.string("Sync is starting over."),
                                   at: .now))
            state = .waiting
        } catch {
            state = .waiting
        }
    }

    private func runCycle(trigger: GLSyncTrigger) async throws {
        // Signed out is a STATE, not a failure. Nothing below runs, nothing is lost, and the
        // app carries on local-only.
        guard let binding = try await tokens.cycleBinding() else {
            // Belt and braces with `signedOut()`: a session that ends without going through
            // that call must not leave the previous account's document key in memory.
            await documents.invalidate()
            state = .signedOut
            return
        }
        let owner = binding.owner
        // Every request this cycle makes answers to `owner` or does not go out (F18): the
        // provider re-reads the live session on each one, and a cycle that outlives its person
        // must not re-mint for the next and push this person's records into their account.
        cycleTransport = transport.bound(to: binding)

        // Before anything is read or pushed: whose account is this? `owner` is the app token's
        // verified `sub`, which is the exact id gl-business-api partitions records by — so
        // binding to it means the persisted cursor can never belong to somebody else.
        if await store.bind(owner: owner) {
            // A different person is signed in now. Their W-9s must not be sealed with the
            // previous person's key, and nothing cached from the old session may be reused.
            await documents.invalidate()
            uploadedHashes = []
            GLSyncBlobHashCache.removeAll()
            pendingBlobFetches = []
            pendingLinks = []
        }

        var persisted = await store.persistedState()

        // Edits an older build PARKED for a lapse (it parked every refusal) are released into
        // held rows: the Worker never cached those refusals, so the same op ids may land now
        // (QA 2026-10-03 F17). Cheap and idempotent; the server stays the judge.
        await store.releaseLapseParks()

        // The breaker stopped this device on a previous run and nobody has looked yet. Staying
        // paused is the whole point — an in-memory-only pause forgot on relaunch, re-pulled the
        // same page from the same un-advanced cursor, and tripped again forever with nothing on
        // screen to say so.
        if let trip = persisted.breaker {
            pause(deletions: trip.deletions, threshold: trip.threshold, announce: false)
            throw GLSyncHalted()
        }

        // CRASH-LOOP BREAKER (2026-09-01, the build-62 address SIGTRAP). The sentinel was
        // set before a history read and never cleared: the last run died INSIDE
        // `fetchHistory` — an uncatchable trap, so no catch block ever saw it. Reading
        // again would crash identically on the same row, every launch, until the person
        // deletes the app. So don't read: purge (`deleteHistory` never materializes a
        // transaction) and re-upload the whole store — the same lossless path a schema
        // change takes. Alert AND log, per the house rule.
        if await store.foldSentinelTripped() {
            Logger.data.error("glsync fold_sentinel_tripped: previous run died inside a history read — purging history and re-baselining instead of reading")
            await store.rebaselineHistory()
            await store.clearFoldSentinel()
            persisted = await store.persistedState()
            await StoreRecovery.noteSyncRepaired()
        }

        // ROOT FIX (2026-08-30 night, the name-never-reached-the-server bug): the
        // history watermark must leave nil EXACTLY ONCE, up front — the old design
        // left it nil forever (a nil-token fold purged all history BEFORE reading
        // it and returned no token; advance() never persists nil), so every cycle
        // destroyed the person's un-folded edits unread and pushed nothing.
        // Establishing the baseline BEFORE bootstrap also means edits made while
        // the first pull is still running land AFTER the watermark and fold
        // normally (since F16, before the very next page is applied).
        if persisted.historyToken == nil {
            await store.establishHistoryBaseline()
            persisted = await store.persistedState()
        }

        // The app UPDATED since this token was written, so its history refers to a model shape
        // this build no longer has. Reading it is not a recoverable error — it TRAPS inside
        // SwiftData (3.0.0 build 42 crashed at launch for every device upgrading from 41). So
        // re-baseline instead: drop the unreadable watermark and re-upload the local store, which
        // is what `bootstrap` already does for a first run. What the outbox holds is safe; an
        // edit still only in that unreadable history is not, because nothing can read it.
        //
        // Checked BEFORE bootstrap and before the first fold (F16): both need a readable token.
        if persisted.historyToken != nil,
           !GLSyncHistory.canReadHistory(writtenUnder: persisted.historyFingerprint) {
            Logger.data.error(
                "glsync history_schema_changed: token written under \(persisted.historyFingerprint ?? "pre-fingerprint", privacy: .public), this build is \(GLSyncHistory.schemaFingerprint, privacy: .public) — re-baselining, not reading")
            await store.rebaselineHistory()
            await store.establishHistoryBaseline()   // straight back onto a real watermark
            persisted = await store.persistedState()
        }

        // FIRST fold, ahead of bootstrap (QA 2026-10-03 F16). A re-bootstrap (checksum drift,
        // a cursor gap) applies snapshot pages over the local store; an edit still only in
        // history would be overwritten by the server's older copy, and the bootstrap diff that
        // follows would then find nothing to send. Folded first, the edit is an outbox row and
        // every pull skips it.
        var window = GLSyncFoldWindow(committed: persisted.historyToken,
                                      writtenUnder: persisted.historyFingerprint)
        try await foldBeforeApplying(&window)

        if !persisted.bootstrapComplete {
            try await bootstrap(&persisted, window: &window)
        }

        try await pushAndPull(state: &persisted, window: &window)
        try Task.checkCancellation()

        // Only after the round trip landed. Nothing else trims persistent history now that
        // the CloudKit mirroring delegate is gone.
        await store.pruneHistory(before: Date().addingTimeInterval(-Self.historyRetention))

        try await selfHealIfDue(persisted)
    }

    // MARK: Push + pull

    private func pushAndPull(state persisted: inout GLSyncPersistedState,
                             window: inout GLSyncFoldWindow) async throws {

        var rounds = 0
        var foldDrivenRounds = 0
        // Ops refused for a lapse this cycle. They are retried on the NEXT cycle; offering them
        // again in this one would only be refused again, round after round, up to the cap.
        var heldThisCycle: Set<UUID> = []
        // A bound, not a schedule: each round either drains ops or advances the cursor, so
        // this terminates on its own. The cap only stops a server that never advances from
        // spinning the device's battery flat.
        let maxRounds = 200

        repeat {
            // Signed out between rounds: stop before the next push (F18).
            try Task.checkCancellation()
            rounds += 1
            let ops = await store.pendingOps(limit: Self.opsPerChunk, excluding: heldThisCycle)

            // Blob bytes must be on the server BEFORE the payload that references them, or a
            // pulled row points at an attachment that 404s.
            let sanitized = try await uploadBlobs(for: ops)

            try Task.checkCancellation()
            let response = try await wire().sync(
                deviceID: persisted.deviceID, cursor: persisted.cursor, ops: sanitized)

            let push = await store.applyResults(response.results, for: sanitized)
            heldThisCycle.formUnion(push.heldOpIDs)
            record(push.recentChanges)
            push.messages.forEach(note)
            // The server's refusals and conflicts, on screen (QA 2026-10-03 F87, law 6). They
            // were collected here and read by nothing, so a contested price reverted silently.
            announce(push.messages)

            // F16: AFTER the results (an edit folded now opens a fresh row at the version the
            // server just reported, instead of coalescing into the op it already judged) and
            // immediately BEFORE the pull — the server echoes this device's own writes, and
            // that echo must not land on an edit saved while the request was on the wire.
            let folded = try await foldBeforeApplying(&window)

            let verdict = await store.applyChanges(response.changes)
            switch verdict {
            case .massDeleteRefused(let deletions, let threshold):
                // GLSYNC-SPEC.md §5. The cursor is NOT advanced and the history token is NOT
                // committed, so nothing is lost — the device simply stops until a human looks.
                pause(deletions: deletions, threshold: threshold, announce: true)
                NSLog("glsync: mass-delete breaker tripped (%d deletions, threshold %d)",
                      deletions, threshold)
                throw GLSyncHalted()

            case .applied(let pull):
                await absorb(pull)

                // §5.5 — together, transactionally, and only now. The newest folded token: every
                // window up to it is in the outbox, which is where unsent work lives.
                await store.advance(cursor: response.newCursor, historyToken: window.uncommitted)
                persisted = GLSyncPersistedState(
                    cursor: response.newCursor,
                    historyToken: window.uncommitted ?? persisted.historyToken,
                    deviceID: persisted.deviceID,
                    lastSyncAt: persisted.lastSyncAt,
                    lastChecksumAt: persisted.lastChecksumAt,
                    bootstrapComplete: persisted.bootstrapComplete,
                    // Carried for the same reason as the rest: this page said nothing about the
                    // model shape the token was written under.
                    historyFingerprint: persisted.historyFingerprint,
                    // Carried, never recomputed: a successful page says nothing about who owns
                    // the cursor, whether the breaker is tripped, or whether this store still
                    // holds a previous owner's rows. Dropping any of them here would silently
                    // re-arm the very defects this pass fixed.
                    ownerID: persisted.ownerID,
                    breaker: persisted.breaker,
                    suppressBootstrapUpload: persisted.suppressBootstrapUpload)
                // Committed. The next round folds on from `window.readFrom`, never back over
                // a window already consumed.
                window.committed()

                // `sanitized`, not `ops`: a chunk held back ENTIRELY for encryption cleared
                // nothing, so going round again would re-ask the same question up to the round
                // cap. The next trigger retries it, which is what "later" means here.
                let moreToPush = ops.count >= Self.opsPerChunk && !sanitized.isEmpty
                let morePulled = response.changes.count >= Self.pullPageSize
                // An edit folded mid-cycle is pushed in THIS cycle: the save's own trigger was
                // dropped while the cycle ran. Bounded, so an app write that answers every pull
                // with a save cannot spin rounds; past the bound the outbox still holds it.
                var foldedMore = false
                if folded > 0, foldDrivenRounds < Self.maxFoldDrivenRounds {
                    foldDrivenRounds += 1
                    foldedMore = true
                }
                if !moreToPush && !morePulled && !foldedMore { return }
            }
        } while rounds < maxRounds

        // Falling out here means the server kept promising more for 200 rounds. Not fatal —
        // the next trigger picks up where this left off — but it is worth seeing in a log.
        NSLog("glsync: push/pull hit the round cap; will continue on the next trigger")
    }

    // MARK: The cycle's person

    /// The running cycle's road out. Outside a cycle there is none, so nothing can call the
    /// Worker unbound.
    private func wire() throws -> GLSyncTransport {
        guard let cycleTransport else { throw GLSyncTransportError.signedOut }
        return cycleTransport
    }

    /// Throws `.signedOut` when the person this cycle started for is no longer the one signed
    /// in. Usually local (a Keychain read and the cached token); it never mints for anybody new.
    private func ensureStillBound() async throws {
        guard let binding = try wire().binding,
              case .token = try await tokens.token(boundTo: binding) else {
            throw GLSyncTransportError.signedOut
        }
    }

    // MARK: Fold

    /// Fold history into the outbox, right before a pull is applied (QA 2026-10-03 F16). The
    /// pull skips every record with an outbox row, so an edit folded here is safe from it; the
    /// store's own unfolded-edit check covers a save that lands between this and the apply.
    /// Returns how many rows the fold queued.
    @discardableResult
    private func foldBeforeApplying(_ window: inout GLSyncFoldWindow) async throws -> Int {
        guard window.canFoldAgain else { return 0 }
        let fold = try await store.fold(since: window.readFrom, writtenUnder: window.fingerprint)
        window.folded(through: fold.newHistoryToken)
        if fold.unresolvedDeletes > 0 {
            // Named loudly rather than swallowed: these rows are gone locally and still alive
            // on the server, and the next pull will resurrect them. See `enqueueDelete`.
            note(GLSyncUserMessage(
                recordID: nil, recordType: nil,
                text: MBLocalization.string(
                    "Some deleted items may come back when this device syncs."), at: .now))
        }
        return fold.enqueued
    }

    // MARK: Bootstrap

    /// `bootstrapComplete == false` → page `/snapshot` to completion before any push, then
    /// enqueue every local record the server did NOT already have (GLSYNC-SPEC.md §5).
    private func bootstrap(_ persisted: inout GLSyncPersistedState,
                           window: inout GLSyncFoldWindow) async throws {
        var after = 0
        var pulledIDs: Set<UUID> = []
        var pulledPayloads: [UUID: [String: Any]] = [:]
        var maxSeq = persisted.cursor

        while true {
            try Task.checkCancellation()
            let page = try await wire().snapshot(after: after, limit: Self.snapshotPageSize)

            // The 180-day tombstone window has closed on our cursor: deletions may have
            // vanished from the stream entirely, so incremental catch-up can no longer be
            // trusted. Starting over is the only honest answer.
            if let oldest = page.oldestSeq, persisted.cursor > 0, oldest > persisted.cursor {
                NSLog("glsync: seq gap (oldest_seq %d > cursor %d) — full resync",
                      oldest, persisted.cursor)
                await store.resetCursorForFullResync()
                // Re-read: leaving the stale cursor in `persisted` would re-detect the same
                // gap on the very next page and loop forever.
                persisted = await store.persistedState()
                after = 0
                pulledIDs = []
                pulledPayloads = [:]
                maxSeq = 0
                continue
            }

            guard !page.records.isEmpty else { break }

            // F16: an edit saved while the previous page downloaded joins the outbox before
            // this page lands on it.
            try await foldBeforeApplying(&window)
            let verdict = await store.applyChanges(page.records)
            switch verdict {
            case .massDeleteRefused(let deletions, let threshold):
                pause(deletions: deletions, threshold: threshold, announce: true)
                NSLog("glsync: mass-delete breaker tripped during bootstrap (%d/%d)",
                      deletions, threshold)
                throw GLSyncHalted()
            case .applied(let pull):
                await absorb(pull)
                maxSeq = max(maxSeq, pull.maxSeq)
            }

            pulledIDs.formUnion(page.records.map(\.id))
            for row in page.records where !row.isTombstone {
                if let payload = row.payload.payload { pulledPayloads[row.id] = payload }
            }
            after = page.records.map(\.seq).max() ?? after
            if page.records.count < Self.snapshotPageSize { break }
        }

        // THE MIGRATION + RECONCILIATION. Push what is already here — parent-before-child.
        // Un-pulled records go as creates; PULLED records reconcile as a PER-FIELD DIFF
        // against what the pull just delivered (root fix 2026-08-30 night): only fields
        // where the local row genuinely differs go on the wire, at the pulled version. The
        // previous full-payload re-upload was the clobber half of the name bug — a fresh
        // install echoed the just-pulled (or just-minted, blank) row back at the server,
        // v-bumping it forever and, on a rebaseline, overwriting locally-newer values with
        // the server's own stale echo. A byte-identical row now enqueues NOTHING.
        //
        // SUPPRESSED after the signed-in account changed: the records on this device belong to
        // the person who was here before, and one tap of "sign in" must not move somebody's
        // books into somebody else's account. The new account still pulls its own data down.
        var enqueued = 0
        if persisted.suppressBootstrapUpload {
            NSLog("glsync: bootstrap upload suppressed — this store predates the signed-in account")
        } else {
            enqueued = await store.enqueueEverything(pulled: pulledPayloads)
        }
        NSLog("glsync: bootstrap complete — %d pulled, %d local records queued for upload",
              pulledIDs.count, enqueued)

        await store.markBootstrapComplete(cursor: maxSeq)
        persisted = await store.persistedState()
    }

    // MARK: Self-heal

    /// Every ~24h compare `/checksums` against local per-type counts. A mismatch means the
    /// stores have drifted — a lost write, a missed page, a bug — and re-bootstrapping is
    /// cheaper and more honest than trying to work out which row is wrong.
    private func selfHealIfDue(_ persisted: GLSyncPersistedState) async throws {
        if let last = persisted.lastChecksumAt,
           Date().timeIntervalSince(last) < Self.checksumInterval { return }

        let remote = try await wire().checksums()
        await store.stampChecksumChecked()

        let local = await store.localCounts()
        var drifted: [String] = []
        for type in GLSyncRegistry.allTypes {
            let localCount = local[type] ?? 0
            let remoteCount = remote.types[type]?.count ?? 0
            if localCount != remoteCount { drifted.append(type) }
        }
        guard !drifted.isEmpty else { return }

        NSLog("glsync: checksum drift on %@ — re-bootstrapping", drifted.joined(separator: ", "))
        await store.requestRebootstrap()
    }

    // MARK: Attachments

    /// Upload every blob referenced by this chunk's patches, then hand back the ops that are
    /// safe to send. Three outcomes per blob:
    ///
    /// * **uploaded** — the reference stands, rewritten to the ENVELOPE hash for a tax
    ///   document, because the server content-addresses what it actually received;
    /// * **permanently refused** — the reference is REMOVED and the person is told, because a
    ///   payload must never point at an attachment the server does not have. The rest of the
    ///   record still goes: one refused document never aborts an otherwise valid push. A
    ///   lapsed subscription lands here too, with the sentence coming from /sync's refusal of
    ///   the same op instead of from here, so one edit is reported once;
    /// * **not encryptable right now** — the whole OP is held back, untouched, and goes on a
    ///   later cycle.
    ///
    /// THE INVARIANT, and the reason `fold` no longer strips `w9Data`: a tax-class document
    /// leaves this device as ciphertext or it does not leave at all. No branch below reaches
    /// `uploadAttachment` with `encrypted: false` for a tax field — the seal either produces
    /// the bytes to send or the op is skipped.
    private func uploadBlobs(for ops: [GLSyncPendingOp]) async throws -> [GLSyncPendingOp] {
        let uploads = await store.blobUploads(for: ops)
        guard !uploads.isEmpty else { return ops }

        var dropped: [UUID: Set<String>] = [:]
        var sealedHashes: [UUID: [String: String]] = [:]
        var held: Set<UUID> = []

        for upload in uploads {
            // Before each file, and before a W-9 is sealed (F18): a person who signed out mid-
            // upload gets no further, and the sealing key is never fetched for whoever is
            // signed in now. The key comes through the live session, so this check is what
            // keeps one person's W-9 from being sealed under the next person's key.
            try Task.checkCancellation()
            try await ensureStillBound()
            let piiClass = GLSyncRegistry.piiClass(type: upload.recordType, field: upload.field)

            // A tax document is uploaded from the SEALED value or not at all: the bytes, the
            // hash and the `encrypted` flag below are all read off this one optional, so
            // "tax, encrypted: 1, plaintext bytes" is not a state this code can express. And
            // if it were ever nil for a tax field, `uploadAttachment` refuses that pair before
            // the request instead of sending it. It fails closed twice.
            var sealed: GLSyncSealedDocument?
            if piiClass == .tax {
                do {
                    let envelope = try await documents.seal(upload.bytes)
                    sealed = envelope
                    sealedHashes[upload.recordID, default: [:]][upload.field] = envelope.sha256
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.canRetryLater(error) {
                    // No key right now: offline, rate-limited, signed out mid-cycle, or the
                    // key service is not turned on yet (it answers 503 until its master secret
                    // is set). The op stays in the outbox exactly as it was, so THE OUTBOX IS
                    // the retry — every later cycle tries again and a relaunch loses nothing.
                    held.insert(upload.recordID)
                    continue
                } catch {
                    // Permanent: this build can never seal these bytes. Drop the reference so
                    // the rest of the record still reaches the server, and say so in words.
                    dropped[upload.recordID, default: []].insert(upload.field)
                    let message = GLSyncUserMessage(recordID: upload.recordID,
                                                    recordType: upload.recordType,
                                                    text: GLSyncDocumentError.message(for: error), at: .now)
                    note(message)
                    Logger.data.error("glsync document seal refused \(upload.recordType, privacy: .public).\(upload.field, privacy: .public)")
                    announce([message])
                    continue
                }
            }

            let sha = sealed?.sha256 ?? upload.sha256
            guard !uploadedHashes.contains(sha) else { continue }
            do {
                try await wire().uploadAttachment(
                    bytes: sealed?.envelope ?? upload.bytes,
                    sha256: sha,
                    name: upload.name,
                    piiClass: piiClass,
                    encrypted: sealed != nil)
                uploadedHashes.insert(sha)
            } catch GLSyncTransportError.signedOut {
                // The person changed mid-upload: the cycle ends here, nothing dropped or sent.
                throw GLSyncTransportError.signedOut
            } catch let error as GLSyncTransportError where !error.isTransient {
                // Permanent: this file is not going up as things stand. Drop the reference
                // and let the REST of the record through, rather than pushing a payload that
                // points at nothing — and rather than letting one refused document abort a
                // push whose other ops never touched an attachment.
                dropped[upload.recordID, default: []].insert(upload.field)
                sealedHashes[upload.recordID]?.removeValue(forKey: upload.field)
                if case .subscriptionLapsed = error {
                    // The one refusal here that is not about this FILE: the account lapsed,
                    // and it becomes uploadable again the moment they renew. The person is
                    // still told — by /sync, in this same round, in the same words: the op
                    // goes on the wire below and the Worker refuses it with
                    // `subscription_lapsed`, whose sentence IS this error's sentence. Noting
                    // it here as well would print one edit's refusal twice. So this branch
                    // carries the developer half only, which is the half /sync's answer
                    // cannot give: the endpoint that refused, and the field it cost.
                    NSLog("glsync: attachment upload refused, subscription lapsed — %@.%@ dropped from this push",
                          upload.recordType, upload.field)
                } else if let text = error.userMessage {
                    let message = GLSyncUserMessage(recordID: upload.recordID,
                                                    recordType: upload.recordType,
                                                    text: text, at: .now)
                    note(message)
                    // A refused FILE is a refusal of the person's work: on screen and logged
                    // (law 6; QA 2026-10-03 F87).
                    Logger.data.error("glsync attachment refused \(upload.recordType, privacy: .public).\(upload.field, privacy: .public)")
                    announce([message])
                }
            }
            // Transient failures propagate: the whole chunk waits rather than pushing a
            // payload whose bytes are still on this device. A subscription refusal is NOT
            // one of those — see `GLSyncTransportError.isTransient`, where routing it to
            // `.server(status: 403)` made it look transient and put this upload in a loop
            // that threw out of here on every cycle, taking the whole push with it.
        }

        guard !dropped.isEmpty || !sealedHashes.isEmpty || !held.isEmpty else { return ops }
        return ops.compactMap { op in
            // Held back ENTIRELY rather than sent with the reference stripped: dropping it
            // would clear the outbox row on success and the W-9 would then wait for the next
            // time somebody happened to edit that subcontractor.
            guard !held.contains(op.recordID) else { return nil }
            var sanitized = op
            if let fields = dropped[op.recordID] { sanitized = sanitized.removingPatchFields(fields) }
            if let hashes = sealedHashes[op.recordID] { sanitized = sanitized.replacingBlobHashes(hashes) }
            return sanitized
        }
    }

    /// Whether a failed seal or a failed download is worth another attempt in a few minutes.
    /// `signedOut` counts: the document key comes from the identity service, and the app is
    /// fully usable — and still syncing everything else — without a session (§4). Anything
    /// that is not a transport error is a format or key problem this build cannot outgrow.
    private static func canRetryLater(_ error: Error) -> Bool {
        guard let error = error as? GLSyncTransportError else { return false }
        if case .signedOut = error { return true }
        return error.isTransient
    }

    /// Fetch blob bytes for pulled rows and write them onto the records. Failures are
    /// non-fatal: the row is already applied and correct apart from the file.
    ///
    /// A `tax`-class blob arrives as an ENVELOPE and is opened here. The class is read from
    /// the registry, never from the server, so the two halves agree by construction: whatever
    /// `piiClass` said to seal with is what says to open. Bytes that fail to open are NEVER
    /// written onto the record — a W-9 that renders as garbage is worse than one that has not
    /// arrived yet.
    private func fetchBlobs(_ fetches: [GLSyncBlobFetch]) async {
        // Every NEW fetch is attempted; carried-over ones are capped, because uploads and
        // downloads share one 300-per-15-minutes budget and a backlog must not spend it all
        // in one cycle. The set is unordered, so each cycle gives a different slice a turn.
        let carried = pendingBlobFetches.subtracting(fetches).prefix(Self.blobRetriesPerCycle)
        pendingBlobFetches.formUnion(fetches)

        for fetch in fetches + Array(carried) {
            do {
                let bytes = try await wire().downloadAttachment(sha256: fetch.sha256)
                // Verify what we were handed. A byte-for-byte check is cheap and it is the
                // only thing standing between a corrupted download and a customer's COI.
                guard glSyncSHA256(bytes) == fetch.sha256 else {
                    NSLog("glsync: attachment %@ failed its hash check", fetch.sha256)
                    pendingBlobFetches.remove(fetch)
                    continue
                }
                var plaintext = bytes
                if GLSyncRegistry.piiClass(type: fetch.recordType, field: fetch.field) == .tax {
                    plaintext = try await documents.open(bytes)
                }
                await store.applyBlob(plaintext, to: fetch)
                pendingBlobFetches.remove(fetch)
            } catch is CancellationError {
                return
            } catch let error where Self.canRetryLater(error) {
                // Offline mid-pull, rate-limited, or no document key yet. Kept for a later
                // cycle: this row will not be pulled again, so dropping it here would lose
                // the file until somebody edited that record on another device.
                continue
            } catch {
                // A 404 for bytes another device has not uploaded yet, or an envelope this
                // build cannot open. Retrying either would only burn the attachment budget.
                pendingBlobFetches.remove(fetch)
            }
        }
    }

    // MARK: Deletes

    /// Queue a delete. **Call this BEFORE `context.delete(record)`**, never after.
    ///
    /// Every `syncID` now carries `@Attribute(.preserveValueOnDeletion)`, so a tombstone DOES
    /// hold the uuid — but `GLSyncHistory` does not read it back out yet (its `.delete` case
    /// still returns `changedFields: nil` and no id), so the fold still cannot name a delete.
    /// Until that reader lands, this is the only supported path, and it has to run while the
    /// record still exists because the cascade subtree does too.
    @discardableResult
    func enqueueDelete(recordID: UUID, type: String) async -> Bool {
        await store.enqueueDelete(recordID: recordID, type: type)
    }

    // MARK: Bookkeeping

    private func handle(_ error: GLSyncTransportError) {
        switch error {
        case .signedOut:
            state = .signedOut
        case .rateLimited:
            // Quiet by contract. Never a banner, never a badge — the next trigger retries.
            state = .waiting
        default:
            state = .waiting
            if let text = error.userMessage {
                note(GLSyncUserMessage(recordID: nil, recordType: nil, text: text, at: .now))
            }
        }
    }

    /// Everything a successful pull hands back that the ENGINE owns: parent relinking and blob
    /// bytes. Versions are not here — the store stamped them in the same save as the rows.
    private func absorb(_ pull: GLSyncPullOutcome) async {
        pendingLinks.formUnion(pull.unlinked)
        if !pendingLinks.isEmpty {
            // Parents that arrived in THIS page can now adopt children from earlier ones.
            pendingLinks = Set(await store.relink(Array(pendingLinks)))
        }
        if pull.unknownType > 0 {
            NSLog("glsync: %d pulled rows had a type this build does not know", pull.unknownType)
        }
        await fetchBlobs(pull.blobFetches)
    }

    private func record(_ changes: [GLSyncRecentChange]) {
        guard !changes.isEmpty else { return }
        recentChanges.append(contentsOf: changes)
        if recentChanges.count > Self.logCapacity {
            recentChanges.removeFirst(recentChanges.count - Self.logCapacity)
        }
    }

    private func note(_ message: GLSyncUserMessage) {
        messages.append(message)
        if messages.count > Self.logCapacity {
            messages.removeFirst(messages.count - Self.logCapacity)
        }
    }

    /// Put the server's refusals in front of the person, once (QA 2026-10-03 F87, law 6).
    /// `GLSyncStatus` drops a sentence already waiting, so thirty refused edits are one alert.
    private func announce(_ messages: [GLSyncUserMessage]) {
        let texts = messages.map(\.text)
        guard !texts.isEmpty else { return }
        Task { @MainActor in GLSyncStatus.shared.post(texts) }
    }

    // MARK: - Entitlement (QA 2026-10-03 F17)

    /// The subscription changed. The app token carries the account's standing (`ent`) as it
    /// was when it was minted, so the cached one is now wrong either way: a renewal pushed with
    /// a `lapsed` token is refused for up to the token's whole life. Dropped, the next request
    /// mints with the new standing. Renewed (or entitled again), edits held for the lapse go now
    /// rather than at the next trigger.
    func entitlementChanged(to entitlement: GLSyncEntitlement) async {
        await tokens.invalidate()
        guard !entitlement.isLapsed else { return }
        await store.releaseLapseParks()
        await sync(trigger: .manual)
    }

    /// Watches the subscription for the life of the engine. The first value is the standing at
    /// launch, not a change, so it only sets the baseline.
    private func startEntitlementTrigger() {
        let task = Task { [weak self] in
            let changes = await MainActor.run { GLSyncEntitlement.changes() }
            var last: GLSyncEntitlement?
            for await now in changes {
                guard let self else { break }
                defer { last = now }
                guard let previous = last, previous != now else { continue }
                await self.entitlementChanged(to: now)
            }
        }
        monitors.append(task)
    }
}

// MARK: - Patch surgery

extension GLSyncPendingOp {
    /// A copy without the named patch fields. Used when a blob upload fails permanently: the
    /// rest of the record still deserves to reach the server.
    nonisolated func removingPatchFields(_ fields: Set<String>) -> GLSyncPendingOp {
        guard !fields.isEmpty else { return self }
        return rewritingPatch { patch in
            for field in fields { patch.removeValue(forKey: field) }
        }
    }

    /// A copy whose named blob references carry a DIFFERENT sha256: the hash of the bytes
    /// that were actually uploaded. Encryption is the only caller — the server
    /// content-addresses the envelope it received, so a reference naming the plaintext hash
    /// would point at a blob that was never stored. The `name` half is left alone.
    nonisolated func replacingBlobHashes(_ hashes: [String: String]) -> GLSyncPendingOp {
        guard !hashes.isEmpty else { return self }
        return rewritingPatch { patch in
            for (field, sha) in hashes {
                guard var reference = patch[field] as? [String: Any] else { continue }
                reference["sha256"] = sha
                patch[field] = reference
            }
        }
    }

    /// Both rewrites go through here so a patch that will not decode or re-encode has ONE
    /// behaviour: the op travels exactly as it was, never half-rewritten.
    private nonisolated func rewritingPatch(
        _ transform: (inout [String: Any]) -> Void
    ) -> GLSyncPendingOp {
        guard let data = patchJSON.data(using: .utf8),
              var patch = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return self }
        transform(&patch)
        guard JSONSerialization.isValidJSONObject(patch),
              let encoded = try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return self }
        return GLSyncPendingOp(
            opID: opID, recordID: recordID, recordType: recordType, parentID: parentID,
            baseVersion: baseVersion, patchJSON: text, isDelete: isDelete,
            cascade: cascade, clientTS: clientTS)
    }
}

/// SHA-256 hex. Same shape as the mappers' own copies (each file keeps a private one so the
/// module has no duplicate declaration); this one is for verifying DOWNLOADS.
nonisolated func glSyncSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 hex of a blob the device already holds, remembered by the bytes themselves (QA
/// 2026-10-03 F91). A payload names every document by its hash, and the same unchanged logo
/// or PDF was hashed again on the main actor every time its record was folded or pulled.
///
/// Keyed by the `Data` value: the lookup hashes only the length and the first bytes, and a
/// match is confirmed by a full byte comparison (instant when it is the same buffer), so a
/// remembered answer is always the right one; it is never a guess from a size or a date. Safe
/// from any thread. Bounded by bytes held, oldest out first; a blob larger than the whole
/// budget is hashed and not remembered. Emptied at sign-out and on a change of account, and
/// a tax-class field (the subcontractor W-9) never goes through it.
nonisolated enum GLSyncBlobHashCache {

    nonisolated struct State: Sendable {
        var hashes: [Data: String] = [:]
        var order: [Data] = []
        var bytes = 0
    }

    static let byteBudget = 16 * 1024 * 1024
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func sha256(_ data: Data) -> String {
        if let known = remembered(data) { return known }
        let hex = glSyncSHA256(data)
        guard data.count <= byteBudget else { return hex }
        state.withLock { state in
            guard state.hashes[data] == nil else { return }
            state.hashes[data] = hex
            state.order.append(data)
            state.bytes += data.count
            while state.bytes > byteBudget, !state.order.isEmpty {
                let oldest = state.order.removeFirst()
                state.hashes[oldest] = nil
                state.bytes -= oldest.count
            }
        }
        return hex
    }

    /// The remembered hash, without computing one. Nil when these bytes were never hashed
    /// (or have aged out).
    static func remembered(_ data: Data) -> String? {
        state.withLock { $0.hashes[data] }
    }

    /// Forgets every remembered blob. The keys ARE the signed-in person's documents, so a
    /// sign-out or a change of account must not leave them in memory for the next person.
    static func removeAll() {
        state.withLock { $0 = State() }
    }
}

// MARK: - Parent relinking

/// A child whose cascade parent had not been pulled yet when the child landed. Retried after
/// every page: within one page a child can precede its parent (seq is write order, not tree
/// order), and across pages the parent may simply be later in the stream.
nonisolated struct GLSyncParentLink: Sendable, Hashable {
    let recordID: UUID
    let recordType: String
    let parentID: UUID
}

// MARK: - The local store
//
// Every SwiftData touch in GLSync happens here, on the MainActor, because this target
// compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — the @Models, their mappers and
// their relationship graphs are all MainActor types. A @MainActor class is implicitly
// Sendable, which is what lets the engine actor hold one.
//
// THE AUTHORED CONTEXT is the load-bearing detail. Everything written here goes through a
// context stamped `author = GLSyncHistory.applyAuthor`, so the fold skips our own writes.
// Without it, applying a pulled change would look exactly like a user edit and echo straight
// back to the server, forever (GLSYNC-SPEC.md §2a, trap 1).

@MainActor
final class GLSyncLocalStore {

    private let container: ModelContainer

    /// Separate from the app's main context ON PURPOSE. `author` is a property of the
    /// context, so stamping the app's own context would tag every USER edit `gl-sync` and the
    /// fold would skip all of them — the app would go permanently, silently un-synced.
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.author = GLSyncHistory.applyAuthor
        // Manual saves only: an autosave here would land mid-apply, between a record's
        // payload and its parent link.
        context.autosaveEnabled = false
        return context
    }()

    /// `nonisolated` so the engine actor can build one in its own init. Nothing MainActor
    /// happens here — the context is lazy, and `ModelContainer` is Sendable.
    nonisolated init(container: ModelContainer) {
        self.container = container
    }

    /// `saveChanges()` is deliberately NOT used: it stamps `updatedAt = .now` on everything
    /// it touches, which would overwrite the server's own `updatedAt` on every pulled row and
    /// make this device look like the last editor of records it never edited.
    private func persist() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Logger.data.error("glsync save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: State

    func persistedState() -> GLSyncPersistedState {
        let state = GLSyncState.singleton(in: context)
        persist()
        return Self.snapshot(state)
    }

    private static func snapshot(_ state: GLSyncState) -> GLSyncPersistedState {
        GLSyncPersistedState(
            cursor: state.cursor,
            historyToken: state.lastHistoryTokenData,
            deviceID: state.deviceID ?? UUID(),
            lastSyncAt: state.lastSyncAt,
            lastChecksumAt: state.lastChecksumAt,
            bootstrapComplete: state.bootstrapComplete,
            historyFingerprint: state.historySchemaFingerprint,
            ownerID: state.ownerID,
            breaker: state.breakerTrippedAt.map {
                GLSyncBreakerTrip(deletions: state.breakerDeletions,
                                  threshold: state.breakerThreshold, at: $0)
            },
            suppressBootstrapUpload: state.suppressBootstrapUpload)
    }

    // MARK: - Account binding (GLSYNC-SPEC.md §4)

    /// Bind this device's sync state to the signed-in Gold Life ID, resetting everything that
    /// is only meaningful inside ONE account if it has changed hands.
    ///
    /// `seq` is per-user, so an inherited cursor is not merely stale — it is a number from a
    /// different counter. A second person signing in on this device would start above their own
    /// account's entire history and pull NOTHING, forever, while `bootstrapComplete` told the
    /// engine there was nothing to catch up on. Meanwhile the outbox, the version table and the
    /// history bookmark all describe the previous account's server state, so pushing them would
    /// upload one person's books into another person's account.
    ///
    /// Returns true when the account CHANGED (nil → id is a first binding, not a change).
    @discardableResult
    func bind(owner: String) -> Bool {
        let state = GLSyncState.singleton(in: context)
        guard state.ownerID != owner else { return false }
        let changed = state.ownerID != nil
        state.ownerID = owner
        guard changed else {
            persist()
            return false
        }

        state.cursor = 0
        state.lastHistoryTokenData = nil
        lastFoldedToken = nil
        state.bootstrapComplete = false
        state.lastSyncAt = nil
        state.lastChecksumAt = nil
        state.breakerTrippedAt = nil
        state.breakerDeletions = 0
        state.breakerThreshold = 0
        state.breakerOverrideArmed = false
        // The records on this device are the PREVIOUS owner's. Pull the new account's data
        // down, but never push what is already here into it — that is somebody else's business,
        // and one tap of "sign in" must not move it.
        state.suppressBootstrapUpload = true

        for row in GLSyncOutboxEntry.all(in: context) { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<GLSyncRecordVersion>())) ?? [] {
            context.delete(row)
        }
        // The cache mirrors those rows — a stale entry would hand back a DELETED
        // model whose next property read traps (CRUD audit 2026-09-02).
        versionCache.removeAll()
        // A fresh device identity too: the server breaks LWW ties on it, and the previous
        // owner's id is not this session's to reuse.
        state.deviceID = UUID()
        persist()
        NSLog("glsync: signed-in account changed — sync state reset, local upload suppressed")
        return true
    }

    // MARK: - The mass-delete breaker's persisted trip

    /// Remember that the breaker stopped, so a relaunch does not quietly re-pull the same page
    /// and trip again with nothing on screen to explain it.
    func recordBreakerTrip(deletions: Int, threshold: Int) {
        let state = GLSyncState.singleton(in: context)
        state.breakerTrippedAt = .now
        state.breakerDeletions = deletions
        state.breakerThreshold = threshold
        persist()
    }

    /// The person read the sentence and asked to continue. Spent by the very next pull that
    /// would otherwise trip, so a SECOND unexpected wave still stops.
    func armBreakerOverride() {
        let state = GLSyncState.singleton(in: context)
        state.breakerOverrideArmed = true
        state.breakerTrippedAt = nil
        persist()
    }

    private func consumeBreakerOverride() -> Bool {
        let state = GLSyncState.singleton(in: context)
        guard state.breakerOverrideArmed else { return false }
        state.breakerOverrideArmed = false
        state.breakerTrippedAt = nil
        persist()
        return true
    }

    /// §5.5: the cursor and the history token move TOGETHER, in one save, and only after the
    /// round trip landed. Advancing one without the other is how a device loses a window of
    /// edits or re-applies one forever.
    func advance(cursor: Int, historyToken: Data?) {
        let state = GLSyncState.singleton(in: context)
        state.cursor = cursor
        // nil means "history had nothing new" — KEEP the token we have. Writing nil would
        // re-fold the entire history next cycle.
        if let historyToken {
            state.lastHistoryTokenData = historyToken
            // The token and the shape it was written under are ONE fact. Storing the token
            // without the shape is what made build 42 unrecoverable.
            state.historySchemaFingerprint = GLSyncHistory.schemaFingerprint
        }
        persist()
    }

    /// Whether `context` is the engine's own apply/persist context — the edit
    /// observer must not re-trigger on the engine's own saves.
    func owns(_ other: ModelContext) -> Bool { other === context }

    func stampSynced() {
        GLSyncState.singleton(in: context).lastSyncAt = .now
        persist()
    }

    /// Stamp "backed up" only when the outbox holds nothing but parked rows (QA 2026-10-03
    /// F88). Parked rows are the server's settled answer and the Backup row counts them on its
    /// own; any other row is an edit this device still owes the server. Returns whether it
    /// stamped.
    @discardableResult
    func stampSyncedIfDrained() -> Bool {
        guard !GLSyncOutboxEntry.all(in: context).contains(where: { !$0.isParked }) else {
            return false
        }
        stampSynced()
        return true
    }

    /// Release rows an older build parked for `subscription_lapsed` into HELD rows, op id
    /// unchanged, so they go out again (QA 2026-10-03 F17). Returns how many it released.
    @discardableResult
    func releaseLapseParks() -> Int {
        let rows = GLSyncOutboxEntry.all(in: context).filter(\.isParkedForLapse)
        guard !rows.isEmpty else { return 0 }
        for row in rows { row.hold(GLSyncOutboxEntry.lapsedReason) }
        persist()
        NSLog("glsync: %d edits parked for a lapsed subscription released for retry", rows.count)
        return rows.count
    }

    func stampChecksumChecked() {
        GLSyncState.singleton(in: context).lastChecksumAt = .now
        persist()
    }

    func markBootstrapComplete(cursor: Int) {
        let state = GLSyncState.singleton(in: context)
        state.bootstrapComplete = true
        state.cursor = max(state.cursor, cursor)
        // Spent: it suppresses the FIRST bootstrap after the account changed hands. A later
        // re-bootstrap (checksum drift) must still be able to re-upload what only this device
        // has, or self-heal would be a one-way pull.
        state.suppressBootstrapUpload = false
        persist()
    }

    func requestRebootstrap() {
        GLSyncState.singleton(in: context).bootstrapComplete = false
        persist()
    }

    func resetCursorForFullResync() {
        let state = GLSyncState.singleton(in: context)
        state.cursor = 0
        state.bootstrapComplete = false
        persist()
    }

    /// The saved history bookmark cannot be trusted (a foreign store, or unreadable bytes).
    /// Dropping it re-folds the whole window, which is safe — the outbox coalesces per record
    /// — while KEEPING it would report "nothing changed" forever (§2a, trap 2).
    func dropHistoryTokenAndRebootstrap() {
        let state = GLSyncState.singleton(in: context)
        state.lastHistoryTokenData = nil
        lastFoldedToken = nil
        state.bootstrapComplete = false
        persist()
    }

    /// Recover from history written under a MODEL SHAPE this build cannot read.
    ///
    /// Order matters and is the whole point. Dropping the token alone would be WORSE than doing
    /// nothing: a nil token means "read from the beginning", so the next fold would materialize
    /// the very transactions that trap. So PURGE first — `deleteHistory` never materializes a
    /// transaction, which is why it is safe to call on poisoned history — and only then clear the
    /// bookmark and stamp the shape this build actually reads.
    ///
    /// `bootstrapComplete = false` is what makes it lossless: the first-run path re-uploads
    /// the WHOLE local store — pulled rows included, as reconciling updates
    /// (`enqueueEverything(pulled:)`) — so an edit whose history entry died here still
    /// reaches the server. (Until 2026-08-30 the re-upload skipped rows the server already
    /// had, which silently orphaned exactly those edits: the name-lost-on-reinstall bug.)
    func rebaselineHistory() {
        do {
            // EVERYTHING, not `.now`: writes landing inside this same cycle (the state row
            // below, bootstrap's marks) postdate a `.now` cutoff and would survive a re-purge.
            try GLSyncHistory.prune(before: .distantFuture, in: context)
        } catch {
            // Even a failed purge must not leave the poisoned token readable — fall through and
            // clear it. The nil token this leaves behind is SAFE now because `changes()`'s
            // nil-token gate purges again before any from-the-beginning read (the build-48
            // launch trap: this comment used to claim the fingerprint gate covered that path,
            // and it never did — a nil token bypasses it).
            Logger.data.error("glsync rebaseline purge failed: \(error.localizedDescription, privacy: .public)")
        }
        let state = GLSyncState.singleton(in: context)
        state.lastHistoryTokenData = nil
        lastFoldedToken = nil
        state.historySchemaFingerprint = GLSyncHistory.schemaFingerprint
        state.bootstrapComplete = false
        persist()
    }

    func pruneHistory(before cutoff: Date) {
        do {
            try GLSyncHistory.prune(before: cutoff, in: context)
        } catch {
            Logger.data.error("glsync history prune failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Per-record versions (GLSYNC-SPEC.md §5.3)
    //
    // A write-through cache over `GLSyncRecordVersion`: read on demand, write on every applied
    // push result and every pulled row — and never with a save of its own. Each writer is
    // already inside a `persist()` that commits the outbox row or the domain payload the
    // version belongs to, so the two land together or not at all. Saving separately is how a
    // crash between the two leaves a record whose stored version does not describe it.

    /// `nil` VALUE means "looked, and there is no row" — negative results are cached too, or
    /// every create in `enqueueEverythingAsCreates` would re-fetch a row that has never existed.
    private var versionCache: [UUID: GLSyncRecordVersion?] = [:]

    /// The last server version this device saw for a record. `0` means the server has never
    /// acknowledged it, which is the same thing the wire calls a create.
    private func version(for recordID: UUID) -> Int { versionRow(for: recordID)?.version ?? 0 }

    private func versionRow(for recordID: UUID) -> GLSyncRecordVersion? {
        if let cached = versionCache[recordID] { return cached }
        let fetched = GLSyncRecordVersion.row(for: recordID, in: context)
        versionCache[recordID] = fetched
        return fetched
    }

    /// Remember a version. Deliberately does NOT persist — see the note above.
    private func stampVersion(_ version: Int, for recordID: UUID) {
        if let row = versionRow(for: recordID) {
            // MAX, never plain assignment: a push result and a pulled row for the same record
            // can arrive in either order inside one cycle, and moving a version BACKWARDS would
            // re-contest fields the server has already merged.
            row.version = max(row.version, version)
            return
        }
        let row = GLSyncRecordVersion(recordID: recordID, version: version)
        context.insert(row)
        versionCache[recordID] = row
    }

    /// The record is gone for good. Its version row would otherwise outlive it forever, and a
    /// stale row is worse than none: uuids are never reused, so it can only ever be wrong.
    private func dropVersion(for recordID: UUID) {
        if let row = versionRow(for: recordID) { context.delete(row) }
        versionCache[recordID] = .some(nil)
    }

    func localCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for key in GLSyncRegistry.allTypes {
            counts[key] = GLSyncRegistry.entry(for: key)?.count(context) ?? 0
        }
        return counts
    }

    // MARK: - Fold sentinel (crash-loop breaker, 2026-09-01, the build-62 address SIGTRAP)

    /// A FILE next to the store, not a UserDefaults flag: defaults flush lazily, so a
    /// SIGTRAP right after `set` can lose the write — which would defeat the point. File
    /// creation is synchronous, per-user by construction, and dies with the store on wipe.
    private var foldSentinelURL: URL? {
        guard let storeURL = container.configurations.first?.url else { return nil }
        return storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".folding")
    }

    /// True when a previous run DIED inside a history read — the sentinel was created and
    /// never removed. `fetchHistory` traps uncatchably on a row it can't materialize, so no
    /// error path ever runs; without this check the same row crashes every launch until the
    /// person deletes the app. The caller must re-baseline (purge FIRST) instead of reading.
    func foldSentinelTripped() -> Bool {
        guard let url = foldSentinelURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func clearFoldSentinel() {
        guard let url = foldSentinelURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every `fetchHistory` that MATERIALIZES transactions runs inside this. Create the
    /// sentinel, read, remove it — a crash mid-read leaves the file for the next launch.
    private func withFoldSentinel<T>(_ body: () throws -> T) rethrows -> T {
        if let url = foldSentinelURL {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        defer { clearFoldSentinel() }
        return try body()
    }

    // MARK: - Unfolded edits (QA 2026-10-03 F16)

    /// The newest history token a fold in THIS process has read through — its window is in
    /// the outbox. Nil until the first fold, and after anything that purges or replaces the
    /// watermark; the pull guard then falls back to the persisted token.
    private var lastFoldedToken: Data?

    /// How many rows the newest fold loaded to find the records its history names. A read-only
    /// measure for tests (QA 2026-10-03 F91): it must track the edits, not the table size.
    private(set) var lastFoldRowsFetched = 0

    /// Records a user edit touched AFTER the last fold: saved, but not in the outbox yet.
    ///
    /// The outbox alone cannot answer "is this record dirty?" — an edit reaches it only when a
    /// fold reads history, and a pull lands between folds. A pulled row (this device's own
    /// write echoed back, or a snapshot page) would overwrite such an edit, and the next fold
    /// would then push the overwritten value: the person's newest value gone on every device.
    ///
    /// Reads only history this build can read: never with a nil token (that read PURGES — see
    /// `GLSyncHistory.changes`), never under another build's fingerprint (that read TRAPS), and
    /// inside the fold sentinel like every other materializing read. A read that fails falls
    /// back to the outbox alone, which is the rule as it stood before.
    private func unfoldedRecordIDs() -> Set<UUID> {
        guard let (watermark, fingerprint) = readableFoldWatermark() else { return [] }

        let changes: [GLSyncHistoryChange]
        do {
            changes = try withFoldSentinel {
                try GLSyncHistory.changes(since: watermark, writtenUnder: fingerprint,
                                          in: context).changes
            }
        } catch {
            Logger.data.error("glsync unfolded-edit check failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var dirty: Set<UUID> = []
        var touched: [String: Set<PersistentIdentifier>] = [:]
        for change in changes where GLSyncRegistry.entry(entityName: change.recordType) != nil {
            if change.kind == .delete {
                // Gone locally, not queued yet: a pulled copy must not bring it back.
                if let id = change.deletedSyncID { dirty.insert(id) }
            } else {
                touched[change.recordType, default: []].insert(change.recordID)
            }
        }
        // History names rows, not sync ids. The same fetch route `fold` takes — this context
        // is not the one the person edits in, so nothing is registered here. Only the named
        // rows load (QA 2026-10-03 F91).
        for (entityName, rows) in touched {
            guard let entry = GLSyncRegistry.entry(entityName: entityName) else { continue }
            for record in entry.fetchRows(rows, context) {
                if let id = record.glSyncID { dirty.insert(id) }
            }
        }
        return dirty
    }

    /// Where history past the newest fold starts, when it can be read safely: the token the last
    /// fold in this process read through, else the committed one. Nil for a nil watermark (that
    /// read PURGES — see `GLSyncHistory.changes`) and for a token written under another build's
    /// model shape (that read TRAPS).
    private func readableFoldWatermark() -> (token: Data, fingerprint: String?)? {
        if let lastFoldedToken { return (lastFoldedToken, GLSyncHistory.schemaFingerprint) }
        let state = GLSyncState.singleton(in: context)
        guard let token = state.lastHistoryTokenData,
              GLSyncHistory.canReadHistory(writtenUnder: state.historySchemaFingerprint) else {
            return nil
        }
        return (token, state.historySchemaFingerprint)
    }

    /// Fold every edit saved since the newest fold into the outbox, with no network (QA
    /// 2026-10-03 F12). An edit reaches the outbox only through a fold, and a fold used to run
    /// only inside a cycle: about 5 s after the save, and never while the breaker is paused or no
    /// token can be minted. So the sign-out warning, which counts the outbox, read 0 for an edit
    /// saved seconds before, and the wipe then lost it. Folding first makes the count true.
    ///
    /// Reads only past the newest fold, so it never repeats a window a fold already read in this
    /// process (a repeat would re-open an outbox row the server just parked). Nothing is
    /// committed here: the next cycle's fold may read this window again from its own start,
    /// which coalesces the same edits into the same rows. Skipped (0) when history can't be read
    /// safely, or when a previous run died inside a history read (the cycle repairs that first).
    @discardableResult
    func foldPendingEdits() -> Int {
        guard !foldSentinelTripped(), let (token, fingerprint) = readableFoldWatermark() else { return 0 }
        do {
            return try fold(since: token, writtenUnder: fingerprint).enqueued
        } catch {
            Logger.data.error("glsync local fold failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Fold: history → outbox (GLSYNC-SPEC.md §2)

    /// Read persistent history since `token` and fold it into coalesced outbox rows.
    ///
    /// The returned token is NOT committed here — the caller commits it only after the push
    /// lands, together with the cursor. Re-folding a window is free; losing one is not.
    func fold(since token: Data?, writtenUnder fingerprint: String?) throws -> GLSyncFoldResult {
        // The fingerprint MUST ride along (root fix 2026-08-30 night): omitting it
        // made `changes` treat EVERY non-nil token as written under an unknown
        // schema — .schemaChanged on every cycle, token dropped, re-bootstrap,
        // and the store lived permanently in the nil-token regime where no edit
        // ever reached the outbox. runCycle validates the same fact up front;
        // this is the same fact at the second gate.
        let (changes, newToken) = try withFoldSentinel {
            try GLSyncHistory.changes(since: token, writtenUnder: fingerprint, in: context)
        }
        // Everything up to here is now the outbox's to carry (the window below is persisted
        // before this returns), so the pull guard reads history only PAST it.
        lastFoldedToken = newToken ?? token
        guard !changes.isEmpty else {
            return GLSyncFoldResult(newHistoryToken: newToken, enqueued: 0, unresolvedDeletes: 0)
        }

        // One fetch per TOUCHED type, for exactly the rows history names, indexed by row
        // identity. `registeredModel(for:)` only answers for objects already faulted into this
        // context, and this context is not the one the user edits in — so an index built from
        // a real fetch is the only reliable way to get from a history row back to a model.
        // Never the whole table: this runs on the main actor after every save (QA 2026-10-03
        // F91). A row deleted later in the same window simply does not come back, and its
        // tombstone is handled below.
        var touched: [String: Set<PersistentIdentifier>] = [:]
        for change in changes where change.kind != .delete {
            touched[change.recordType, default: []].insert(change.recordID)
        }
        var index: [PersistentIdentifier: GLSyncRecord] = [:]
        lastFoldRowsFetched = 0
        for (entityName, rows) in touched {
            guard let entry = GLSyncRegistry.entry(entityName: entityName) else { continue }
            for record in entry.fetchRows(rows, context) {
                lastFoldRowsFetched += 1
                index[record.persistentModelID] = record
            }
        }

        var enqueued = 0
        var unresolvedDeletes = 0

        // Computed ONCE for the whole window: a routed delete (`ModelContext.deleteSynced`)
        // already named its whole subtree in one op, and SwiftData then emits a tombstone per
        // cascaded row. Those echoes must not become independent delete ops — see
        // `enqueueResolvedDelete`. Nothing below adds to the set: a fold-written delete carries
        // no cascade of its own.
        let cascadeCovered = GLSyncDeleteQueue.cascadeCoveredIDs(in: context)

        for change in changes {
            // Types with no registry entry are not synced records — GLSync's own three @Models
            // are the whole of that set, and their history must never become outbox rows.
            // `GLSyncRecordVersion` in particular: it is written on every applied push, so
            // folding it would turn each push into another push, forever.
            guard let entry = GLSyncRegistry.entry(entityName: change.recordType) else { continue }

            guard change.kind != .delete else {
                // The row is gone, but `syncID` carries `@Attribute(.preserveValueOnDeletion)`,
                // so the tombstone still names it. That closes the case this counter was
                // invented for: a delete made anywhere — including a swipe that never went
                // through `enqueueDelete` — now reaches the server instead of being resurrected
                // by the next pull.
                //
                // No cascade is computed here and none is needed: SwiftData emits a delete
                // change per cascaded row, so every child arrives as its own tombstone in the
                // same fold, children before parents. A nil id means a row written before the
                // attribute existed — genuinely unrecoverable, so it stays counted.
                //
                // An APPEND-ONLY row is counted unresolved rather than queued: it has no delete
                // of its own on the wire, so this fold cannot remove it server-side and the
                // next pull WILL bring it back. Saying so out loud is the honest answer; the
                // routed path (`deleteSynced`) is what actually removes one, inside its
                // parent's cascade.
                guard let deletedID = change.deletedSyncID else {
                    unresolvedDeletes += 1
                    continue
                }
                if cascadeCovered.contains(deletedID) { continue }
                if entry.isAppendOnly {
                    unresolvedDeletes += 1
                    continue
                }
                if enqueueResolvedDelete(recordID: deletedID, type: entry.key,
                                         coveredByCascade: cascadeCovered,
                                         at: change.at) { enqueued += 1 }
                continue
            }

            guard let record = index[change.recordID] else { continue }
            guard let recordID = record.glSyncID else {
                // `SyncIdentityBackfill` mints these on launch and `saveChanges` mints them
                // on save, so this is a record saved by neither. It will be picked up on the
                // next cycle once an id exists.
                continue
            }

            let baseVersion = version(for: recordID)

            // With a KNOWN base version, ship exactly the fields history says moved — that is
            // what makes disjoint edits merge invisibly server-side. With base_version 0 the
            // server treats every field as concurrent anyway, so a partial patch would buy
            // nothing and could CREATE a half-empty record (a customer with no name) if the
            // row does not exist server-side. Whole payload is the safe side of that trade.
            // Only the shipped fields are BUILT (QA 2026-10-03 F91): a counter bump on the
            // profile no longer hashes its logos and documents.
            let patch: GLSyncPayload
            if let changed = change.changedFields, baseVersion > 0 {
                patch = entry.payload(record, Set(changed))
            } else {
                patch = entry.payload(record, nil)
            }

            // Tax-class blob references ride like every other one now: the engine seals those
            // bytes before the push and rewrites the reference to the envelope's hash. Nothing
            // is stripped here — a W-9 that never left the device was the regression this
            // whole path exists to close.

            // An update whose only "changed field" was a to-many inverse (adding a group
            // touches its invoice) has nothing to say on the wire. Enqueuing it would push an
            // empty patch and burn an op.
            if patch.isEmpty { continue }

            if let existing = GLSyncOutboxEntry.entry(for: recordID, in: context) {
                // A delete already queued for this record wins: the record is going away, and
                // re-queuing its field edits would resurrect an argument about a dead row.
                guard !existing.isDelete else { continue }
                existing.coalesce(patch, parentID: record.glSyncParentID, at: change.at)
            } else {
                let row = GLSyncOutboxEntry(
                    recordID: recordID,
                    recordType: entry.key,
                    parentID: record.glSyncParentID,
                    baseVersion: baseVersion,
                    fieldsJSON: "",
                    // The moment the write landed, NOT the moment we folded it. The fold cannot
                    // run while the device is offline past its cached token, so "now" here would
                    // really be "when the phone found signal" (see GLSyncHistoryChange.at).
                    firstDirtiedAt: change.at)
                row.fields = patch
                context.insert(row)
            }
            enqueued += 1
        }

        persist()
        return GLSyncFoldResult(newHistoryToken: newToken, enqueued: enqueued,
                                unresolvedDeletes: unresolvedDeletes)
    }

    // MARK: - Outbox → wire

    /// The next chunk. Writes before deletes; writes PARENT-BEFORE-CHILD, deletes
    /// CHILD-BEFORE-PARENT; oldest first inside a tier.
    ///
    /// The two depth directions are not symmetry for its own sake. A create pushed ahead of its
    /// parent is refused `bad_parent`. A DELETE is the mirror image: the Worker refuses to
    /// tombstone a row that still has a live child the op never named (that child could be a
    /// payment recorded on another device, and it will not vaporize one). So a delete that
    /// arrives without a cascade — the history-fold fallback, for a delete that slipped past
    /// `ModelContext.deleteSynced` — only lands if its children died first, in the same request.
    /// Leaf-first is what makes that fallback degrade instead of leaving an invoice stripped of
    /// its line items with its payments still attached.
    ///
    /// `excluding` names ops this cycle already sent and had HELD for a lapsed subscription:
    /// they go again on the next cycle, not round after round of this one (QA 2026-10-03 F17).
    func pendingOps(limit: Int, excluding judged: Set<UUID> = []) -> [GLSyncPendingOp] {
        let rows = GLSyncOutboxEntry.all(in: context)
        var sweep = false
        let usable = rows.filter { row in
            guard row.recordID != nil, GLSyncRegistry.entry(for: row.recordType) != nil else {
                // A row we can neither name nor route. Deleting it is right: it can never be
                // pushed, and leaving it would block the record from ever pulling (§5.4).
                context.delete(row)
                sweep = true
                return false
            }
            guard let opID = row.opID else { return row.isReadyToPush }
            return row.isReadyToPush && !judged.contains(opID)
        }
        if sweep { persist() }

        let pushedAt = Int(Date().timeIntervalSince1970 * 1000)
        return usable
            .sorted { lhs, rhs in
                // Every write this chunk still owes goes out before any death in it.
                if lhs.isDelete != rhs.isDelete { return !lhs.isDelete }
                let left = GLSyncRegistry.depth(of: lhs.recordType)
                let right = GLSyncRegistry.depth(of: rhs.recordType)
                if left != right { return lhs.isDelete ? left > right : left < right }
                return lhs.firstDirtiedAt < rhs.firstDirtiedAt
            }
            .prefix(limit)
            .compactMap { row in
                guard let recordID = row.recordID, let opID = row.opID else { return nil }
                return GLSyncPendingOp(
                    opID: opID,
                    recordID: recordID,
                    recordType: row.recordType,
                    parentID: row.parentID,
                    baseVersion: row.baseVersion,
                    patchJSON: row.fieldsJSON,
                    isDelete: row.isDelete,
                    cascade: row.cascade,
                    clientTS: Self.clientTS(for: row, pushedAt: pushedAt))
            }
    }

    /// When the PERSON edited this record, in unix milliseconds — not when the phone found
    /// signal.
    ///
    /// The server breaks last-writer-wins ties on this number (merge.ts §3.4), so stamping the
    /// whole chunk with push time hands every argument to whichever device syncs LAST: a note
    /// typed on Monday in a basement beats one typed on Tuesday, purely because Monday's phone
    /// surfaced on Wednesday. `firstDirtiedAt` is the moment the record went dirty and is never
    /// re-stamped by a coalesce, which is the value the merge is meant to compare.
    private static func clientTS(for row: GLSyncOutboxEntry, pushedAt: Int) -> Int {
        // LAST edit, not first: the patch carries the last value of every field, so judging it
        // by the moment the record first went dirty would lose today's 5pm price to another
        // device's noon one. `firstDirtiedAt` is the fallback for a row written before that
        // column existed.
        let last = row.lastDirtiedAt.timeIntervalSince1970
        let edited = last > 0 ? last : row.firstDirtiedAt.timeIntervalSince1970
        // `.distantPast` is these columns' stored default — a row materialised without one.
        // Sending it would lose EVERY tie forever, so it degrades to push time.
        guard edited > 0 else { return pushedAt }
        // The server clamps to its own clock anyway; clamping here too keeps a device with a
        // fast clock from claiming an edit time it cannot have had.
        return min(Int(edited * 1000), pushedAt)
    }

    /// Blob bytes referenced by this chunk's patches. Only fields actually being pushed —
    /// re-uploading a logo because an unrelated field changed is pure waste.
    func blobUploads(for ops: [GLSyncPendingOp]) -> [GLSyncBlobUpload] {
        var uploads: [GLSyncBlobUpload] = []
        for op in ops where !op.isDelete {
            guard let entry = GLSyncRegistry.entry(for: op.recordType),
                  !entry.blobFields.isEmpty,
                  let record = entry.fetch(op.recordID, context) else { continue }

            let patch = (op.patchJSON.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? GLSyncPayload) ?? [:]
            let bytesByField = entry.blobBytes(record)

            for field in entry.blobFields {
                guard let sha = GLSyncValue.blobSHA(patch, field),
                      let bytes = bytesByField[field] else { continue }
                uploads.append(GLSyncBlobUpload(
                    recordID: op.recordID,
                    recordType: op.recordType,
                    field: field,
                    sha256: sha,
                    name: GLSyncValue.blobName(patch, field),
                    bytes: bytes))
            }
        }
        return uploads
    }

    // MARK: - Applying push results (GLSYNC-SPEC.md §5.3)

    /// A contested edit, in words (QA 2026-10-03 F87). The server kept the other device's value
    /// and the next pull shows it here; the person's own value stays parked in the outbox. It
    /// does not say "enter it again": the row keeps its first base version, so a re-edit is
    /// contested the same way.
    nonisolated static var conflictMessage: String {
        MBLocalization.string(
            "Another device changed this at the same time, so your change wasn’t backed up. The other device’s version was kept.")
    }

    func applyResults(_ results: [UUID: GLSyncOpResult],
                      for ops: [GLSyncPendingOp]) -> GLSyncPushOutcome {
        var messages: [GLSyncUserMessage] = []
        var changes: [GLSyncRecentChange] = []
        var cleared = 0
        var parked = 0
        var heldOpIDs: Set<UUID> = []
        let now = Date()

        for op in ops {
            guard let row = GLSyncOutboxEntry.entry(for: op.recordID, in: context) else { continue }
            guard let result = results[op.opID] else {
                // The server did not judge this op. Leave the row EXACTLY as it is — assuming
                // success here is how an unsent edit disappears.
                row.attempts += 1
                continue
            }
            // The version stamp, in the SAME save that clears or parks the row it belongs to.
            // A delete the server accepted has no version worth keeping — the record and its
            // whole cascade subtree are gone, and so are their rows.
            if op.isDelete, result.status == .applied || result.status == .cached {
                dropVersion(for: op.recordID)
                for id in op.cascade { dropVersion(for: id) }
            } else if let version = result.version {
                stampVersion(version, for: op.recordID)
            }
            if let head = result.head { stampVersion(head.version, for: head.id) }

            // THE STALE-ROW GUARD, applied to every branch below. A fresh edit that landed
            // WHILE the push was in flight rewrote `fieldsJSON` and re-minted `opID`, so the row
            // sitting at this recordID is no longer the one the server just judged. Clearing it
            // would throw the new edit away; PARKING it is worse — a parked row never pushes
            // again until another edit un-parks it, so an edit made at exactly the wrong second
            // would be frozen out on a verdict that was never about it.
            let isTheRowWeSent = row.opID == op.opID

            switch result.status {
            case .applied, .cached:
                if isTheRowWeSent {
                    context.delete(row)
                    cleared += 1
                }
                for loss in result.lwwLost {
                    changes.append(GLSyncRecentChange(
                        recordID: op.recordID, recordType: op.recordType, field: loss.field,
                        serverValue: loss.serverValue.displayText,
                        kind: .lostToOtherDevice, at: now))
                }

            case .conflict:
                // Protected money fields, or a delete raced by an edit. The value stays
                // PARKED in this row — that is what makes a side-by-side pick possible later
                // — and the record is badged rather than silently overwritten.
                //
                // Law 6, both halves (QA 2026-10-03 F87): one log line for the developer here,
                // and one sentence for the person, which the engine publishes to the screen.
                Logger.data.error("glsync conflict \(op.recordType, privacy: .public) fields=\(result.conflicts.map(\.field).joined(separator: ","), privacy: .public)")
                if isTheRowWeSent {
                    row.park("conflict")
                    parked += 1
                }
                messages.append(GLSyncUserMessage(
                    recordID: op.recordID, recordType: op.recordType,
                    text: Self.conflictMessage, at: now))
                for conflict in result.conflicts {
                    changes.append(GLSyncRecentChange(
                        recordID: op.recordID, recordType: op.recordType, field: conflict.field,
                        serverValue: conflict.serverValue.displayText,
                        kind: .contested, at: now))
                }
                if result.conflicts.isEmpty {
                    // A whole-record conflict (delete vs. edit, or a singleton that already
                    // exists) carries no field list.
                    changes.append(GLSyncRecentChange(
                        recordID: op.recordID, recordType: op.recordType, field: "",
                        serverValue: "", kind: .contested, at: now))
                }

            case .refused:
                // Law 6's developer half: one line per refusal, the record type and the
                // machine word only, never a value (QA 2026-10-03 F87).
                Logger.data.error("glsync refused \(op.recordType, privacy: .public) reason=\(result.reason?.rawValue ?? "unknown", privacy: .public)")
                if result.reason == .subscriptionLapsed {
                    // HELD, never parked (QA 2026-10-03 F17): the Worker does not cache this
                    // refusal, and the same op id goes through the moment the person renews. A
                    // row already held was refused before and the person was told then; saying
                    // it again on every cycle would be a nag. A row re-minted by a newer edit
                    // is not the one judged and is left alone: its own push speaks for it.
                    guard isTheRowWeSent else { continue }
                    heldOpIDs.insert(op.opID)
                    if row.isHeld { continue }
                    row.hold(GLSyncOutboxEntry.lapsedReason)
                    messages.append(GLSyncUserMessage(
                        recordID: op.recordID, recordType: op.recordType,
                        text: GLSyncRefusalReason.subscriptionLapsed.userMessage, at: now))
                    continue
                }
                if isTheRowWeSent {
                    row.park(result.reason?.rawValue ?? "refused")
                    parked += 1
                }
                // The sentence goes out either way: the person's edit WAS refused, and a newer
                // edit to the same record does not make the refusal untrue.
                //
                // A reason this build does not know falls back to `unknownType`'s own sentence
                // rather than a second copy of it — one string, so the fallback is localized by
                // construction and can never drift from the case it stands in for.
                let text = result.reason?.userMessage ?? GLSyncRefusalReason.unknownType.userMessage
                messages.append(GLSyncUserMessage(
                    recordID: op.recordID, recordType: op.recordType, text: text, at: now))
            }
        }

        persist()
        return GLSyncPushOutcome(messages: messages, recentChanges: changes,
                                 cleared: cleared, parked: parked, heldOpIDs: heldOpIDs)
    }

    // MARK: - Applying pulled changes (GLSYNC-SPEC.md §5.4)

    /// THE non-obvious rule: a pulled row overwrites a CLEAN local record; a record with a
    /// pending outbox entry is SKIPPED and reconciles at the next push, where the server
    /// merges per field. Overwriting a dirty record here would discard an edit the server has
    /// not seen yet — the one thing this whole layer exists to prevent.
    func applyChanges(_ rows: [GLSyncRecordRow]) -> GLSyncPullVerdict {
        guard !rows.isEmpty else {
            return .applied(GLSyncPullOutcome(applied: 0, skipped: 0, deleted: 0, unknownType: 0,
                                              blobFetches: [], maxSeq: 0, unlinked: []))
        }

        // Dirty = an unsent outbox row OR an edit saved since the last fold (F16). The engine
        // folds right before every call here; this second half covers a save that lands
        // between that fold and this call, and any caller that did not fold first.
        let pending = GLSyncOutboxEntry.pendingRecordIDs(in: context).union(unfoldedRecordIDs())

        // ---- the mass-delete circuit breaker, BEFORE anything lands -------------------
        //
        // Judged on the whole page: a partial apply would be the worst of both worlds. The
        // threshold is the larger of 25 records and 10% of the store, so a small business
        // with 40 records is not tripped by a legitimate cleanup, and a large one is not
        // wiped by a server bug.
        //
        // COUNTED PER CASCADE ROOT, not per row. One invoice with a few hundred line items is
        // ONE decision a person made, and counting its subtree row by row trips the breaker on
        // the most ordinary delete in the app — which then wedges this device (see
        // `GLSyncState.breakerTrippedAt`). A tombstone whose parent is tombstoned in the same
        // page is part of somebody else's decision, not its own.
        var tombstoned: Set<UUID> = []
        var parentOfTombstoned: [UUID: UUID] = [:]
        for row in rows where row.isTombstone {
            guard !pending.contains(row.id),
                  let entry = GLSyncRegistry.entry(for: row.type),
                  let record = entry.fetch(row.id, context) else { continue }
            tombstoned.insert(row.id)
            // Read from the LOCAL record: a tombstone carries no parent, and this device's copy
            // is the only place the subtree shape still exists.
            if let parentID = record.glSyncParentID { parentOfTombstoned[row.id] = parentID }
        }
        let deletions = tombstoned.filter { id in
            guard let parentID = parentOfTombstoned[id] else { return true }
            // A subtree split across pages counts its orphaned half as roots. That OVER-counts,
            // which fails toward the breaker rather than past it.
            return !tombstoned.contains(parentID)
        }.count
        if deletions > 0 {
            let localTotal = localCounts().values.reduce(0, +)
            let threshold = max(25, localTotal / 10)
            if deletions > threshold {
                // The person may have already looked at this and said "yes, that was me" —
                // that is the one thing that lets a page this size through, and it is spent
                // here so a SECOND surprise still stops.
                if consumeBreakerOverride() {
                    NSLog("glsync: mass-delete breaker overridden by the user (%d deletions)",
                          deletions)
                } else {
                    recordBreakerTrip(deletions: deletions, threshold: threshold)
                    return .massDeleteRefused(deletions: deletions, threshold: threshold)
                }
            }
        }

        var applied = 0
        var skipped = 0
        var deleted = 0
        var unknownType = 0
        var fetches: [GLSyncBlobFetch] = []
        var maxSeq = 0
        var links: [GLSyncParentLink] = []

        // Ascending seq is write order, not tree order, so a child can precede its parent.
        // Payloads land in pass one; parent links are wired in pass two, by which time every
        // parent in this page exists.
        let ordered = rows.sorted { $0.seq < $1.seq }

        for row in ordered {
            maxSeq = max(maxSeq, row.seq)
            guard let entry = GLSyncRegistry.entry(for: row.type) else {
                // A type this build has never heard of. Skipped, not applied blindly, and
                // counted so a version skew is visible rather than silent.
                unknownType += 1
                continue
            }
            guard !pending.contains(row.id) else {
                skipped += 1
                continue
            }

            let existing = entry.fetch(row.id, context)

            if row.isTombstone {
                if let existing {
                    entry.delete(existing, context)
                    deleted += 1
                }
                // Dropped whether or not the record was here: the server says it is gone, so a
                // version row for it can only ever be wrong.
                dropVersion(for: row.id)
                // Only a PARKED row can still be here — an unparked one would have skipped this
                // page above. It holds a value for a record that no longer exists, can never
                // push, and can never be un-parked (un-parking needs a fresh edit to a record
                // the person can no longer open), so leaving it is leaving litter that a later
                // `entry(for:)` would answer with.
                if let stale = GLSyncOutboxEntry.entry(for: row.id, in: context) {
                    context.delete(stale)
                }
                continue
            }

            guard let payload = row.payload.payload else { continue }
            let record = existing ?? entry.createEmpty(context)
            record.glSyncID = row.id
            record.glSyncApply(payload, in: context)
            // Same save as the payload it describes — that is the whole point of the table.
            stampVersion(row.version, for: row.id)
            applied += 1

            if let parentID = row.parentID {
                links.append(GLSyncParentLink(
                    recordID: row.id, recordType: row.type, parentID: parentID))
            }

            // Blob BYTES never ride in a payload — only `{sha256, name}`. Fetch when we do
            // not already hold bytes with that exact hash.
            //
            // Known and accepted for `tax` fields: the reference names the ENVELOPE's hash
            // while the bytes on this device are the plaintext, so the comparison below can
            // never match and a pulled W-9 is re-downloaded even when the local copy is
            // already right. Sealing it here to compare would need the document key on the
            // MainActor, which is exactly where it must not be; the cost is one small
            // download each time another device edits that subcontractor.
            //
            // For the same reason a tax-class field is hashed WITHOUT the blob-hash cache: it
            // could never hit, and the cache would keep the plaintext W-9 (an SSN or EIN) in
            // memory for nothing.
            let localBlobs = entry.blobBytes(record)
            for field in entry.blobFields {
                guard let sha = GLSyncValue.blobSHA(payload, field) else { continue }
                if let bytes = localBlobs[field] {
                    let isTax = GLSyncRegistry.piiClass(type: row.type, field: field) == .tax
                    let local = isTax ? glSyncSHA256(bytes) : GLSyncBlobHashCache.sha256(bytes)
                    if local == sha { continue }
                }
                fetches.append(GLSyncBlobFetch(
                    recordID: row.id, recordType: row.type, field: field, sha256: sha))
            }
        }

        let unresolved = relink(links)
        persist()

        return .applied(GLSyncPullOutcome(
            applied: applied, skipped: skipped, deleted: deleted, unknownType: unknownType,
            blobFetches: fetches, maxSeq: maxSeq, unlinked: unresolved))
    }

    /// Wire pulled records to their cascade parents. The parent id rides in the op ENVELOPE,
    /// never in the patch, so no mapper can do this. Returns the links whose parent has not
    /// arrived yet — the caller retries them after the next page rather than leaving a child
    /// orphaned forever.
    @discardableResult
    func relink(_ links: [GLSyncParentLink]) -> [GLSyncParentLink] {
        var unresolved: [GLSyncParentLink] = []
        for link in links {
            guard let entry = GLSyncRegistry.entry(for: link.recordType),
                  let record = entry.fetch(link.recordID, context) else { continue }
            entry.linkParent(record, link.parentID, context)
            if record.glSyncParentID != link.parentID { unresolved.append(link) }
        }
        persist()
        return unresolved
    }

    /// Write downloaded blob bytes onto a record.
    func applyBlob(_ bytes: Data, to fetch: GLSyncBlobFetch) {
        guard let entry = GLSyncRegistry.entry(for: fetch.recordType),
              let record = entry.fetch(fetch.recordID, context) else { return }
        entry.setBlobBytes(record, fetch.field, bytes)
        persist()
    }

    // MARK: - Bootstrap upload (GLSYNC-SPEC.md §5)

    /// The migration AND the reconciliation: enqueue every local record, PARENT BEFORE
    /// CHILD. Records the snapshot did NOT return are creates. Records it DID return
    /// reconcile as a PER-FIELD DIFF against the pulled payload, at the pulled version.
    ///
    /// Two prior designs each held half a bug (both 2026-08-30). Skipping pulled rows
    /// (`excluding:`) orphaned any edit whose history died un-folded — the rebaseline
    /// half of the name-loss. Re-uploading pulled rows as FULL payloads fixed that and
    /// created the other half: a fresh install pushed its just-pulled (or just-minted,
    /// blank) rows straight back — the empty-profile echoes on the owner's D1 row. The
    /// diff keeps both truths: a byte-identical row enqueues nothing; a locally-newer
    /// field (and ONLY that field) goes on the wire. The account-switch suppression in
    /// `bootstrap()` still guards this path — a store that predates the signed-in
    /// account uploads nothing.
    @discardableResult
    func enqueueEverything(pulled: [UUID: [String: Any]]) -> Int {
        var enqueued = 0
        // `allTypes` is not in depth order; sorting by depth is what makes the queue
        // parent-before-child from the very first push.
        let keys = GLSyncRegistry.allTypes.sorted { GLSyncRegistry.depth(of: $0) < GLSyncRegistry.depth(of: $1) }
        let now = Date()

        for key in keys {
            guard let entry = GLSyncRegistry.entry(for: key) else { continue }
            for record in entry.fetchAll(context) {
                guard let recordID = record.glSyncID else { continue }
                guard GLSyncOutboxEntry.entry(for: recordID, in: context) == nil else { continue }

                // The whole payload, tax-class blob references included: the migration is the
                // one moment every existing W-9 gets its first trip to the server.
                let patch = record.glSyncPayload()

                let fields: [String: Any]
                let baseVersion: Int
                if let serverPayload = pulled[recordID] {
                    // Reconcile: only what the local row knows better than the server.
                    var diff: [String: Any] = [:]
                    for (field, value) in patch where !Self.syncValueEqual(value, serverPayload[field]) {
                        diff[field] = value
                    }
                    guard !diff.isEmpty else { continue }   // identical — no echo, ever
                    fields = diff
                    baseVersion = version(for: recordID)
                } else {
                    fields = patch
                    baseVersion = 0   // never on the server — a create
                }

                let row = GLSyncOutboxEntry(
                    recordID: recordID,
                    recordType: key,
                    parentID: record.glSyncParentID,
                    baseVersion: baseVersion,
                    fieldsJSON: "",
                    firstDirtiedAt: now)
                row.fields = fields
                context.insert(row)
                enqueued += 1
            }
        }
        persist()
        return enqueued
    }

    /// Field-level equality across the sync value space, by JSON normalization —
    /// the exact representation the wire uses, so "equal" here means "the server
    /// would see no change". A field the server lacks is NOT equal to any local
    /// value (it must be pushed).
    static func syncValueEqual(_ local: Any?, _ server: Any?) -> Bool {
        switch (local, server) {
        case (nil, nil): return true
        case let (l?, r?):
            if l is NSNull && r is NSNull { return true }
            // .sortedKeys is load-bearing: nested payload dicts serialize in
            // nondeterministic key order without it, and "equal" would then
            // depend on hashing luck (caught by the reconcile-diff test).
            // A value JSON can't carry (NaN, ∞, a non-JSON type) raises an Objective-C exception
            // that `try?` can't catch — a crash. Such a value is never "equal": it's pushed, and
            // the queue's own encoder refuses it (QA F64).
            guard JSONSerialization.isValidJSONObject([l]), JSONSerialization.isValidJSONObject([r]),
                  let ld = try? JSONSerialization.data(withJSONObject: [l], options: [.sortedKeys]),
                  let rd = try? JSONSerialization.data(withJSONObject: [r], options: [.sortedKeys]) else { return false }
            return ld == rd
        default:
            return (local is NSNull && server == nil) || (local == nil && server is NSNull)
        }
    }

    /// ROOT FIX (2026-08-30 night): move the history watermark off nil, exactly once.
    ///
    /// A nil watermark used to mean "purge everything, read nothing, stay nil" — the
    /// regime under which no field edit could ever reach the outbox. This mint keeps the
    /// build-48 poison purge (deleteHistory never materializes a transaction, so it is
    /// safe on ANY history), then writes one benign transaction of our own and adopts its
    /// token as the baseline: every user edit from this instant forward lands AFTER the
    /// watermark and folds normally. Idempotent — a store that already has a token is
    /// left alone.
    func establishHistoryBaseline() {
        let state = GLSyncState.singleton(in: context)
        guard state.lastHistoryTokenData == nil else { return }
        try? GLSyncHistory.prune(before: .distantFuture, in: context)
        // A real write → a real transaction to watermark. Its OWN field: this used to write
        // `lastSyncAt`, which the Backup row reads as "backed up at" (QA 2026-10-03 F88).
        state.historyBaselineAt = .now
        persist()
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.sortBy = [SortDescriptor(\DefaultHistoryTransaction.transactionIdentifier,
                                            order: .forward)]
        // Sentinel-wrapped: a row saved by another context between the prune above and this
        // read would be materialized here — if it ever can't be, next launch self-repairs.
        guard let latest = withFoldSentinel({ try? context.fetchHistory(descriptor).last }),
              let data = try? JSONEncoder().encode(latest.token) else {
            NSLog("glsync: baseline mint could not read its own transaction — staying nil this cycle")
            return
        }
        state.lastHistoryTokenData = data
        state.historySchemaFingerprint = GLSyncHistory.schemaFingerprint
        persist()
        NSLog("glsync: history baseline established")
    }

    // MARK: - Deletes

    /// Queue a delete with its cascade subtree, read while the record still exists.
    ///
    /// The body lives in `GLSyncDeleteQueue` because the APP calls the same code through
    /// `ModelContext.deleteSynced(_:)` — one implementation of "what a delete looks like on the
    /// wire", so the engine's path and the app's path cannot drift apart.
    @discardableResult
    func enqueueDelete(recordID: UUID, type: String) -> Bool {
        guard let entry = GLSyncRegistry.entry(for: type),
              let record = entry.fetch(recordID, context) else { return false }
        let queued = GLSyncDeleteQueue.enqueue(record, recordID: recordID, type: type, in: context)
        persist()
        return queued
    }

    /// Enqueue a delete for a record that is ALREADY gone locally — the history-fold path.
    ///
    /// `enqueueDelete(recordID:type:)` above needs the live record to walk the cascade and read
    /// the parent id. By the time history is folded there is nothing left to read, so this
    /// writes the op from the tombstone's id alone: no parent (the server tombstones by id, and
    /// parentage only gates CREATES), and no cascade (each cascaded row arrives as its own
    /// tombstone). Any queued edit to the same record is dropped first — it is moot.
    ///
    /// Two things it refuses to queue, both because the op could only ever come back a refusal:
    ///
    ///  * a record ALREADY named in a queued delete's cascade — the routed path shipped the
    ///    whole subtree in one op, and SwiftData's per-row tombstones are the echo of it. A
    ///    second, independent op for the same row re-asks a settled question, and for
    ///    `invoice_payment` it comes back `refused: append_only` and parks a row for a record
    ///    the person can no longer even open to un-park;
    ///  * an APPEND-ONLY type on its own. A payment has no delete of its own on the wire at
    ///    all — it dies inside its parent's verified cascade or not at all.
    ///
    /// `coveredByCascade` is passed in by `fold`, which computes it once for the whole window;
    /// nil means "work it out yourself".
    @discardableResult
    func enqueueResolvedDelete(recordID: UUID, type: String,
                               coveredByCascade covered: Set<UUID>? = nil,
                               at: Date = .now) -> Bool {
        guard let entry = GLSyncRegistry.entry(for: type), !entry.isAppendOnly else { return false }
        let covered = covered ?? GLSyncDeleteQueue.cascadeCoveredIDs(in: context)
        guard !covered.contains(recordID) else { return false }
        if let existing = GLSyncOutboxEntry.entry(for: recordID, in: context) {
            // Already queued as a delete: nothing to add. Otherwise the pending edit dies here.
            if existing.isDelete { return false }
            context.delete(existing)
        }
        let row = GLSyncOutboxEntry(
            recordID: recordID,
            recordType: type,
            parentID: nil,
            baseVersion: version(for: recordID),
            fieldsJSON: "{}",
            isDelete: true,
            firstDirtiedAt: at)
        context.insert(row)
        dropVersion(for: recordID)
        return true
    }
}
