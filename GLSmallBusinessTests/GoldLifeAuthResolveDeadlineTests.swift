//
//  GoldLifeAuthResolveDeadlineTests.swift
//  GLSmallBusinessTests
//
//  A cold launch never waits on the network for more than about 3 seconds (audit 2026-10-03
//  F22; platform rule "gates never wait on the network"). On one bar of signal or captive
//  Wi-Fi, Stytch's session check used to hold the splash for up to its 60 s request timeout.
//  Now the launch lands on the stored session at the limit, and the check keeps going: if
//  Stytch then refuses the session, the session-expiry teardown still runs.
//

import Foundation
import Testing
@testable import GLSmallBusiness

@MainActor
// The limit only matters for a regression: the old code waited on Stytch with no limit at all.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GoldLifeAuthResolveDeadlineTests {

    /// Work the TEST releases — never a wall-clock race.
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    @Test func aStalledSessionCheckLandsSignedInWithinTheLaunchLimit() async {
        let auth = GoldLifeAuth()
        var refusals = 0
        // One bar of signal: Stytch's request hangs for its whole 60 s timeout. A gate the test
        // opens at the end stands in for it, so no 60 s task outlives the test.
        let stytch = Gate()
        auth.sessionSource = .init(
            hasPersistedSession: { true },
            authenticate: { await stytch.wait() },
            refusedAfterLanding: { _ in refusals += 1 })

        let started = ContinuousClock.now
        await auth.resolve()
        let waited = ContinuousClock.now - started

        #expect(auth.state == .signedIn, "the stored session must stand while Stytch is unreachable")
        #expect(waited < .milliseconds(3_500), "the splash waited \(waited) for the network")
        #expect(!auth.didSignInThroughDoor, "a restored session keeps the cold Face ID lock")
        #expect(refusals == 0)
        #expect(GoldLifeAuth.sessionCheckLimit == .seconds(3))
        stytch.release()
    }

    @Test func aRefusalThatArrivesAfterTheLandingStillEndsTheSession() async throws {
        let auth = GoldLifeAuth()
        auth.sessionCheckLimit = .milliseconds(50)
        let stytch = Gate()
        var stored = true
        var refusals = 0
        auth.sessionSource = .init(
            hasPersistedSession: { stored },
            authenticate: {
                await stytch.wait()
                stored = false          // Stytch refused it and cleared the stored copy
            },
            refusedAfterLanding: { _ in refusals += 1 })

        await auth.resolve()
        #expect(auth.state == .signedIn)
        #expect(refusals == 0, "nothing is refused before Stytch answers")

        stytch.release()
        for _ in 0..<200 where refusals == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(refusals == 1, "a late refusal must run the session-expiry teardown")
    }

    @Test func aLateNetworkFailureLeavesTheSessionAlone() async throws {
        let auth = GoldLifeAuth()
        auth.sessionCheckLimit = .milliseconds(50)
        let stytch = Gate()
        var finished = false
        var refusals = 0
        auth.sessionSource = .init(
            hasPersistedSession: { true },
            // A timeout, not a refusal: Stytch keeps the stored session (owner ruling
            // 2026-09-28: weak signal never ends a session).
            authenticate: { await stytch.wait(); finished = true },
            refusedAfterLanding: { _ in refusals += 1 })

        await auth.resolve()
        stytch.release()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(finished && refusals == 0 && auth.state == .signedIn)
    }
}
