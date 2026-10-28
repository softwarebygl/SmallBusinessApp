//
//  MenuSignOutWarningTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F12 (law 13: warn before a sign-out loses work; law 88: What's New says
//  "If something hasn't backed up yet, the Menu warns you first"). The warning counted only the
//  sync outbox, once, when the Menu appeared. An edit reaches the outbox only through a fold,
//  which ran about 5 s after the save inside a sync cycle, so an edit saved a second before
//  Sign Out read as 0 and the wipe lost it. Now the count folds first, each time the alert
//  opens, parked rows are named apart, and the sign-out pushes before it wipes.
//

import Foundation
import GoldLifeCloud
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MenuSignOutWarningTests {

    // MARK: - The count

    /// A customer saved, then the sync baseline, then an edit a second before Sign Out: the
    /// edit is in history only. The alert must count it.
    @Test func anEditSavedASecondBeforeSignOutIsCountedInTheAlert() async throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Leaving")
        SyncFix.store(container).establishHistoryBaseline()
        let engine = SignOutFlushStub.engine(container, session: { nil })

        let editor = SyncFix.reader(container)
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        let customer = try #require(entry.fetchAll(editor).first { $0.glSyncID == ids[0] } as? Customer)
        customer.firstName = "Edited a second ago"
        try editor.save()

        #expect(MBSessionPurge.unsyncedChangeCount(in: SyncFix.reader(container)) == 0,
                "precondition: the edit is not in the outbox yet (what the old count read)")

        let changes = await MBSessionPurge.unsyncedChanges(engine: engine, context: SyncFix.reader(container))
        #expect(changes == MBSessionPurge.UnsyncedChanges(waiting: 1, parked: 0),
                "the alert read \(changes.total) changes for an edit saved a second before Sign Out")

        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en
        #expect(MBSessionPurge.signOutMessage(changes)
                == "1 change hasn’t been backed up yet. If you sign out now, it’s lost. Connect to the internet first to keep it.")
        await engine.stop()
    }

    /// The audit's own path: a Settings switch in the Menu, then straight to Sign Out.
    @Test func aSettingsSwitchSavedJustBeforeSignOutIsCounted() async throws {
        let container = try TestStore.makeDiskContainer()
        let main = container.mainContext
        main.insert(BusinessProfile())
        main.saveChanges()
        SyncIdentityBackfill.run(ModelContext(container))
        SyncFix.store(container).establishHistoryBaseline()
        let engine = SignOutFlushStub.engine(container, session: { nil })

        try BusinessProfileService.setDisplay(.addressOnDocuments, false, in: main)

        let changes = await MBSessionPurge.unsyncedChanges(engine: engine, context: SyncFix.reader(container))
        #expect(changes.waiting == 1, "a Settings switch saved just before Sign Out read as \(changes.total)")
        await engine.stop()
    }

    /// Asking twice folds nothing twice: the same edit is still one change.
    @Test func countingAgainCountsTheSameEditOnce() async throws {
        let container = try TestStore.makeContainer()
        let ids = SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Twice")
        SyncFix.store(container).establishHistoryBaseline()
        let engine = SignOutFlushStub.engine(container, session: { nil })
        let editor = SyncFix.reader(container)
        let entry = try #require(GLSyncRegistry.entry(for: "customer"))
        let customer = try #require(entry.fetchAll(editor).first { $0.glSyncID == ids[0] } as? Customer)
        customer.firstName = "Once"
        try editor.save()

        _ = await MBSessionPurge.unsyncedChanges(engine: engine, context: SyncFix.reader(container))
        customer.lastName = "Then again"
        try editor.save()
        let changes = await MBSessionPurge.unsyncedChanges(engine: engine, context: SyncFix.reader(container))
        #expect(changes.total == 1, "two edits to one record are one change, got \(changes.total)")
        await engine.stop()
    }

    /// A row the server refused can't be saved by connecting, so it is named apart.
    @Test func parkedChangesAreNamedApartFromWaitingOnes() throws {
        let container = try TestStore.makeContainer()
        let context = SyncFix.reader(container)
        SyncFix.outbox(record: UUID(), type: "customer", in: context)
        let parked = SyncFix.outbox(record: UUID(), type: "invoice", in: context)
        parked.park("conflict")
        try context.save()

        let changes = MBSessionPurge.unsyncedChanges(in: SyncFix.reader(container))
        #expect(changes == MBSessionPurge.UnsyncedChanges(waiting: 1, parked: 1))
        #expect(MBSessionPurge.unsyncedChangeCount(in: SyncFix.reader(container)) == 2,
                "the total still counts every row")

        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en
        #expect(MBSessionPurge.signOutMessage(changes) == "1 change hasn’t been backed up yet. If you sign out now, it’s lost. Connect to the internet first to keep it. 1 other change couldn’t be backed up, so signing out loses it too.")
        #expect(MBSessionPurge.signOutMessage(.init(waiting: 0, parked: 1))
                == "1 change couldn’t be backed up. If you sign out now, it’s lost.",
                "no 'connect to the internet' advice for a change no connection saves")
        #expect(MBSessionPurge.signOutMessage(.init(waiting: 0, parked: 3))
                == "3 changes couldn’t be backed up. If you sign out now, they’re lost.")
        #expect(MBSessionPurge.signOutMessage(.init(waiting: 2, parked: 2))
                .hasSuffix("2 other changes couldn’t be backed up, so signing out loses them too."))
        #expect(MBSessionPurge.signOutMessage(.init()) == "Are you sure you want to sign out of My Business?")
        MBLocalization.shared.language = .es
        #expect(MBSessionPurge.signOutMessage(.init(waiting: 0, parked: 2))
                == "2 cambios no se pudieron respaldar. Si cierras sesión ahora, se pierden.")
        #expect(MBSessionPurge.signOutMessage(.init(waiting: 1, parked: 1))
                .hasSuffix("Otro cambio no se pudo respaldar, así que al cerrar sesión también se pierde."))
    }

    /// The Menu asks when the alert opens, never once on appear.
    @Test func theMenuAsksForTheMessageWhenTheAlertOpens() throws {
        let menu = try #require(GLSource.code("Screens/MenuScreen.swift"))
        #expect(menu.contains("signOutMessageProvider: { await MBSessionPurge.currentSignOutMessage() }"))
        #expect(!menu.contains("unsyncedChangeCount("), "a count taken on appear goes stale in a pushed screen")
        let purge = try #require(GLSource.file("Services/MBSessionPurge.swift"))
        let start = try #require(purge.range(of: "func unsyncedChanges(engine:"))
        let live = try #require(GLSource.balanced("{", "}", from: start.upperBound, in: purge)).inner
        #expect(live.contains("foldNow()"), "the count must fold before it counts")
    }

    // MARK: - The sign-out pushes first

    /// Online, the sign-out's last push goes out before `signedOut()` and the wipe.
    @Test func signingOutPushesTheWaitingEditFirst() async throws {
        let log = SignOutFlushLog()
        SignOutFlushStub.handler = SignOutFlushStub.server(log: log, syncDelay: 0)
        // GoldLifeCloud's transport reads the stored session from this mock (as the cycle-owner
        // and weak-signal suites do; the test plan runs suites one at a time).
        let savedJwt = GLSessionEngine.mockJwt
        GLSessionEngine.mockJwt = SignOutFlushStub.session
        defer {
            SignOutFlushStub.handler = nil
            GLSessionEngine.mockJwt = savedJwt
        }
        let container = try TestStore.makeContainer()
        SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Pushed")
        let engine = SignOutFlushStub.engine(container, session: { SignOutFlushStub.session })

        let finished = await engine.flushBeforeSignOut()
        #expect(finished, "the push did not finish inside the limit on a fast connection")
        #expect(log.paths.contains { $0.hasSuffix("/sync") }, "nothing was pushed before the sign-out went on: \(log.paths)")
        await engine.signedOut()
        await engine.stop()
    }

    /// Weak signal: the sign-out waits at most its limit, then goes on (and `signedOut()` ends
    /// the push still out).
    @Test func aSlowPushNeverHoldsTheSignOutPastItsLimit() async throws {
        let log = SignOutFlushLog()
        SignOutFlushStub.handler = SignOutFlushStub.server(log: log, syncDelay: 1)
        // GoldLifeCloud's transport reads the stored session from this mock (as the cycle-owner
        // and weak-signal suites do; the test plan runs suites one at a time).
        let savedJwt = GLSessionEngine.mockJwt
        GLSessionEngine.mockJwt = SignOutFlushStub.session
        defer {
            SignOutFlushStub.handler = nil
            GLSessionEngine.mockJwt = savedJwt
        }
        let container = try TestStore.makeContainer()
        SyncFix.customers(1, in: SyncFix.reader(container), prefix: "Slow")
        let engine = SignOutFlushStub.engine(container, session: { SignOutFlushStub.session })

        let clock = ContinuousClock()
        let started = clock.now
        let finished = await engine.flushBeforeSignOut(limit: .milliseconds(300))
        let waited = clock.now - started
        #expect(!finished)
        #expect(waited < .seconds(2), "the sign-out waited \(waited) for a push on weak signal")
        await engine.signedOut()
        let state = await engine.state
        #expect(state == .signedOut)
        await engine.stop()
        // Let the slow answer land and its cycle wind down here, not inside the next suite
        // (its store saves would wake another suite's engine mid-test).
        for _ in 0..<50 where log.syncAnswers == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
    }

    /// The order inside `signOut`: flush, then stop, then the wipe.
    @Test func signOutFlushesBeforeItStopsSyncAndWipes() throws {
        let auth = try #require(GLSource.file("Services/GoldLifeAuth.swift"))
        let body = try #require(GLSource.functionBody("signOut", in: auth))
        let flush = try #require(body.range(of: "await Self.flushSync()"))
        let stop = try #require(body.range(of: "await Self.stopSync()"))
        let wipe = try #require(body.range(of: "GLSessionWipe.shared.run(.sessionEnded)"))
        #expect(flush.lowerBound < stop.lowerBound && stop.lowerBound < wipe.lowerBound)
        let flushSync = try #require(GLSource.functionBody("flushSync", in: auth))
        #expect(flushSync.contains("flushBeforeSignOut()"))
    }
}

// MARK: - A stub server for the sign-out flush

/// Every path the stub saw.
nonisolated final class SignOutFlushLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var answered = 0
    func append(_ path: String) { lock.lock(); seen.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    /// `/sync` requests the stub has finished answering.
    func syncAnswered() { lock.lock(); answered += 1; lock.unlock() }
    var syncAnswers: Int { lock.lock(); defer { lock.unlock() }; return answered }
}

/// Answers the identity Worker's mint and gl-business-api in memory. Its own class (not the
/// cycle-owner suite's), so the two suites never share a handler.
nonisolated final class SignOutFlushStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    /// A JWT-shaped session whose payload carries `sub` (the provider reads it unverified).
    static let session = jwt(sub: "stytch-session-flush")
    static let appToken = jwt(sub: "glid-flush")

    static func jwt(sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    static func server(log: SignOutFlushLog, syncDelay: TimeInterval) -> (URLRequest) -> (Int, String) {
        { request in
            let path = request.url?.path ?? ""
            log.append(path)
            if path.hasSuffix("auth/app-token") { return (200, #"{"token":"\#(appToken)","expires_in":900}"#) }
            if path.hasSuffix("/snapshot") { return (200, #"{"records":[]}"#) }
            if path.hasSuffix("/sync") {
                if syncDelay > 0 { Thread.sleep(forTimeInterval: syncDelay) }
                log.syncAnswered()
                return (200, #"{"results":{},"changes":[],"new_cursor":1}"#)
            }
            if path.hasSuffix("/checksums") { return (200, #"{"types":{},"tombstones":0}"#) }
            return (404, #"{"error":"not_found"}"#)
        }
    }

    @MainActor
    static func engine(_ container: ModelContainer, session: @escaping @Sendable () -> String?) -> GLSyncEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SignOutFlushStub.self]
        let cloud = GLCloudTransport(session: URLSession(configuration: config), sessionEngine: GLSessionEngine())
        return GLSyncEngine(
            container: container,
            tokens: GLSyncTokenProvider(transport: cloud, storedSessionJWT: session, onSessionExpired: {}),
            cloud: cloud,
            documents: GLSyncDocumentCrypto(transport: cloud, storedSessionJWT: session, onSessionExpired: {}))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
