//
//  MBAIEntitlement.swift
//  GLSmallBusiness
//
//  Is the ASSISTANT open for this person? A narrower question than "is the app writable"
//  (GLSubscription): only Pro + AI (`mybusiness.ai.monthly|yearly`) or a comped account opens
//  it. Plain Pro never does.
//
//  The rules (contract v2, A9 / A17):
//  - Entitled = a CURRENT Pro + AI period — a verified transaction in
//    `Transaction.currentEntitlements` for an AI product, not revoked, not upgraded away,
//    bought by this person (Family Sharing is off; the server refuses anything but PURCHASED),
//    with `expirationDate > now` — OR comped (the server's comp answer on GLSubscription:
//    source "owner" or "comp"; a paying subscriber's "subscription" source is NOT a comp).
//  - No grace period for the assistant (A9). `currentEntitlements` includes a subscription in
//    its billing grace period, but that transaction's expiry has already passed, so the
//    `expirationDate > now` rule keeps it closed. The renewal state is read separately
//    (`Product.SubscriptionInfo.status(for:)`) so the gate can say "update your payment"
//    instead of "upgrade" for `.inGracePeriod` / `.inBillingRetryPeriod`.
//  - `currentAIJWS()` is the Apple-signed JWS of the current AI transaction, sent as the
//    entitlement header. The server verifies it; this object only decides what the screen
//    shows (the client gate is UX, the server's check is the enforcement). It comes from the
//    LAST READ, never a fresh StoreKit walk per message: the first question must not wait on
//    StoreKit (the 29-second first-question delay). Only a period that ran out since (a
//    renewal) or nothing read yet costs one bounded read.
//  - Comp is the SERVER's answer (GoldLifeAI's GLAIGate contract: fold it in before saying
//    "not entitled"). Until this account's answer is known — this session's reply, or the last
//    one on record — the gate never says Upgrade.
//  - Owner ruling 2026-09-25 (8): both answers are read at the launch gate (MBLaunchEntitlement),
//    before the person lands in the app, with a short limit, the last-known answer as the
//    fallback, and the reads left running to land silently. While a first answer is still out
//    the screen shows its neutral spinner (`isChecking`), never the "Couldn't confirm" error.
//
//  The decision is pure functions (`decide`, `state`, `isChecking`, `jwsPlan`) over value
//  snapshots, so it is tested without StoreKit. The live reads sit behind `MBAIStoreKitReading`.
//

import GoldLifeCloud
import Foundation
import GoldLifeAI
import GoldLifeUI
import Observation
import StoreKit

/// Why a Pro + AI subscriber can't use the assistant right now (A9).
nonisolated enum MBAIRenewalIssue: Equatable, Sendable {
    /// `.inGracePeriod` — Apple is still retrying the renewal and Pro stays open.
    case gracePeriod
    /// `.inBillingRetryPeriod` — the renewal failed and Apple is retrying.
    case billingRetry
}

/// One AI transaction from `Transaction.currentEntitlements`, as the decision needs it.
nonisolated struct MBAITransactionFacts: Equatable, Sendable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded: Bool
    /// `ownershipType == .purchased` (not Family Sharing).
    var isPurchasedByThisPerson: Bool
    /// `VerificationResult.jwsRepresentation` — what the server verifies.
    var jws: String
}

/// One entry of `Product.SubscriptionInfo.status(for: groupID)`: its renewal state and the
/// product of its latest verified transaction.
nonisolated struct MBAIStatusFacts: Equatable, Sendable {
    var productID: String
    var state: Product.SubscriptionInfo.RenewalState
}

/// The live StoreKit reads, behind a seam so the decision is testable without StoreKit.
protocol MBAIStoreKitReading {
    /// Verified AI-product transactions from `Transaction.currentEntitlements`.
    func aiTransactions() async -> [MBAITransactionFacts]
    /// The group's renewal statuses for AI products. Throws when StoreKit can't answer.
    func aiStatuses() async throws -> [MBAIStatusFacts]
}

struct MBAILiveStoreKit: MBAIStoreKitReading {
    let groupID: String
    let aiProductIDs: Set<String>

    func aiTransactions() async -> [MBAITransactionFacts] {
        var facts: [MBAITransactionFacts] = []
        for await result in Transaction.currentEntitlements {
            // Only a transaction StoreKit verified; an unverified one is never trusted.
            guard case .verified(let txn) = result, aiProductIDs.contains(txn.productID) else { continue }
            facts.append(MBAITransactionFacts(
                productID: txn.productID,
                expirationDate: txn.expirationDate,
                revocationDate: txn.revocationDate,
                isUpgraded: txn.isUpgraded,
                isPurchasedByThisPerson: txn.ownershipType == .purchased,
                jws: result.jwsRepresentation
            ))
        }
        return facts
    }

    func aiStatuses() async throws -> [MBAIStatusFacts] {
        let statuses = try await Product.SubscriptionInfo.status(for: groupID)
        return statuses.compactMap { status in
            guard case .verified(let txn) = status.transaction, aiProductIDs.contains(txn.productID) else { return nil }
            return MBAIStatusFacts(productID: txn.productID, state: status.state)
        }
    }
}

@MainActor
@Observable
final class MBAIEntitlement {
    static let shared = MBAIEntitlement(
        storeKit: MBAILiveStoreKit(groupID: SubscriptionManager.groupID,
                                   aiProductIDs: SubscriptionManager.aiProductIDs),
        isComped: { MBAIEntitlement.isComped(SubscriptionManager.shared) },
        compAnswerKnown: { MBAIEntitlement.compAnswerKnown(SubscriptionManager.shared) },
        refreshCompAnswer: { await SubscriptionManager.shared.checkVipStatus() }
    )

    /// How long one StoreKit read may hold the screen before it counts as "couldn't confirm".
    /// The read itself is never cancelled: when it lands later, it still applies.
    nonisolated static let storeKitReadLimit: Duration = .seconds(8)
    /// A message is never held longer than this for a StoreKit read (see `currentAIJWS()`).
    nonisolated static let jwsReadLimit: Duration = .seconds(3)

    /// What one refresh concluded. `isComped` is NOT part of it: comp is read live, so a comp
    /// answer that lands after the refresh opens the assistant at once.
    nonisolated struct Decision: Equatable, Sendable {
        /// The current AI transaction (latest expiry), or nil.
        var current: MBAITransactionFacts?
        /// A renewal problem on the AI product, when there is no current period.
        var renewalIssue: MBAIRenewalIssue?
        /// StoreKit couldn't confirm either way: the status read failed, or it reports a live
        /// Pro + AI renewal that `currentEntitlements` doesn't list yet (a fresh install before
        /// StoreKit syncs).
        var statusUnknown: Bool
    }

    /// What `currentAIJWS()` does for a message (pure, see `jwsPlan`).
    nonisolated enum JWSPlan: Equatable, Sendable {
        /// Send this JWS from the last read.
        case send(String)
        /// Send no proof: comped (the server finds the comp itself) or nothing Apple-signed to show.
        case noProof
        /// One bounded fresh read first.
        case read
    }

    /// A current Pro + AI period, from the last refresh.
    private(set) var hasCurrentAIPeriod = false
    /// The AI product's renewal problem, from the last refresh (see `aiRenewalIssue`).
    private(set) var renewalIssue: MBAIRenewalIssue?
    /// StoreKit couldn't confirm either way on the last refresh (see `Decision.statusUnknown`).
    private(set) var statusUnknown = false
    /// False until the first refresh finishes.
    private(set) var hasLoaded = false
    /// The server's comp answer is being asked for right now.
    private(set) var serverCheckInFlight = false
    /// The transaction behind `hasCurrentAIPeriod` — its JWS is what a message carries. Memory
    /// only; dropped by `reset()` when the session ends.
    @ObservationIgnored private var currentTransaction: MBAITransactionFacts?
    /// Bumped per refresh, so a slow read that finishes after a newer one can't land over it.
    @ObservationIgnored private var refreshGeneration = 0
    /// The comp question in flight, so a second asker joins it instead of asking twice.
    @ObservationIgnored private var compTask: Task<Void, Never>?
    @ObservationIgnored private let storeKit: any MBAIStoreKitReading
    @ObservationIgnored private let isCompedNow: () -> Bool
    @ObservationIgnored private let compAnswerKnownNow: () -> Bool
    @ObservationIgnored private let refreshCompAnswer: () async -> Void
    @ObservationIgnored private let now: () -> Date

    init(storeKit: any MBAIStoreKitReading,
         isComped: @escaping () -> Bool,
         compAnswerKnown: @escaping () -> Bool = { true },
         refreshCompAnswer: @escaping () async -> Void = {},
         now: @escaping () -> Date = { .now }) {
        self.storeKit = storeKit
        self.isCompedNow = isComped
        self.compAnswerKnownNow = compAnswerKnown
        self.refreshCompAnswer = refreshCompAnswer
        self.now = now
    }

    // MARK: The answers

    /// The assistant is open: a current Pro + AI period, or comped.
    var isAIEntitled: Bool { hasCurrentAIPeriod || isCompedNow() }

    /// Grace / billing retry on the Pro + AI product (A9). Nil whenever the assistant is open.
    var aiRenewalIssue: MBAIRenewalIssue? {
        guard !isAIEntitled else { return nil }
        return renewalIssue
    }

    /// The gate's input (GoldLifeAI `GLAIGate`). "Couldn't confirm" when StoreKit or the server
    /// couldn't confirm either way and nothing else opened the assistant — never Upgrade for
    /// someone who may be paying or comped (A17).
    var subscriptionState: GLAISubscriptionState {
        Self.state(isAIEntitled: isAIEntitled, hasLoaded: hasLoaded, renewalIssue: renewalIssue,
                   statusUnknown: statusUnknown, compAnswerKnown: compAnswerKnownNow())
    }

    /// A first answer is still being read: the screen shows its neutral spinner, never the
    /// "Couldn't confirm" error (the cold-open flash).
    var isChecking: Bool {
        Self.isChecking(isAIEntitled: isAIEntitled, hasLoaded: hasLoaded,
                        compAnswerKnown: compAnswerKnownNow(), serverCheckInFlight: serverCheckInFlight)
    }

    /// The Apple-signed JWS of the current Pro + AI transaction, or nil — from the last read
    /// (see the header). A comped account has none: the server finds the comp itself.
    func currentAIJWS() async -> String? {
        switch Self.jwsPlan(cached: currentTransaction, now: now(), isComped: isCompedNow(),
                            hasCurrentAIPeriod: hasCurrentAIPeriod, hasLoaded: hasLoaded) {
        case .send(let jws):
            return jws
        case .noProof:
            return nil
        case .read:
            await refresh(limit: Self.jwsReadLimit)
            guard case .send(let jws) = Self.jwsPlan(cached: currentTransaction, now: now(), isComped: false,
                                                     hasCurrentAIPeriod: false, hasLoaded: true) else { return nil }
            return jws
        }
    }

    // MARK: Reading

    /// Re-reads StoreKit. Call on appear, after a purchase or restore, and when the
    /// subscription status changes. Waits at most `limit`; a read still out then keeps going
    /// and applies when it lands, unless a newer refresh started since.
    func refresh(limit: Duration = MBAIEntitlement.storeKitReadLimit) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let landed = await GLDeadline.wait(atMost: limit) { [weak self] in
            guard let self else { return }
            let decision = await self.read()
            guard generation == self.refreshGeneration else { return }
            self.apply(decision)
        }
        // Still out, and nothing answered before: what is true right now is "not confirmed".
        // An earlier answer, when there is one, stands until this read lands.
        if !landed, generation == refreshGeneration, !hasLoaded {
            apply(Decision(current: nil, renewalIssue: nil, statusUnknown: true))
        }
    }

    /// Re-reads BOTH answers the gate turns on — StoreKit's and the server's comp word — at once.
    /// The launch gate, the screen's first appearance and Try Again use it; it never opens a
    /// paywall.
    func recheck() async {
        let comp = compCheck()
        await refresh()
        await comp.value
    }

    /// The assistant screen appearing: StoreKit is re-read (local and quick), and the server is
    /// asked again only when this account's comp answer never arrived.
    func refreshOnAppear() async {
        if compAnswerKnownNow() {
            await refresh()
        } else {
            await recheck()
        }
    }

    /// Session end (sign-out, expiry, account deletion, an account switch): what StoreKit said
    /// for the last session is dropped, and the next session reads its own.
    func reset() {
        refreshGeneration += 1
        currentTransaction = nil
        hasCurrentAIPeriod = false
        renewalIssue = nil
        statusUnknown = false
        hasLoaded = false
    }

    /// One StoreKit read. A current period needs no renewal status (`decide` ignores it), so the
    /// network status read is skipped for a subscriber.
    private func read() async -> Decision {
        let transactions = await storeKit.aiTransactions()
        if Self.currentTransaction(in: transactions, now: now()) != nil {
            return Self.decide(transactions: transactions, statuses: [], now: now())
        }
        let statuses: [MBAIStatusFacts]?
        do {
            statuses = try await storeKit.aiStatuses()
        } catch {
            statuses = nil
        }
        return Self.decide(transactions: transactions, statuses: statuses, now: now())
    }

    /// The server's comp question, single-flighted.
    private func compCheck() -> Task<Void, Never> {
        if let running = compTask { return running }
        serverCheckInFlight = true
        let ask = refreshCompAnswer
        let task = Task { @MainActor [weak self] in
            await ask()
            self?.compTask = nil
            self?.serverCheckInFlight = false
        }
        compTask = task
        return task
    }

    private func apply(_ decision: Decision) {
        currentTransaction = decision.current
        hasCurrentAIPeriod = decision.current != nil
        renewalIssue = decision.renewalIssue
        statusUnknown = decision.statusUnknown
        hasLoaded = true
    }

    // MARK: The rules (pure)

    /// The gate's state from what is known.
    nonisolated static func state(isAIEntitled: Bool, hasLoaded: Bool, renewalIssue: MBAIRenewalIssue?,
                                  statusUnknown: Bool, compAnswerKnown: Bool) -> GLAISubscriptionState {
        if isAIEntitled { return .entitled }
        // Before the first read lands nothing has been READ yet — not "no subscription".
        if !hasLoaded { return .unconfirmed }
        if renewalIssue != nil { return .paymentIssue }
        if statusUnknown { return .unconfirmed }
        // StoreKit says no; only the server can say "comped". Without this account's answer a
        // comped owner would be told to buy (GLAIGate: fold in the comp answer first).
        if !compAnswerKnown { return .unconfirmed }
        return .notEntitled
    }

    /// True while a first answer is still being read: StoreKit's first read hasn't landed, or
    /// the server's comp answer is out with none on record. Never while the assistant is open.
    nonisolated static func isChecking(isAIEntitled: Bool, hasLoaded: Bool, compAnswerKnown: Bool,
                                       serverCheckInFlight: Bool) -> Bool {
        guard !isAIEntitled else { return false }
        if !hasLoaded { return true }
        return !compAnswerKnown && serverCheckInFlight
    }

    /// What a message sends as its Pro + AI proof, without walking StoreKit when the last read
    /// already answers.
    nonisolated static func jwsPlan(cached: MBAITransactionFacts?, now: Date, isComped: Bool,
                                    hasCurrentAIPeriod: Bool, hasLoaded: Bool) -> JWSPlan {
        if let cached, !cached.jws.isEmpty, let expires = cached.expirationDate, expires > now {
            return .send(cached.jws)
        }
        // The server finds a comp itself; no Apple-signed proof is needed.
        if isComped { return .noProof }
        // The last read found no current period: nothing to show, and nothing to wait for — the
        // server answers "subscription required" honestly.
        if hasLoaded, !hasCurrentAIPeriod { return .noProof }
        // The period the last read saw has run out (a renewal), or nothing was read yet.
        return .read
    }

    /// - Parameter statuses: nil when StoreKit couldn't report the renewal state.
    nonisolated static func decide(transactions: [MBAITransactionFacts],
                                   statuses: [MBAIStatusFacts]?,
                                   now: Date) -> Decision {
        let current = currentTransaction(in: transactions, now: now)
        guard current == nil else {
            return Decision(current: current, renewalIssue: nil, statusUnknown: false)
        }
        guard let statuses else {
            return Decision(current: nil, renewalIssue: nil, statusUnknown: true)
        }
        // Billing retry outranks grace: it is the later, more serious state.
        let states = statuses.map(\.state)
        if states.contains(.inBillingRetryPeriod) {
            return Decision(current: nil, renewalIssue: .billingRetry, statusUnknown: false)
        }
        if states.contains(.inGracePeriod) {
            return Decision(current: nil, renewalIssue: .gracePeriod, statusUnknown: false)
        }
        // Subscribed per the status, yet no current transaction to show the server: never
        // "Upgrade" for someone who is paying (A17) — the gate says it couldn't confirm.
        return Decision(current: nil, renewalIssue: nil, statusUnknown: states.contains(.subscribed))
    }

    /// The transaction that makes a period current: an AI product, not revoked, not upgraded
    /// away, this person's own purchase, expiring after `now`. Latest expiry wins (a monthly ↔
    /// yearly switch can leave both listed until the old one ends).
    nonisolated static func currentTransaction(in transactions: [MBAITransactionFacts], now: Date) -> MBAITransactionFacts? {
        transactions
            .filter { txn in
                guard SubscriptionManager.aiProductIDs.contains(txn.productID),
                      txn.revocationDate == nil,
                      !txn.isUpgraded,
                      txn.isPurchasedByThisPerson,
                      !txn.jws.isEmpty,
                      let expires = txn.expirationDate else { return false }
                return expires > now
            }
            .max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }
    }

    /// Comped for My Business = the server's comp answer. GET /entitlement?app=my_business
    /// also answers `entitled: true` for a paying subscriber (source "subscription"), which is
    /// NOT a comp — Pro alone must never open the assistant.
    static func isComped(_ subscription: SubscriptionManager) -> Bool {
        isCompSource(entitled: subscription.serverEntitled, source: subscription.serverSource)
    }

    nonisolated static func isCompSource(entitled: Bool, source: String) -> Bool {
        entitled && (source == "owner" || source == "comp")
    }

    /// Where GLSubscription keeps the last server answer for this app ("mb.entitlement"). It is
    /// written only by a successful answer and removed by `clearServerEntitlement()`, so its
    /// presence means "this account's comp answer is on record".
    static var storedAnswerKey: String { GLSubscriptionMigrator.appPrefix(for: "my_business") + "entitlement" }

    /// This account's comp answer is known: the server answered this session, or its last answer
    /// is on record (the last-known fallback, owner ruling 2026-09-25 (8)).
    static func compAnswerKnown(_ subscription: SubscriptionManager) -> Bool {
        isCompAnswerKnown(serverAnswered: subscription.serverAnswered,
                          hasStoredAnswer: UserDefaults.standard.data(forKey: storedAnswerKey) != nil)
    }

    nonisolated static func isCompAnswerKnown(serverAnswered: Bool, hasStoredAnswer: Bool) -> Bool {
        serverAnswered || hasStoredAnswer
    }
}
