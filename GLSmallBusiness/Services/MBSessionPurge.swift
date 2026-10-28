//
//  MBSessionPurge.swift
//  GLSmallBusiness
//
//  My Business's part of the fleet's ONE sign-out wipe (GoldLifeUI REQUIREMENTS law 13,
//  owner ruling 2026-09-26: "every Gold Life app wipes"; GoldLifeCloud `GLSessionWipe`).
//  Signing out, a session Stytch ended, and a launch with no session all run the same
//  registered step: the person's local copy leaves the device —
//    - every per-person SwiftData store (`Application Support/Stores/…`), and the legacy
//      default store is marked for the next launch's wipe (it is held open until then);
//    - the documents the app generated into the temporary folder (PDFs, a W-9 with a full
//      Tax ID, year-end CSVs);
//    - the assistant consent (law 74 `GLAIConsent.reset()`), so the next person on this
//      iPhone is asked again;
//    - the Stripe install token of the account whose session ended, and any pre-3.3.0 unscoped
//      token still on the device (audit 2026-10-03 F2): the next person can never mint a pay
//      link on this business's Stripe account. Get Paid by Card resumes the same account after
//      the next sign-in ("Reconnect this device").
//  The server (gl-business-api) is the store of record: the next sign-in pulls everything
//  back through GLSync (`MBSessionPurgeTests` proves it). Before a sign-out the Menu warns
//  when changes are still waiting in the sync outbox, because those are the only thing a
//  wipe can lose. The warning folds the newest edits into the outbox before it counts, each
//  time the alert opens, and the sign-out pushes them first when online (audit 2026-10-03 F12).
//
//  NOT wiped at sign-out: Tax IDs in the Keychain (SecureTINStore). They are never backed up,
//  so deleting them would lose them for good instead of re-downloading them. The BUSINESS Tax
//  ID's item is keyed to the Gold Life ID (2026-09-29), and this step drops the signed-in scope,
//  so a different person who signs in on the same iPhone can never read it. (Whether the
//  subcontractors' Tax IDs stay after a sign-out is the owner's open question 6(d), C57.)
//  DELETING the Gold Life ID does erase them all — the business Tax ID and every
//  subcontractor's — before the store goes (GoldLifeAuth.purgeAccountSecrets, law 73, audit
//  2026-10-03 F58): that person asked for everything to be erased.
//
//  Supersedes `UserScopedStore.endSessionKeepingCache()` (the 2026-08-28 "keep the synced
//  cache" ruling, superseded 2026-09-26).
//

import Foundation
import SwiftData
import OSLog
import GoldLifeCloud
import GoldLifeAI

@MainActor
enum MBSessionPurge {
    /// The step's name in `GLSessionWipe` (one per app).
    static let stepName = "my-business"

    private static let log = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness", category: "SessionPurge")

    /// Registers My Business's step. Called once at launch; registering again replaces it.
    static func registerWipe() { registerWipe(GLSessionWipe.shared) }

    static func registerWipe(_ wipe: GLSessionWipe) {
        wipe.register(stepName) { reason in
            // Whose session is ending, read BEFORE the scope is dropped: their Stripe token goes.
            // (nil on a launch with nobody signed in: nothing of anyone's is touched then.)
            let signingOut = SecureTINStore.accountScope
            // Nobody is signed in now: the business Tax ID has no account to read for.
            // (The DEBUG screenshot harness runs with the gate off on an account of its own.)
            if !DemoMode.isActive { SecureTINStore.setAccountScope(nil) }
            run(reason,
                store: .shared,
                consent: MBAssistantSession.shared.consent,
                appSupport: UserScopedStore.applicationSupport(),
                temporary: FileManager.default.temporaryDirectory,
                stripeTokenScope: signingOut)
        }
    }

    /// The step itself, with every place it touches injectable (tests).
    static func run(_ reason: GLSessionWipe.Reason, store: UserScopedStore, consent: GLAIConsent,
                    appSupport: URL?, temporary: URL,
                    stripeTokenScope: String? = nil,
                    stripeTokenService: String = StripeInstallTokenStore.service) {
        consent.reset()
        AISessionPurge.wipeAll(connectionStore: .shared, chatService: .shared)
        StripeInstallTokenStore.purgeSession(of: stripeTokenScope, service: stripeTokenService)
        UserDefaults.standard.removeObject(forKey: "mb.money.selectedAccountIds")
        store.wipeLocalCopy(appSupport: appSupport)
        clearContents(of: temporary)
        log.info("session purge ran: \(String(describing: reason), privacy: .public)")
    }

    /// Everything inside `folder`, never the folder itself (iOS owns the temporary directory).
    static func clearContents(of folder: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    // MARK: - The warning before a sign-out

    /// What a sign-out would lose, split by whether a connection can still save it.
    struct UnsyncedChanges: Equatable {
        /// Waiting to be backed up. A connection saves them (the sign-out pushes them first).
        var waiting = 0
        /// Parked: the server already refused them (a conflict, a paid invoice's locked lines).
        /// No connection saves these, so the warning never tells the person to connect for them.
        var parked = 0

        var total: Int { waiting + parked }
    }

    /// Every row in the sync outbox of the mounted store, parked ones included (0 when nothing
    /// is mounted). Counts only what is already IN the outbox: the Menu folds first
    /// (`unsyncedChanges(engine:context:)`).
    static func unsyncedChangeCount(in context: ModelContext?) -> Int {
        unsyncedChanges(in: context).total
    }

    /// The outbox rows of the mounted store, waiting and parked apart.
    static func unsyncedChanges(in context: ModelContext?) -> UnsyncedChanges {
        guard let context, let rows = try? context.fetch(FetchDescriptor<GLSyncOutboxEntry>()) else {
            return UnsyncedChanges()
        }
        let parked = rows.filter(\.isParked).count
        return UnsyncedChanges(waiting: rows.count - parked, parked: parked)
    }

    /// What the sign-out alert counts (audit 2026-10-03 F12): the edits saved since the last
    /// fold go into the outbox first (local, no network), then the outbox is counted. Counting
    /// the outbox alone read 0 for an edit saved seconds before: edits reach it only through a
    /// fold, which ran about 5 s after a save and never while the breaker was paused.
    static func unsyncedChanges(engine: GLSyncEngine?, context: ModelContext?) async -> UnsyncedChanges {
        if let engine { await engine.foldNow() }
        return unsyncedChanges(in: context)
    }

    /// The Menu's Sign Out message, worked out each time the alert opens (never once per visit
    /// to the Menu: an edit made in a screen the Menu pushed would not be in it).
    static func currentSignOutMessage() async -> String {
        #if DEBUG
        if let harness = MBSignOutWarningHarness.active {
            return signOutMessage(await unsyncedChanges(engine: harness.engine, context: ModelContext(harness.container)))
        }
        #endif
        let store = UserScopedStore.shared
        return signOutMessage(await unsyncedChanges(engine: store.activeEngine, context: store.activeMainContext))
    }

    /// The sign-out alert's message, with parked changes named apart: connecting first saves
    /// the waiting ones, never the parked ones.
    static func signOutMessage(_ changes: UnsyncedChanges) -> String {
        guard changes.parked > 0 else { return signOutMessage(unsyncedChanges: changes.waiting) }
        guard changes.waiting > 0 else {
            return changes.parked == 1
                ? mbLoc("1 change couldn’t be backed up. If you sign out now, it’s lost.")
                : mbLoc("\(changes.parked) changes couldn’t be backed up. If you sign out now, they’re lost.")
        }
        let parked = changes.parked == 1
            ? mbLoc("1 other change couldn’t be backed up, so signing out loses it too.")
            : mbLoc("\(changes.parked) other changes couldn’t be backed up, so signing out loses them too.")
        return signOutMessage(unsyncedChanges: changes.waiting) + " " + parked
    }

    /// The sign-out alert's message: the warning first when changes would be lost.
    static func signOutMessage(unsyncedChanges: Int) -> String {
        switch unsyncedChanges {
        case ...0:
            return mbLoc("Are you sure you want to sign out of My Business?")
        case 1:
            return mbLoc("1 change hasn’t been backed up yet. If you sign out now, it’s lost. Connect to the internet first to keep it.")
        default:
            return mbLoc("\(unsyncedChanges) changes haven’t been backed up yet. If you sign out now, they’re lost. Connect to the internet first to keep them.")
        }
    }
}
