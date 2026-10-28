//
//  SessionEndTraceTests.swift
//  GLSmallBusinessTests
//
//  What a session leaves behind for the next person on the device: nothing (Zero Account Bleed,
//  R2). Sign-out, session expiry, account deletion and an account switch clear the server's
//  comp/owner word (`mb.entitlement`), the assistant's last StoreKit read, the chat and the AI
//  consent — and the chat was never anywhere but memory to begin with.
//
//  The three exits themselves revoke a Stytch session and stop GLSync, so they are pinned by a
//  source scan (the defects this guards were MISSING CALLS, which only a scan can catch); what
//  they call is exercised for real.
//

import Foundation
import GoldLifeAI
import GoldLifeUI
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct SessionEndTraceTests {

    // MARK: - Every exit calls the clears

    @Test func everySessionExitClearsTheEntitlementWordTheChatAndTheConsent() throws {
        let auth = try #require(GLSource.file("Services/GoldLifeAuth.swift"))
        for exit in ["signOut", "handleSessionExpired", "deleteAccount"] {
            let body = try #require(GLSource.functionBody(exit, in: auth), "\(exit) not found")
            #expect(body.contains("MBAssistantSession.shared.endSession()"),
                    "\(exit) must end the assistant's session (chat + consent)")
            #expect(body.contains("clearAccountEntitlement()"),
                    "\(exit) must clear the server's comp word — the next person inherits it otherwise")
        }
        // An account that changed under a cold launch (no sign-out ran) is cleared the same way.
        let reconcile = try #require(GLSource.functionBody("reconcilePrefOwner", in: auth))
        #expect(reconcile.contains("consent.reset()") && reconcile.contains("clearAccountEntitlement()"))

        // endSession is the conversation fence plus the consent.
        let session = try #require(GLSource.file("AI/MBAssistantSession.swift"))
        let endSession = try #require(GLSource.functionBody("endSession", in: session))
        #expect(endSession.contains("cancelAndWait()") && endSession.contains("consent.reset()"))

        // The launch gate settles whose session it is BEFORE it reads that session's entitlement.
        let gate = try #require(GLSource.file("AccessControl/GatePhase.swift"))
        let mount = try #require(GLSource.functionBody("mount", in: gate))
        let reconcileAt = try #require(mount.range(of: "GoldLifeAuth.reconcilePrefOwner()"))
        let resolveAt = try #require(mount.range(of: "MBLaunchEntitlement.resolve()"))
        #expect(reconcileAt.lowerBound < resolveAt.lowerBound)
        #expect(!gate.contains("CustomerPronounCleanup"), "the app never deletes anything on its own")
    }

    // MARK: - A teardown is never raced by the remembered door (audit 2026-10-03 F62)

    /// Expiry flipped to signed-out, then awaited the revoke, then wiped. The gate's remembered
    /// door ran in that gap, and the old teardown then revoked the NEW session and deleted the
    /// store it had just mounted. Now the door waits until the wipe has finished.
    @Test func afterExpiryTheRememberedDoorWaitsUntilTheWipeHasFinished() async throws {
        let auth = GoldLifeAuth()
        let events = TeardownEvents()
        let revoke = TeardownGate()

        let teardown = Task { @MainActor in
            await auth.runTeardown(keepDoorSuppressed: false) {
                events.append("signed-out")
                await revoke.wait()          // the revoke, still on the wire
                events.append("wiped")
            }
        }
        for _ in 0..<100 where !events.all.contains("signed-out") { await Task.yield() }
        #expect(auth.isBusy, "the doors must stay disabled for the whole teardown")

        let door = Task { @MainActor in
            let mayRun = await auth.mayRunRememberedDoor()
            events.append(mayRun ? "door" : "no-door")
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!events.all.contains("door"), "the remembered door ran before the wipe: \(events.all)")

        revoke.open()
        await teardown.value
        await door.value
        #expect(events.all == ["signed-out", "wiped", "door"],
                "an expiry may sign back in through the remembered door, but only after the wipe: \(events.all)")
        #expect(!auth.isBusy && !auth.isTearingDown)
    }

    /// A chosen sign-out keeps the remembered door shut after its wipe (law 30).
    @Test func afterAChosenSignOutTheRememberedDoorStaysShut() async {
        let auth = GoldLifeAuth()
        await auth.runTeardown(keepDoorSuppressed: true) {}
        #expect(await auth.mayRunRememberedDoor() == false)
        #expect(await auth.mayRunRememberedDoor() == true, "one-shot: a later cold gate auto-continues")
    }

    /// A different session live by the time the teardown reaches its revoke is left alone.
    @Test func aTeardownNeverRevokesOrWipesADifferentSession() throws {
        #expect(GoldLifeAuth.isSameSession("old", live: "old"))
        #expect(GoldLifeAuth.isSameSession("old", live: nil), "Stytch already cleared it: still this teardown's")
        #expect(!GoldLifeAuth.isSameSession("old", live: "new"))
        #expect(!GoldLifeAuth.isSameSession(nil, live: "new"))

        let auth = try #require(GLSource.file("Services/GoldLifeAuth.swift"))
        let expired = try #require(GLSource.functionBody("handleSessionExpired", in: auth))
        #expect(expired.contains("runTeardown(keepDoorSuppressed: false)"))
        let check = try #require(expired.range(of: "isSameSession(endingSession, live: Self.liveSessionToken)"))
        let revoke = try #require(expired.range(of: "StytchClient.sessions.revoke"))
        let wipe = try #require(expired.range(of: "GLSessionWipe.shared.run(.sessionEnded)"))
        #expect(check.lowerBound < revoke.lowerBound && revoke.lowerBound < wipe.lowerBound)
        let signOut = try #require(GLSource.functionBody("signOut", in: auth))
        #expect(signOut.contains("runTeardown(keepDoorSuppressed: true)"))

        let gate = try #require(GLSource.file("AccessControl/SignInScreen.swift"))
        let auto = try #require(GLSource.functionBody("autoContinueIfRemembered", in: gate))
        #expect(auto.contains("await auth.mayRunRememberedDoor()"), "the gate must wait for the teardown")
        #expect(!auto.contains("consumeAutoDoorSuppression()"), "the gate must not decide before the teardown ends")
    }

    // MARK: - What the clear leaves

    /// Synchronous on purpose: suites share the main actor, and nothing can interleave with a
    /// test body that never suspends — the shared subscription is back as it was before any
    /// other test can read it.
    @Test func clearingTheEntitlementLeavesNothingForTheNextPerson() {
        let subs = SubscriptionManager.shared
        let defaults = UserDefaults.standard
        let key = MBAIEntitlement.storedAnswerKey
        let before = (source: subs.serverSource, entitled: subs.serverEntitled, answered: subs.serverAnswered,
                      tier: subs.tier, standing: subs.standing)
        let storedBefore = defaults.data(forKey: key)
        let vipBefore = defaults.object(forKey: "mb.isVip")
        defer {
            subs.setTestEntitlement(serverSource: before.source, serverEntitled: before.entitled,
                                    tier: before.tier, standing: before.standing, serverAnswered: before.answered)
            if let storedBefore { defaults.set(storedBefore, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let vipBefore { defaults.set(vipBefore, forKey: "mb.isVip") } else { defaults.removeObject(forKey: "mb.isVip") }
        }

        // The owner's word, answered and on record.
        subs.setTestEntitlement(serverSource: "owner", serverEntitled: true, serverAnswered: true)
        defaults.set(Data("{}".utf8), forKey: key)
        defaults.set(true, forKey: "mb.isVip")
        #expect(MBAIEntitlement.isComped(subs) && MBAIEntitlement.compAnswerKnown(subs))

        GoldLifeAuth.clearAccountEntitlement()

        #expect(!subs.serverEntitled && subs.serverSource == "none" && !subs.serverAnswered)
        #expect(defaults.data(forKey: key) == nil, "the persisted comp answer must not survive the session")
        #expect(defaults.object(forKey: "mb.isVip") == nil)
        #expect(!MBAIEntitlement.isComped(subs), "the next person is not comped on the owner's word")
        #expect(!MBAIEntitlement.compAnswerKnown(subs), "…and is asked about afresh, never told Upgrade early")
        #expect(!MBAIEntitlement.shared.hasLoaded && !MBAIEntitlement.shared.hasCurrentAIPeriod,
                "the assistant's last StoreKit read belonged to the last session")
    }

    // MARK: - The chat is memory only

    /// A reply that repeats the question, so the marker exists in both halves of the chat.
    private nonisolated final class EchoTransport: GLAITurnTransport {
        nonisolated func send(_ request: GLAITurnRequest) async throws -> GLAITurnResponse {
            GLAITurnResponse(step: GLAIModelStep(text: "Noted: \(SessionEndTraceTests.marker)", providerState: "ps-echo"),
                             done: true)
        }
    }

    nonisolated static let marker = "zebra-lantern-7731-chat-marker"

    @Test func aConversationIsNeverWrittenToDefaultsOrDiskAndTheFenceEmptiesIt() async throws {
        let started = Date()
        let context = try DomainFixtures.context()
        let box = try MBToolHarness.toolbox(context)
        let controller = GLAIConversationController(
            toolbox: box.online,
            transport: EchoTransport(),
            configuration: .init(appName: MBAssistantSession.appName,
                                 context: { GLAIHostContext(language: "en", appVersion: "test") },
                                 isOnline: { true },
                                 isSampleMode: { false }))

        controller.send("Remember \(Self.marker) for me")
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!controller.isBusy)
        let transcript = controller.messages.map { String(describing: $0.content) }.joined(separator: "\n")
        #expect(transcript.contains(Self.marker), "the exchange happened: \(transcript)")

        // Not in UserDefaults…
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let inDefaults = defaults.filter { String(describing: $0.value).contains(Self.marker) }.map(\.key)
        #expect(inDefaults.isEmpty, "chat text reached UserDefaults under \(inDefaults)")

        // …and not in any file this app wrote since the chat began.
        let written = Self.filesModified(since: started, under: URL(fileURLWithPath: NSHomeDirectory()))
        let marker = Data(Self.marker.utf8)
        let holding = written.filter { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return data.range(of: marker) != nil
        }
        #expect(holding.isEmpty, "chat text reached disk: \(holding.map(\.lastPathComponent))")

        // The session fence (sign-out, expiry, account deletion) leaves nothing behind.
        await controller.cancelAndWait()
        #expect(controller.messages.isEmpty)
    }

    /// Regular files under `root` modified at or after `date` (bounded, so a large sandbox can't
    /// stall the suite).
    private static func filesModified(since date: Date, under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) < 50_000_000,
                  let modified = values.contentModificationDate,
                  modified >= date.addingTimeInterval(-1) else { continue }
            found.append(url)
        }
        return found
    }
}

/// What a teardown test saw, in order.
@MainActor
final class TeardownEvents {
    private(set) var all: [String] = []
    func append(_ event: String) { all.append(event) }
}

/// A step the test holds open (the revoke still on the wire) until it says go.
@MainActor
final class TeardownGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
