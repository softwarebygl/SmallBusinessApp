//
//  StripeTokenScopeTests.swift
//  GLSmallBusinessTests
//
//  Audit 2026-10-03 F2 (blocker): the Stripe install token used to be ONE Keychain item per device
//  (and per iCloud Keychain), never cleared. A second Gold Life ID on the same iPhone minted pay
//  links with the first business's token, so customers paid the wrong business. Now the token
//  belongs to one Gold Life ID, remembers the Stripe account the backend bound it to, never mints
//  for a profile that names a different account, and leaves with the session. The pre-3.3.0 token
//  moves to the signed-in account only when the server proves it is that account's.
//
//  F125: the connect screen's status poll is owned by the screen and stops writing once the
//  session it started under is gone; the auth sheet's anchor never indexes an empty scene list.
//
//  Every test uses its own Keychain service, so nothing here races the rest of the suite.
//

import Foundation
import SwiftData
import Testing
import GoldLifeCloud
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct StripeTokenScopeTests {

    private static func freshService() -> String {
        "GLStripeInstallToken.scope-tests.\(UUID().uuidString)"
    }

    private static func clear(_ service: String, scopes: [String]) {
        for scope in scopes { StripeInstallTokenStore.delete(for: scope, service: service) }
        StripeInstallTokenStore.deleteLegacy(service: service)
    }

    private static func world(profileAccount: String) throws -> (ModelContext, BusinessProfile, Invoice) {
        let context = try DomainFixtures.context()
        let profile = BusinessProfile()
        profile.businessName = "Second Business"
        profile.stripeConnectedAccountId = profileAccount
        profile.stripeChargesEnabled = true
        context.insert(profile)
        let invoice = TS.invoice(number: "INV-0042", status: .sent, lines: [(500, false)], in: context)
        invoice.customer = TS.customer(in: context)
        invoice.includePayLink = true
        context.saveChanges()
        return (context, profile, invoice)
    }

    /// A legacy check that must never run (the decision is made before any network call).
    private static let neverChecked: @Sendable (String, String) async -> StripeInstallTokenStore.LegacyCheck = { _, _ in
        Issue.record("the legacy token was sent to the server when the rules had already decided")
        return .transient
    }

    // MARK: - One Gold Life ID, one token

    @Test func anotherGoldLifeIDNeverReadsTheToken() {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a", "person-b"]) }
        let entry = StripeInstallTokenStore.Entry(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_A")
        #expect(StripeInstallTokenStore.save(entry, for: "owner-a", service: service))
        #expect(StripeInstallTokenStore.load(for: "owner-a", service: service) == entry)
        #expect(StripeInstallTokenStore.load(for: "person-b", service: service) == nil,
                "person B on the same iPhone reads nothing of A's")
        #expect(StripeInstallTokenStore.load(for: nil, service: service) == nil, "signed out reads nothing")
        #expect(!StripeInstallTokenStore.save(entry, for: nil, service: service), "signed out writes nothing")
    }

    /// THE blocker. Owner A connected Stripe on this iPhone; person B signs in, connects their own
    /// account (profile names acct_B), and sends an invoice. At HEAD the device's one token was
    /// "linked", so the plan said mint and the link was minted on A's Stripe account.
    @Test func accountATokenWithAccountBProfileMintsNoPayLink() async throws {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a", "person-b"]) }
        let tokenA = StripeInstallTokenStore.Entry(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_A")
        #expect(StripeInstallTokenStore.save(tokenA, for: "owner-a", service: service))
        let (context, profileB, invoice) = try Self.world(profileAccount: "acct_B")
        let stripe = FakeStripe()

        // B signed in: A's token is not B's.
        let asB = PayLinkEnvironment.device(scope: "person-b", service: service, isConfigured: true,
                                            backend: stripe, isCurrent: { _ in true }, legacyCheck: Self.neverChecked)
        #expect(!asB.deviceLinked)
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profileB, environment: asB) == .decided(.deviceUnlinked))

        // Even under one Gold Life ID, a token bound to acct_A never mints for a profile naming acct_B.
        let mixed = PayLinkEnvironment.device(scope: "owner-a", service: service, isConfigured: true,
                                              backend: stripe, isCurrent: { _ in true }, legacyCheck: Self.neverChecked)
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profileB, environment: mixed) == .decided(.deviceUnlinked))
        let outcome = try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_B", in: context, environment: mixed)
        #expect(outcome == .deviceUnlinked)
        #expect(stripe.mints.isEmpty, "nothing minted on acct_A for acct_B's invoice")
        #expect(stripe.statusCalls == 0, "not even a status call under the wrong account")
        #expect(invoice.stripePaymentLinkURL.isEmpty)

        // The matching account still mints, stamped with its own id.
        let profileA = BusinessProfile()
        profileA.stripeConnectedAccountId = "acct_A"
        profileA.stripeChargesEnabled = true
        context.insert(profileA)
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profileA, environment: mixed) == .mint(accountId: "acct_A"))
        #expect(try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_A", in: context, environment: mixed) == .ready)
        #expect(stripe.mints.count == 1)
        #expect(invoice.stripePaymentLinkAccountId == "acct_A")
    }

    /// A token with no bound account recorded (unknown) never mints either.
    @Test func aTokenWithNoRecordedAccountDoesNotMint() throws {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        #expect(StripeInstallTokenStore.save(.init(token: StripeInstallTokenStore.generate(), boundAccountId: ""),
                                             for: "owner-a", service: service))
        let (_, profile, invoice) = try Self.world(profileAccount: "acct_A")
        let env = PayLinkEnvironment.device(scope: "owner-a", service: service, isConfigured: true,
                                           backend: FakeStripe(), isCurrent: { _ in true }, legacyCheck: Self.neverChecked)
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: env) == .decided(.deviceUnlinked))
    }

    // MARK: - The token leaves with the session

    @Test func signOutRemovesTheAccountsToken() throws {
        let saved = UserDefaults.standard.object(forKey: UserScopedStore.pendingDefaultStoreWipeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserScopedStore.pendingDefaultStoreWipeKey) }
        }
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a", "person-c"]) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StripeTokenScopeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenA = StripeInstallTokenStore.Entry(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_A")
        let tokenC = StripeInstallTokenStore.Entry(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_C")
        #expect(StripeInstallTokenStore.save(tokenA, for: "owner-a", service: service))
        #expect(StripeInstallTokenStore.save(tokenC, for: "person-c", service: service))
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        let defaults = try #require(UserDefaults(suiteName: "StripeTokenScopeTests.\(UUID().uuidString)"))
        let consent = GLAIConsent(key: "mb.ai.consent.version", requiredVersion: 3, defaults: defaults)

        MBSessionPurge.run(.sessionEnded, store: .shared, consent: consent, appSupport: root,
                           temporary: root.appendingPathComponent("tmp"),
                           stripeTokenScope: "owner-a", stripeTokenService: service)

        #expect(StripeInstallTokenStore.load(for: "owner-a", service: service) == nil, "A's token left with A")
        #expect(StripeInstallTokenStore.readLegacy(service: service).isEmpty, "the pre-3.3.0 token left too")
        #expect(StripeInstallTokenStore.load(for: "person-c", service: service) == tokenC,
                "another Gold Life ID's token is not this session's to delete")
    }

    @Test func theRegisteredStepPassesTheSigningOutAccount() throws {
        let purge = try #require(GLSource.file("Services/MBSessionPurge.swift"))
        let stepStart = try #require(purge.range(of: "static func registerWipe(_ wipe"))
        let register = try #require(GLSource.functionBody("registerWipe", in: String(purge[stepStart.lowerBound...])))
        let capture = try #require(register.range(of: "let signingOut = SecureTINStore.accountScope"))
        let drop = try #require(register.range(of: "SecureTINStore.setAccountScope(nil)"))
        #expect(capture.lowerBound < drop.lowerBound, "the account is read BEFORE the scope is dropped")
        #expect(register.contains("stripeTokenScope: signingOut"))
    }

    // MARK: - The pre-3.3.0 token (upgrade path)

    @Test func legacyTokenMovesOnlyWhenTheServerProvesItIsThisAccounts() async {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        let legacy = StripeInstallTokenStore.generate()
        #expect(StripeInstallTokenStore.writeLegacy(legacy, service: service))
        let result = await StripeInstallTokenStore.migrateLegacy(
            scope: "owner-a", profileAccountId: "acct_A", service: service, isCurrent: { _ in true },
            verify: { token, expected in
                #expect(token == legacy)
                #expect(expected == "acct_A")
                return .matches
            })
        #expect(result == .moved)
        #expect(StripeInstallTokenStore.load(for: "owner-a", service: service)
                == .init(token: legacy, boundAccountId: "acct_A"))
        #expect(StripeInstallTokenStore.readLegacy(service: service).isEmpty)
    }

    @Test func legacyTokenIsDeletedWhenTheServerProvesItIsSomeoneElses() async {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["person-b"]) }
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        let result = await StripeInstallTokenStore.migrateLegacy(
            scope: "person-b", profileAccountId: "acct_B", service: service, isCurrent: { _ in true },
            verify: { _, _ in .mismatch })
        #expect(result == .discarded)
        #expect(StripeInstallTokenStore.load(for: "person-b", service: service) == nil, "B never inherits A's token")
        #expect(StripeInstallTokenStore.readLegacy(service: service).isEmpty)
    }

    /// No answer, or an answer without proof (today's server, before C2 deploys), proves nothing
    /// either way: the token waits, unused, for a server that can prove it. Deleting it on an
    /// unproven answer cost every existing Stripe user their card payments with no way back (the
    /// old server's reconnect needs a secret the app no longer sends), and the item is synced, so
    /// the delete reached their other devices too.
    @Test(arguments: [StripeInstallTokenStore.LegacyCheck.transient, .unverifiable])
    func legacyTokenWaitsWhenTheServerCannotProveEitherWay(_ answer: StripeInstallTokenStore.LegacyCheck) async {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        let legacy = StripeInstallTokenStore.generate()
        #expect(StripeInstallTokenStore.writeLegacy(legacy, service: service))
        let result = await StripeInstallTokenStore.migrateLegacy(
            scope: "owner-a", profileAccountId: "acct_A", service: service, isCurrent: { _ in true },
            verify: { _, _ in answer })
        #expect(result == .deferred)
        #expect(StripeInstallTokenStore.load(for: "owner-a", service: service) == nil, "never moved without proof")
        #expect(StripeInstallTokenStore.readLegacy(service: service) == legacy, "kept for the next try")
    }

    /// The landing step runs before the first sync pull: no business profile yet, or the empty one
    /// a screen inserts, is NOT a synced profile that names no account. Deleting there removed the
    /// owner's token (from every device sharing the iCloud Keychain) on any fresh sign-in.
    @Test func theLandingStepLeavesTheLegacyTokenWhileNoProfileNamesAnAccount() async throws {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        let legacy = StripeInstallTokenStore.generate()
        #expect(StripeInstallTokenStore.writeLegacy(legacy, service: service))
        let migrate: (String) async -> Void = { accountId in
            _ = await StripeInstallTokenStore.migrateLegacy(scope: "owner-a", profileAccountId: accountId,
                                                            service: service, isCurrent: { _ in true },
                                                            verify: Self.neverChecked)
        }

        // Fresh sign-in: the store mounted, nothing pulled yet.
        let context = try DomainFixtures.context()
        #expect(await GoldLifeAuth.settleLegacyStripeTokenOnLanding(context: context, migrate: migrate) == false)
        #expect(StripeInstallTokenStore.readLegacy(service: service) == legacy, "no profile yet: the token stays")

        // A placeholder profile (inserted by a screen before the pull) names no account yet.
        context.insert(BusinessProfile())
        context.saveChanges()
        #expect(await GoldLifeAuth.settleLegacyStripeTokenOnLanding(context: context, migrate: migrate) == false)
        #expect(StripeInstallTokenStore.readLegacy(service: service) == legacy, "an unnamed account: the token stays")
    }

    @Test func theLandingStepProvesTheTokenOnceAProfileNamesAnAccount() async throws {
        let (context, _, _) = try Self.world(profileAccount: "acct_A")
        context.insert(BusinessProfile())   // a stray placeholder never hides the synced account
        context.saveChanges()
        let asked = AccountLog()
        #expect(await GoldLifeAuth.settleLegacyStripeTokenOnLanding(context: context) { await asked.append($0) })
        #expect(await asked.ids == ["acct_A"])
    }

    @Test func legacyTokenIsDeletedWithoutAskingWhenNothingCanMatch() async {
        // No account on the profile: nothing to prove it against.
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["person-b"]) }
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        #expect(await StripeInstallTokenStore.migrateLegacy(scope: "person-b", profileAccountId: "", service: service,
                                                           isCurrent: { _ in true }, verify: Self.neverChecked) == .discarded)
        #expect(StripeInstallTokenStore.readLegacy(service: service).isEmpty)

        // The account already has its own token: the old one is not needed.
        let own = StripeInstallTokenStore.Entry(token: StripeInstallTokenStore.generate(), boundAccountId: "acct_B")
        #expect(StripeInstallTokenStore.save(own, for: "person-b", service: service))
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        #expect(await StripeInstallTokenStore.migrateLegacy(scope: "person-b", profileAccountId: "acct_B", service: service,
                                                           isCurrent: { _ in true }, verify: Self.neverChecked) == .discarded)
        #expect(StripeInstallTokenStore.load(for: "person-b", service: service) == own)
        #expect(StripeInstallTokenStore.readLegacy(service: service).isEmpty)

        // Signed out: nothing happens at all.
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        #expect(await StripeInstallTokenStore.migrateLegacy(scope: nil, profileAccountId: "acct_B", service: service,
                                                           isCurrent: { _ in true }, verify: Self.neverChecked) == .nothingToDo)
    }

    @Test func legacyTokenNeverLandsOnAnAccountThatSignedOutMidCheck() async {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        let result = await StripeInstallTokenStore.migrateLegacy(
            scope: "owner-a", profileAccountId: "acct_A", service: service, isCurrent: { _ in false },
            verify: { _, _ in .matches })
        #expect(result == .deferred)
        #expect(StripeInstallTokenStore.load(for: "owner-a", service: service) == nil)
    }

    /// A send runs the upgrade first: the pre-3.3.0 token is proven, moved, then used.
    @Test func aSendMigratesTheLegacyTokenBeforeMinting() async throws {
        let service = Self.freshService()
        defer { Self.clear(service, scopes: ["owner-a"]) }
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: service))
        let (context, profile, invoice) = try Self.world(profileAccount: "acct_A")
        let stripe = FakeStripe()
        let env = PayLinkEnvironment.device(scope: "owner-a", service: service, isConfigured: true, backend: stripe,
                                           isCurrent: { _ in true }, legacyCheck: { _, _ in .matches })
        #expect(SendPreparer.payLinkPlan(for: invoice, business: profile, environment: env) == .mint(accountId: "acct_A"))
        #expect(try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_A", in: context, environment: env) == .ready)
        #expect(stripe.mints.count == 1)

        // The same send with an unprovable token says "reconnect" and mints nothing.
        let other = Self.freshService()
        defer { Self.clear(other, scopes: ["owner-a"]) }
        #expect(StripeInstallTokenStore.writeLegacy(StripeInstallTokenStore.generate(), service: other))
        let stripe2 = FakeStripe()
        let env2 = PayLinkEnvironment.device(scope: "owner-a", service: other, isConfigured: true, backend: stripe2,
                                            isCurrent: { _ in true }, legacyCheck: { _, _ in .mismatch })
        invoice.clearStripePayLink()
        #expect(try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_A", in: context, environment: env2) == .deviceUnlinked)
        #expect(stripe2.mints.isEmpty && stripe2.statusCalls == 0)
    }

    // MARK: - What the server is told, and what it answers

    @Test func everyCallSaysWhoIsAskingAndWhichAccountTheyExpect() throws {
        let post = try StripeBackendClient.makeRequest(path: "/payment-links", method: "POST", body: ["appInvoiceId": "inv"],
                                                       bearer: "tok", appToken: "jwt", expectedAccountId: "acct_B")
        #expect(post.headers["X-GL-App-Token"] == "jwt")
        #expect(post.headers["Authorization"] == "Bearer tok")
        let json = try #require(try JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: Any])
        #expect(json["expectedAccountId"] as? String == "acct_B")
        #expect(json["appInvoiceId"] as? String == "inv")

        let get = try StripeBackendClient.makeRequest(path: "/connect/status", method: "GET", body: nil,
                                                      bearer: "tok", appToken: "jwt", expectedAccountId: "acct_B")
        #expect(get.queryItems.contains(URLQueryItem(name: "expectedAccountId", value: "acct_B")))
        #expect(get.body == nil)
        #expect(get.headers["X-GL-App-Token"] == "jwt")

        // No expected account (a first connect): nothing is invented.
        let first = try StripeBackendClient.makeRequest(path: "/connect/onboard", method: "POST", body: [:],
                                                        bearer: "tok", appToken: "jwt", expectedAccountId: "")
        let firstJSON = try #require(try JSONSerialization.jsonObject(with: first.body ?? Data()) as? [String: Any])
        #expect(firstJSON["expectedAccountId"] == nil)
    }

    @Test func accountMismatchIsItsOwnReconnectError() {
        let body = Data(#"{"error":"account_mismatch"}"#.utf8)
        #expect(StripeBackendClient.error(forStatus: 409, body: body) == .accountMismatch)
        #expect(StripeBackendClient.error(forStatus: 409, body: Data(#"{"error":"conflict"}"#.utf8)) == .http(409))
        #expect(StripeBackendClient.error(forStatus: 403, body: Data(#"{"error":"invalid_claim"}"#.utf8)) == .claimRejected)
        #expect(StripeBackendError.accountMismatch.isBindingLost, "fixed by reconnecting, never by retrying")
        let savedLanguage = MBLocalization.shared.language
        defer { MBLocalization.shared.language = savedLanguage }
        MBLocalization.shared.language = .en
        let text = StripeBackendError.accountMismatch.errorDescription ?? ""
        #expect(!text.isEmpty && !text.contains("409") && !text.contains("account_mismatch"))
        MBLocalization.shared.language = .es
        #expect((StripeBackendError.accountMismatch.errorDescription ?? "") != text, "translated (law 41)")
    }

    @Test func theLegacyCheckReadsOnlyAProofAsAMatch() {
        let proven = Data(#"{"chargesEnabled":true,"payoutsEnabled":true,"detailsSubmitted":true,"currentlyDueCount":0,"accountClaim":"c"}"#.utf8)
        let unproven = Data(#"{"chargesEnabled":true,"payoutsEnabled":true,"detailsSubmitted":true,"currentlyDueCount":0}"#.utf8)
        #expect(StripeBackendClient.legacyCheck(statusCode: 200, body: proven) == .matches)
        #expect(StripeBackendClient.legacyCheck(statusCode: 200, body: unproven) == .unverifiable,
                "today's server ignores the Gold Life token, so its 200 proves nothing")
        #expect(StripeBackendClient.legacyCheck(statusCode: 409, body: Data(#"{"error":"account_mismatch"}"#.utf8)) == .mismatch)
        #expect(StripeBackendClient.legacyCheck(statusCode: 401, body: Data()) == .mismatch)
        #expect(StripeBackendClient.legacyCheck(statusCode: 403, body: Data()) == .mismatch)
        #expect(StripeBackendClient.legacyCheck(statusCode: 503, body: Data()) == .transient)
        #expect(StripeBackendClient.legacyCheck(statusCode: 429, body: Data()) == .transient)
        #expect(StripeBackendClient.legacyCheck(statusCode: 200, body: Data("nope".utf8)) == .transient)
    }

    // MARK: - F125: the poll and the auth anchor

    @Test func aStatusResultLandsOnlyOnTheSessionThatAskedForIt() {
        #expect(StripeConnectScreen.mayApplyResult(startedFor: "owner-a", now: "owner-a", isCancelled: false))
        #expect(!StripeConnectScreen.mayApplyResult(startedFor: "owner-a", now: nil, isCancelled: false), "signed out")
        #expect(!StripeConnectScreen.mayApplyResult(startedFor: "owner-a", now: "person-b", isCancelled: false))
        #expect(!StripeConnectScreen.mayApplyResult(startedFor: "owner-a", now: "owner-a", isCancelled: true))
        #expect(!StripeConnectScreen.mayApplyResult(startedFor: nil, now: nil, isCancelled: false))
    }

    @Test func thePollIsOwnedAndTheAnchorNeverTraps() throws {
        let screen = try #require(GLSource.file("Screens/StripeConnectScreen.swift"))
        #expect(!screen.contains("scenes[0]"), "an empty scene list must not trap")
        #expect(screen.contains("connectTask?.cancel()"), "leaving the screen (or signing out) stops the poll")
        #expect(WebAuthCoordinator.anchorWindow(in: []) == nil, "no scene: no anchor, and the sheet says so")
    }
}

/// The accounts a landing step asked the server about.
private actor AccountLog {
    private(set) var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
}
