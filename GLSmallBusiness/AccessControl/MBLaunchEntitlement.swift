//
//  MBLaunchEntitlement.swift
//  GLSmallBusiness
//
//  Owner ruling 2026-09-25 (8): what this account is entitled to is KNOWN during the launch
//  gate, before the person lands in the app — never discovered afterwards as a surprise paywall
//  or a "Couldn't confirm Pro + AI" flash on the Assistant tab.
//
//  The launch gate (GatePhase's SignedInHost, under the splash wordmark) asks all three answers
//  at once — the server's comp word (GET /entitlement), StoreKit's Pro + AI read
//  (MBAIEntitlement) and StoreKit's app-wide read (GLSubscription) — and waits for them at most
//  `limit` (about 3 seconds), counted from when they are asked. Whatever hasn't answered by then falls back to the last-known
//  answer (GLSubscription seeds the last server answer at launch; StoreKit's own cache is local),
//  and the reads are NOT cancelled: they keep going and land silently in the background.
//

import Foundation
import GoldLifeCloud
import GoldLifeUI

@MainActor
enum MBLaunchEntitlement {
    /// The longest the launch gate holds the splash for the entitlement.
    nonisolated static let limit: Duration = .seconds(3)

    /// The launch gate's call: the app's own answers, within `limit`.
    @discardableResult
    static func resolve() async -> Bool {
        await resolve(limit: limit, assistant: .shared,
                      assistantEnabled: MBFeatureFlags.assistantEnabled,
                      compRead: { await SubscriptionManager.shared.checkVipStatus() },
                      appWideRead: { await SubscriptionManager.shared.refreshCachedEntitlement() })
    }

    /// Asks every entitlement answer — the assistant's two (StoreKit's Pro + AI read and the
    /// server's comp word) and the app-wide StoreKit read — and waits at most `limit`. True when
    /// all of them landed in time. Never cancels a read (see the header).
    ///
    /// With the assistant switched off (`MBFeatureFlags.assistantEnabled`, owner 2026-10-03)
    /// nothing reads its Pro + AI answer, so that StoreKit read is skipped and only the server's
    /// comp word is asked (`compRead`) beside the app-wide read (audit 2026-10-03 F155).
    @discardableResult
    static func resolve(limit: Duration, assistant: MBAIEntitlement,
                        assistantEnabled: Bool,
                        compRead: @escaping @MainActor () async -> Void,
                        appWideRead: @escaping @MainActor () async -> Void) async -> Bool {
        // The limit counts from HERE, when the reads are asked — not from whenever the main
        // actor is next free (audit 2026-10-03 F152, law 70).
        let askedAt = ContinuousClock.now
        let landed = Landed()
        // `Task.immediate`: each read is asked right here, before this function first suspends,
        // not whenever the main actor next gets to a queued task (see `startDuringMount`).
        let serverRead = Task.immediate { @MainActor in
            if assistantEnabled { await assistant.recheck() } else { await compRead() }
            landed.server = true
        }
        let appRead = Task.immediate { @MainActor in
            await appWideRead()
            landed.appWide = true
        }
        // Lets the caller's synchronous work (the store mount) finish: this resumes only once
        // the main actor is free. Only the part of the limit that work did not use is left.
        await Task.yield()
        // Reads that landed during the mount are in time, even when the mount used the limit up.
        if landed.all { return true }
        let left = max(.zero, limit - (ContinuousClock.now - askedAt))
        return await GLDeadline.wait(atMost: left) {
            await serverRead.value
            await appRead.value
        }
    }

    /// Which reads have answered — so a mount that used the whole limit can't call reads late
    /// that landed while it ran.
    @MainActor
    private final class Landed {
        var server = false
        var appWide = false
        var all: Bool { server && appWide }
    }

    /// Starts `resolve` for the store mount and hands back its task. The mount's own work is
    /// synchronous main-actor work, so a plain `Task` created there could not start until the
    /// mount's first suspension — after all of it, which made the splash last the mount PLUS
    /// the reads (audit 2026-10-03 F152). `Task.immediate` asks the reads before this returns,
    /// and `resolve`'s limit counts from that moment: the splash lasts the longer of the mount
    /// and the limit, never their sum. A read that needs the main actor still waits for the
    /// mount to free it.
    static func startDuringMount(_ resolve: @escaping @MainActor () async -> Bool)
        async -> Task<Bool, Never> {
        Task.immediate { @MainActor in await resolve() }
    }
}

