import SwiftData
import Foundation
import OSLog

@MainActor
final class UserScopedStore {
    static let shared = UserScopedStore()

    private static let log = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness",
                                    category: "UserScopedStore")
    
    private var activeContainer: ModelContainer?
    /// The mounted user's main context, or nil when nobody is signed in (or the
    /// sample-data host is up). Read-only convenience for composers that need
    /// the signed-in person's UserProfile (e.g. the email signature's name).
    var activeMainContext: ModelContext? { activeContainer?.mainContext }
    private var currentCanonicalID: String?
    /// The sync engine attached to the ACTIVE user store. Held strongly here —
    /// GLSyncEngine.current is deliberately weak, and an unheld engine silently
    /// stops syncing. Set by SignedInHost on mount, dropped by the wipe below.
    var activeEngine: GLSyncEngine?
    
    /// This app's Application Support folder, or nil if the system hands out none. Never seen on
    /// a real device, but the lookup returns a list, so the empty case is answered, not trapped.
    nonisolated static func applicationSupport() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// `<appSupport>/Stores/<sanitized id>` — the one place the person's store folder is named,
    /// so mounting and the account-deletion wipe can never point at different folders.
    nonisolated static func storeDirectory(for canonicalID: String, in appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Stores").appendingPathComponent(sanitized(canonicalID))
    }

    /// Returns the active ModelContainer for the current user, or a default one if none is set.
    /// `appSupport` is injectable so a test can take the no-folder path.
    func container(for canonicalID: String?,
                   appSupport: URL? = UserScopedStore.applicationSupport()) -> ModelContainer {
        if let currentCanonicalID = currentCanonicalID, currentCanonicalID == canonicalID, let activeContainer = activeContainer {
            return activeContainer
        }
        
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let config: ModelConfiguration

        if let canonicalID = canonicalID, !canonicalID.isEmpty {
            if let appSupport {
                let storeDir = Self.storeDirectory(for: canonicalID, in: appSupport)

                try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true, attributes: nil)

                let storeURL = storeDir.appendingPathComponent("GLSmallBusiness.store")
                config = ModelConfiguration(schema: schema, url: storeURL)
            } else {
                // No folder to keep the person's store in. Never the shared default store (that
                // would mix accounts): this session runs in memory — the store is a cache of the
                // backend, so sync re-downloads — and the root alert says changes won't be kept.
                Self.log.fault("[user-store] no Application Support folder; running this session in memory")
                StoreRecovery.noteMemoryOnly()
                config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            }
        } else {
            // Default store when signed out or no ID provided
            config = ModelConfiguration(schema: schema)
        }

        // No crash path: this runs on EVERY sign-in, so a fatalError here wasn't
        // a crash, it was a permanent lockout — the same bad store would kill the
        // app at the gate on every attempt. Nor a wipe (QA 2026-10-03 F63): a full
        // disk keeps the store and runs in memory; a store this build can't read
        // moves to `Stores/<id>/Recovered/`, its unsent changes are copied into the
        // rebuilt store, and sync re-downloads the rest (StoreRecovery, alert + log).
        let container = StoreRecovery.openContainer(schema: schema,
                                                    migrationPlan: GLMigrationPlan.self,
                                                    configuration: config,
                                                    label: "user-store")
        self.activeContainer = container
        self.currentCanonicalID = canonicalID
        return container
    }

    /// The canonical id arrives from the server and lands in a FILENAME, so it is
    /// reduced to characters that cannot mean anything to a path: a stray "/" or
    /// ".." would write outside this directory — real ids are UUIDs and pass through untouched.
    nonisolated static func sanitized(_ canonicalID: String) -> String {
        let safe = canonicalID.prefix(64).map { character -> Character in
            let keep = character.isASCII && (character.isLetter || character.isNumber || character == "-")
            return keep ? character : "_"
        }
        return String(safe)
    }
    
    /// Sign-out, a session Stytch ended, and a launch with no session WIPE the local copy
    /// (REQUIREMENTS law 13, owner ruling 2026-09-26 — superseding the 2026-08-28 "keep the
    /// synced cache" reading): every per-person store folder under `Stores/` goes (a launch
    /// with no session doesn't know whose it was, and nobody's may stay), the live references
    /// drop, and the legacy default store — held open by the launch container — is marked for
    /// the next launch's wipe. The server is the store of record; the next sign-in pulls it
    /// all back. Called through `MBSessionPurge` (GLSessionWipe), after the signed-in subtree
    /// has unmounted. `appSupport` is injectable so a test can use its own folder.
    /// The copies `StoreRecovery` moved aside go too (F63): each person's sits inside their
    /// `Stores/<id>/` folder, the launch store's in `<appSupport>/Recovered`.
    func wipeLocalCopy(appSupport: URL? = UserScopedStore.applicationSupport()) {
        dropActiveEngine()
        activeContainer = nil
        currentCanonicalID = nil
        if let appSupport {
            for folder in ["Stores", "Recovered"] {
                let url = appSupport.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Self.log.error("[user-store] session wipe could not remove the \(folder, privacy: .public) folder")
                }
            }
        }
        UserDefaults.standard.set(true, forKey: Self.pendingDefaultStoreWipeKey)
    }

    /// Account DELETION wipes too (and then runs the session wipe above): the account no longer exists
    /// server-side, so a cache of it is not "your data offline", it is a copy of
    /// a dead account sitting on a device. Removes the user's store directory
    /// and the legacy soft-gate-era default store, and drops the live refs.
    /// `appSupport` is injectable so a test can take the no-folder path.
    func wipeOnAccountDeletion(appSupport: URL? = UserScopedStore.applicationSupport()) {
        dropActiveEngine()
        activeContainer = nil

        if let canonicalID = currentCanonicalID, !canonicalID.isEmpty {
            if let appSupport {
                try? FileManager.default.removeItem(at: Self.storeDirectory(for: canonicalID, in: appSupport))
            } else {
                // No Application Support folder means the store was never on disk (the mount ran
                // in memory, see `container(for:)`) — nothing to remove. Log it, never trap.
                Self.log.error("[user-store] no Application Support folder at account deletion; nothing on disk to wipe")
            }
        }
        currentCanonicalID = nil

        // NOT wiped now: the launch container still holds the default store OPEN,
        // and deleting a store file behind a live container is undefined behavior
        // (CRUD audit 2026-09-02 — the one documented-practice violation found).
        // Mark it instead; the next launch wipes BEFORE the container opens.
        UserDefaults.standard.set(true, forKey: Self.pendingDefaultStoreWipeKey)
    }

    /// Stop the engine, THEN let it go (QA 2026-10-03 F150). Dropping the reference alone left
    /// its path monitor and trigger loops running for as long as anything else held it — a cycle
    /// still finishing does — and every sign-in attaches a new one. Its own task because the
    /// engine is an actor and the wipes are synchronous; the task holds the engine until the
    /// stop has run.
    private func dropActiveEngine() {
        if let engine = activeEngine {
            Task { await engine.stop() }
        }
        activeEngine = nil
    }

    /// See `wipeOnAccountDeletion`. Read by the App BEFORE `sharedModelContainer`
    /// is created, which is the only moment the file is safe to remove.
    static let pendingDefaultStoreWipeKey = "mb.pendingDefaultStoreWipe"
}
