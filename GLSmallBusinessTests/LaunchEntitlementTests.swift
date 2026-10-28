//
//  LaunchEntitlementTests.swift
//  GLSmallBusinessTests
//
//  The entitlement is KNOWN before the person lands (owner ruling 2026-09-25 (8)), and the
//  assistant never says Upgrade to a comped owner or makes a message wait on StoreKit:
//  - GET /entitlement puts the app in a query item, never in the path (the build-79 `%3F` 404
//    that hid every comp);
//  - the gate's state, its neutral "checking" state and the JWS plan are pure functions;
//  - the launch wait is bounded and never cancels a read — a late answer lands on its own;
//  - a slow StoreKit read turns into "couldn't confirm" at its limit, then applies when it lands.
//

import Foundation
import GoldLifeAI
import GoldLifeCloud
import StoreKit
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct LaunchEntitlementTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func txn(expiresIn seconds: TimeInterval = 86_400, jws: String = "signed") -> MBAITransactionFacts {
        MBAITransactionFacts(productID: SubscriptionManager.aiMonthlyID,
                             expirationDate: now.addingTimeInterval(seconds),
                             revocationDate: nil, isUpgraded: false, isPurchasedByThisPerson: true, jws: jws)
    }

    /// Work the TEST releases — never a wall-clock race, so a busy main actor (other suites'
    /// hosting tests) can't reorder "the limit passed" and "the work finished".
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

    /// StoreKit without StoreKit: answers what it is told, can be held, and counts its reads.
    private final class FakeStoreKit: MBAIStoreKitReading {
        var transactions: [MBAITransactionFacts] = []
        var statuses: [MBAIStatusFacts] = []
        var statusGate: Gate?
        private(set) var transactionReads = 0

        func aiTransactions() async -> [MBAITransactionFacts] {
            transactionReads += 1
            return transactions
        }

        func aiStatuses() async throws -> [MBAIStatusFacts] {
            await statusGate?.wait()
            return statuses
        }
    }

    // MARK: - The entitlement request

    @Test func theEntitlementRequestCarriesTheAppAsAQueryItemNeverInThePath() throws {
        let request = GoldLifeAPI.entitlementRequest(app: "my_business")
        #expect(request.path == "entitlement")
        #expect(!request.path.contains("?"))
        #expect(request.queryItems == [URLQueryItem(name: "app", value: "my_business")])
        #expect(request.method == "GET")
        #expect(request.authMode == .sessionJwt)
        #expect(request.target == .custom(LocalSecrets.workerURL))

        // The URL the transport assembles from it (baseURL + path, then the query items).
        let pathURL = request.target.defaultBaseURL.appendingPathComponent(request.path)
        var components = try #require(URLComponents(url: pathURL, resolvingAgainstBaseURL: false))
        components.queryItems = request.queryItems
        let url = try #require(components.url)
        #expect(url.path == "/entitlement")
        #expect(url.query == "app=my_business")
        #expect(!url.absoluteString.contains("%3F"))
    }

    @Test func everyOtherRequestHasNoQueryAndNoQuestionMarkInItsPath() throws {
        let plain = GoldLifeAPI.request("me")
        #expect(plain.queryItems.isEmpty && plain.path == "me" && plain.method == "GET")
        let posted = GoldLifeAPI.request("app-link", method: "POST", body: Data("{}".utf8))
        #expect(posted.headers["Content-Type"] == "application/json" && posted.method == "POST")

        // A call site can't reintroduce the regression: no `send("…?…")` in the identity client.
        for file in ["Services/GoldLifeAPI.swift", "Services/GoldLifeAPI+Profile.swift"] {
            let text = try #require(GLSource.file(file))
            let literalsWithQuery = text.components(separatedBy: "send(\"").dropFirst()
                .map { $0.prefix { $0 != "\"" } }
                .filter { $0.contains("?") }
            #expect(literalsWithQuery.isEmpty, "\(file) puts a query string in a path: \(literalsWithQuery)")
        }
    }

    // MARK: - The gate's state (pure)

    @Test func theStateNeverSaysNotEntitledBeforeTheCompAnswerIsKnown() {
        func state(entitled: Bool = false, loaded: Bool = true, issue: MBAIRenewalIssue? = nil,
                   unknown: Bool = false, compKnown: Bool = true) -> GLAISubscriptionState {
            MBAIEntitlement.state(isAIEntitled: entitled, hasLoaded: loaded, renewalIssue: issue,
                                  statusUnknown: unknown, compAnswerKnown: compKnown)
        }
        #expect(state(entitled: true, loaded: false, compKnown: false) == .entitled)
        #expect(state(loaded: false) == .unconfirmed)
        #expect(state(issue: .billingRetry) == .paymentIssue)
        #expect(state(issue: .gracePeriod, compKnown: false) == .paymentIssue)
        #expect(state(unknown: true) == .unconfirmed)
        // StoreKit says no, and the server hasn't: a comped owner may be looking — never Upgrade.
        #expect(state(compKnown: false) == .unconfirmed)
        // Only a real "no" from both is Upgrade.
        #expect(state() == .notEntitled)
    }

    @Test func checkingIsTheNeutralStateOnlyWhileAFirstAnswerIsOut() {
        func checking(entitled: Bool = false, loaded: Bool = true, compKnown: Bool = true,
                      inFlight: Bool = false) -> Bool {
            MBAIEntitlement.isChecking(isAIEntitled: entitled, hasLoaded: loaded,
                                       compAnswerKnown: compKnown, serverCheckInFlight: inFlight)
        }
        #expect(checking(loaded: false), "StoreKit's first read is still out: spinner, not an error")
        #expect(checking(compKnown: false, inFlight: true), "the comp answer is on its way")
        #expect(!checking(compKnown: false, inFlight: false), "the comp answer failed: say so (Try Again)")
        #expect(!checking(entitled: true, loaded: false, compKnown: false, inFlight: true),
                "an open assistant never flips to a spinner")
        #expect(!checking())
    }

    @Test func theCompAnswerIsKnownFromThisSessionOrTheLastOneOnRecord() {
        #expect(MBAIEntitlement.isCompAnswerKnown(serverAnswered: true, hasStoredAnswer: false))
        #expect(MBAIEntitlement.isCompAnswerKnown(serverAnswered: false, hasStoredAnswer: true))
        #expect(!MBAIEntitlement.isCompAnswerKnown(serverAnswered: false, hasStoredAnswer: false))
        #expect(MBAIEntitlement.storedAnswerKey == "mb.entitlement")
    }

    @Test func aMessageSendsTheLastReadsJWSAndNeverWaitsWhenThereIsNothingToShow() {
        let current = txn(jws: "cached")
        #expect(MBAIEntitlement.jwsPlan(cached: current, now: now, isComped: false,
                                        hasCurrentAIPeriod: true, hasLoaded: true) == .send("cached"))
        // Comped: the server finds the comp itself.
        #expect(MBAIEntitlement.jwsPlan(cached: nil, now: now, isComped: true,
                                        hasCurrentAIPeriod: false, hasLoaded: false) == .noProof)
        // Read, and no period: nothing to wait for.
        #expect(MBAIEntitlement.jwsPlan(cached: nil, now: now, isComped: false,
                                        hasCurrentAIPeriod: false, hasLoaded: true) == .noProof)
        // The period the last read saw has run out (a renewal), or nothing was read yet.
        #expect(MBAIEntitlement.jwsPlan(cached: txn(expiresIn: -1), now: now, isComped: false,
                                        hasCurrentAIPeriod: true, hasLoaded: true) == .read)
        #expect(MBAIEntitlement.jwsPlan(cached: nil, now: now, isComped: false,
                                        hasCurrentAIPeriod: false, hasLoaded: false) == .read)
    }

    // MARK: - The bounded wait

    @Test func theDeadlineAnswersInTimeForQuickWork() async {
        var ran = false
        let inTime = await GLDeadline.wait(atMost: .seconds(5)) { ran = true }
        #expect(inTime && ran)
    }

    @Test func theDeadlineStopsWaitingButNeverCancelsTheWork() async throws {
        let gate = Gate()
        var finished = false
        let inTime = await GLDeadline.wait(atMost: .milliseconds(50)) {
            await gate.wait()
            finished = true
        }
        #expect(!inTime && !finished, "the wait ended at its limit, not with the work")
        // The silent background refresh: the work was never cancelled and lands on its own.
        gate.release()
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(20)) }
        #expect(finished)
    }

    // MARK: - The object

    @Test func aSlowStoreKitReadBecomesCouldntConfirmAtItsLimitThenLandsSilently() async throws {
        let store = FakeStoreKit()
        let gate = Gate()
        store.statusGate = gate
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { false }, now: { now })
        #expect(entitlement.isChecking, "nothing read yet: the neutral spinner")

        await entitlement.refresh(limit: .milliseconds(50))
        #expect(entitlement.hasLoaded && entitlement.subscriptionState == .unconfirmed)
        #expect(!entitlement.isChecking)

        // The read was never cancelled: it lands and says what StoreKit really said.
        gate.release()
        for _ in 0..<100 where entitlement.statusUnknown { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!entitlement.statusUnknown && entitlement.subscriptionState == .notEntitled)
    }

    @Test func theLaunchGateAsksBothAnswersAndALateCompAnswerStillLands() async throws {
        let store = FakeStoreKit()
        let serverGate = Gate()
        var compKnown = false
        var comped = false
        var asked = 0
        let entitlement = MBAIEntitlement(
            storeKit: store,
            isComped: { comped },
            compAnswerKnown: { compKnown },
            refreshCompAnswer: {
                asked += 1
                await serverGate.wait()
                compKnown = true
                comped = true
            },
            now: { now })

        var appWideReads = 0
        let allInTime = await MBLaunchEntitlement.resolve(limit: .milliseconds(300), assistant: entitlement,
                                                          assistantEnabled: true, compRead: {},
                                                          appWideRead: { appWideReads += 1 })
        #expect(!allInTime, "the comp answer ran past the launch limit")
        #expect(asked == 1 && appWideReads == 1, "every answer is asked at the gate")
        // StoreKit answers (its fake is immediate; the poll only absorbs a busy main actor); the
        // server hasn't yet: never Upgrade, and the screen waits quietly instead of flashing an error.
        for _ in 0..<100 where !entitlement.hasLoaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(entitlement.hasLoaded)
        #expect(entitlement.subscriptionState == .unconfirmed)
        #expect(entitlement.isChecking && entitlement.serverCheckInFlight)

        // A second asker joins the question in flight instead of asking again.
        let joined = Task { await entitlement.recheck() }

        serverGate.release()
        for _ in 0..<100 where entitlement.serverCheckInFlight { try await Task.sleep(for: .milliseconds(20)) }
        await joined.value
        #expect(asked == 1)
        #expect(!entitlement.serverCheckInFlight && !entitlement.isChecking)
        #expect(entitlement.subscriptionState == .entitled, "the owner's comp opened it, silently")
    }

    /// The assistant is switched off (MBFeatureFlags, owner 2026-10-03): nothing reads its
    /// Pro + AI answer, so the gate must not hold the splash for it (audit F155). The server's
    /// comp word is still asked.
    @Test func withTheAssistantOffTheGateSkipsThePlusAIReadAndKeepsTheCompCheck() async {
        let store = FakeStoreKit()
        let neverAnswers = Gate()
        store.statusGate = neverAnswers
        var assistantCompAsks = 0
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { false },
                                          refreshCompAnswer: { assistantCompAsks += 1 }, now: { now })
        var compReads = 0
        var appWideReads = 0
        let allInTime = await MBLaunchEntitlement.resolve(limit: .seconds(1), assistant: entitlement,
                                                          assistantEnabled: false,
                                                          compRead: { compReads += 1 },
                                                          appWideRead: { appWideReads += 1 })
        #expect(allInTime, "a StoreKit read nothing uses held the splash")
        #expect(store.transactionReads == 0, "the hidden assistant's StoreKit read still ran")
        #expect(compReads + assistantCompAsks == 1, "the comp check is still asked, once")
        #expect(appWideReads == 1)
        neverAnswers.release()
    }

    /// The store mount is synchronous main-actor work; the entitlement reads must already be on
    /// the wire before it starts, or the splash lasts mount time PLUS the read (audit F152).
    @Test func theMountStartsTheEntitlementReadsBeforeItsOwnWork() async {
        var started = false
        let reads = await MBLaunchEntitlement.startDuringMount {
            started = true
            return true
        }
        #expect(started, "the reads had not started when the mount's own work began")
        #expect(await reads.value)
    }

    /// The real launch call, through the mount's starter: every read is already asked when the
    /// mount's synchronous work begins, not after it.
    @Test func theLaunchReadsAreAskedBeforeTheMountContinues() async {
        let store = FakeStoreKit()
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { false }, now: { now })
        let server = Gate()
        var compReads = 0
        var appWideReads = 0
        let reads = await MBLaunchEntitlement.startDuringMount {
            await MBLaunchEntitlement.resolve(limit: .seconds(2), assistant: entitlement,
                                              assistantEnabled: false,
                                              compRead: { compReads += 1; await server.wait() },
                                              appWideRead: { appWideReads += 1 })
        }
        #expect(compReads == 1 && appWideReads == 1, "a read was still queued behind the mount")
        server.release()
        #expect(await reads.value)
    }

    /// The limit counts from when the reads are asked, not from when the mount frees the main
    /// actor: a stalled read holds the splash for the larger of the mount and the limit, never
    /// their sum (audit F152, law 70).
    @Test func theLaunchLimitRunsWhileTheMountWorks() async {
        let entitlement = MBAIEntitlement(storeKit: FakeStoreKit(), isComped: { false }, now: { now })
        let stalled = Gate()
        let started = ContinuousClock.now
        let reads = await MBLaunchEntitlement.startDuringMount {
            await MBLaunchEntitlement.resolve(limit: .seconds(1), assistant: entitlement,
                                              assistantEnabled: false,
                                              compRead: { await stalled.wait() },
                                              appWideRead: {})
        }
        // The mount's synchronous main-actor work.
        let mountEnds = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < mountEnds {}
        let inTime = await reads.value
        let waited = ContinuousClock.now - started
        #expect(!inTime, "the stalled read can't have landed")
        #expect(waited < .milliseconds(1_300), "the splash lasted \(waited): mount time PLUS the limit")
        stalled.release()
    }

    /// Reads that land while the mount works are in time, even when the mount used up the limit.
    @Test func readsThatLandDuringALongMountAreInTime() async {
        let entitlement = MBAIEntitlement(storeKit: FakeStoreKit(), isComped: { false }, now: { now })
        let reads = await MBLaunchEntitlement.startDuringMount {
            await MBLaunchEntitlement.resolve(limit: .milliseconds(100), assistant: entitlement,
                                              assistantEnabled: false,
                                              compRead: {}, appWideRead: {})
        }
        let mountEnds = ContinuousClock.now + .milliseconds(300)
        while ContinuousClock.now < mountEnds {}
        #expect(await reads.value, "reads that already landed were reported late")
    }

    @Test func aMessageNeverWalksStoreKitWhenTheLastReadAnswers() async {
        let store = FakeStoreKit()
        var comped = false
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { comped }, now: { now })

        // Comped, before anything was read: no StoreKit walk at all.
        comped = true
        #expect(await entitlement.currentAIJWS() == nil)
        #expect(store.transactionReads == 0)
        comped = false

        // A subscriber: one read (the launch gate's), then every message reuses it.
        store.transactions = [txn(jws: "from-launch")]
        await entitlement.refresh()
        let reads = store.transactionReads
        #expect(await entitlement.currentAIJWS() == "from-launch")
        #expect(await entitlement.currentAIJWS() == "from-launch")
        #expect(store.transactionReads == reads, "the first question must not wait on StoreKit")
    }

    @Test func resetDropsTheLastSessionsRead() async {
        let store = FakeStoreKit()
        store.transactions = [txn(jws: "previous-account")]
        let entitlement = MBAIEntitlement(storeKit: store, isComped: { false }, now: { now })
        await entitlement.refresh()
        #expect(entitlement.isAIEntitled)

        entitlement.reset()
        #expect(!entitlement.hasLoaded && !entitlement.hasCurrentAIPeriod && !entitlement.isAIEntitled)
        #expect(entitlement.renewalIssue == nil && !entitlement.statusUnknown)
        #expect(entitlement.subscriptionState == .unconfirmed)
    }
}
