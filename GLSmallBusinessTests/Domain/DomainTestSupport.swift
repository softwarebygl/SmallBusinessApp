//
//  DomainTestSupport.swift
//  GLSmallBusinessTests — Domain
//
//  Pins the three process-wide states every domain gate reads — the subscription, connectivity and
//  sample mode — for the length of one test body, and always restores them. They are singletons in
//  the host app's process, so a test that inherits them proves nothing (the lesson in
//  ReadOnlyGateTests: pin it, never inherit it).
//

import Foundation
import GoldLifeUI
import SwiftData
@testable import GLSmallBusiness

@MainActor
enum DomainState {
    case subscribed, neverSubscribed, lapsed, offline, sampleOffline

    /// Runs `body` with this state pinned, then puts every flag back.
    func run<R>(_ body: () throws -> R) rethrows -> R {
        let restore = pin()
        defer { restore() }
        return try body()
    }

    /// The same, for a body that awaits (the pay-link mint) — the flags stay pinned across it.
    func runAsync<R>(_ body: () async throws -> R) async rethrows -> R {
        let restore = pin()
        defer { restore() }
        return try await body()
    }

    /// Pins the flags and hands back the closure that restores them.
    private func pin() -> () -> Void {
        let subs = SubscriptionManager.shared
        let network = NetworkMonitor.shared
        let wasConnected = network.isConnected
        let wasDemo = UserDemoMode.shared.isDemoActive
        UserDemoMode.shared.isDemoActive = false
        network.isConnected = true
        subs.statusKnown = true; subs.historyKnown = true
        switch self {
        case .subscribed, .offline, .sampleOffline:
            subs.isSubscribed = true; subs.hasEverSubscribed = true
        case .neverSubscribed:
            subs.isSubscribed = false; subs.hasEverSubscribed = false
        case .lapsed:
            subs.isSubscribed = false; subs.hasEverSubscribed = true
        }
        if self == .offline || self == .sampleOffline { network.isConnected = false }
        if self == .sampleOffline { UserDemoMode.shared.isDemoActive = true }
        return {
            subs.statusKnown = false; subs.historyKnown = false
            subs.isSubscribed = false; subs.hasEverSubscribed = false
            network.isConnected = wasConnected
            UserDemoMode.shared.isDemoActive = wasDemo
        }
    }
}

/// The thrown `DomainError`, or nil when `body` did not throw one.
@MainActor
func domainError(_ body: () throws -> Void) -> DomainError? {
    do { try body(); return nil } catch { return error as? DomainError }
}

@MainActor
enum DomainFixtures {
    /// A fresh in-memory store and its main context (autosave off — every save is explicit).
    static func context() throws -> ModelContext {
        try TestStore.makeContainer().mainContext
    }
}
