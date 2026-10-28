//
//  StripeBackendClient.swift
//  GLSmallBusiness
//
//  The app's client for the gl-stripe-connect Cloudflare Worker, which holds the Stripe platform
//  secret key. Every call goes through GoldLifeCloud's `GLCloudTransport.dispatch` (law 59).
//  A plain (nonisolated) value type — NOT an actor — so its async methods,
//  when called from a @MainActor view, resume on the main actor and it's safe to mutate the main-context
//  SwiftData `@Model` objects with the results.
//

import Foundation
import GoldLifeCloud

/// Backend connection settings.
nonisolated enum StripeConfig {
    static let baseURL = "https://backend.softwarebygl.com/my-business/payments"

    /// Whether the backend has been configured (placeholders replaced). Guards calls so a misconfigured
    /// build fails fast/closed instead of hitting a bogus host.
    static var isConfigured: Bool {
        !baseURL.contains("REPLACE-ME")
    }

    /// The most one pay link can charge: $50,000.00. The Worker refuses anything above it
    /// (gl-stripe-connect MAX_AMOUNT_CENTS, 400 `amount_too_large`), so the app checks first and says so
    /// (audit 2026-10-03 F81) instead of blaming the Stripe account.
    static let maxPayLinkCents = 5_000_000
}

/// Every failure this client can produce. NO case carries a system-authored string: the whole point of
/// the closed case list is that a `URLError.localizedDescription` ("An SSL error has occurred…") or an
/// HTTP status can never reach a person — the copy below is the only thing they ever read.
nonisolated enum StripeBackendError: LocalizedError, Equatable {
    case notConfigured
    /// The Worker answered with a non-2xx status. The code is kept for CALLERS (401/403 mean this
    /// install's binding is gone, 5xx means retry) and is never shown to the user.
    case http(Int)
    /// 403 `invalid_claim` — the stored ownership claim no longer proves this install owns the account,
    /// so resending it can only fail again. Only a fresh connect clears it.
    case claimRejected
    case decoding
    case offline
    case timedOut
    /// The request never reached the backend for a reason that isn't plainly "no internet" — DNS,
    /// TLS interception on a job-site hotspot, a captive portal, a dropped connection.
    case unreachable
    case onboardingCancelled
    case browserUnavailable
    /// 409 `account_mismatch` (audit 2026-10-03 F2, gl-stripe-connect C2): this device's token is bound
    /// to a Stripe account that isn't the signed-in Gold Life ID's, or isn't the one the business
    /// profile names. Nothing was minted or read. Only a fresh connect fixes it.
    case accountMismatch
    /// 400 `amount_too_large` (audit F81): the amount is over `StripeConfig.maxPayLinkCents`. Nothing was
    /// retired or minted.
    case amountTooLarge
    /// 409 `already_paid` (audit F14): the customer already paid this invoice's link. Nothing was retired
    /// or minted; `amountCents` is what Stripe collected (nil when the Worker didn't say).
    case alreadyPaid(amountCents: Int?)

    /// The backend refused to authorize THIS install, or its ownership claim no longer holds. Both are
    /// fixed by reconnecting and never by retrying, so callers branch on this instead of a status code.
    var isBindingLost: Bool {
        switch self {
        case .claimRejected, .accountMismatch: return true
        case .http(let code): return code == 401 || code == 403
        default: return false
        }
    }

    /// `MBLocalization.string`, not `mbLoc`: this enum is `nonisolated`, so it can't hop to the main
    /// actor to read the observed language.
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return MBLocalization.string("Card payments aren’t available in this version of the app yet.")
        case .http(let code) where code == 401 || code == 403:
            return MBLocalization.string("This device isn’t linked to your Stripe account. Open Menu → Connect Stripe and reconnect.")
        case .claimRejected:
            return MBLocalization.string("Your Stripe connection needs to be set up again. Open Menu → Connect Stripe and reconnect your Stripe account.")
        case .http(let code) where (400..<500).contains(code):
            return MBLocalization.string("Your Stripe setup needs attention. Open Menu → Connect Stripe to finish connecting.")
        case .http:
            return MBLocalization.string("Stripe setup isn’t responding right now. Try again in a few minutes — nothing on your account changed.")
        case .decoding:
            return MBLocalization.string("Something on our end sent back the wrong answer. Try again in a few minutes — if it keeps happening, email support@softwarebygl.com.")
        case .offline:
            return MBLocalization.string("You’re not connected to the internet. Check your connection and try again.")
        case .timedOut:
            return MBLocalization.string("The connection timed out before Stripe answered. Check your connection and try again.")
        case .unreachable:
            return MBLocalization.string("Couldn’t reach Stripe from this network. Try again, or switch to a different Wi-Fi network or cellular.")
        case .onboardingCancelled:
            return MBLocalization.string("Stripe setup closed before it finished. You can pick it up again any time.")
        case .browserUnavailable:
            return MBLocalization.string("Couldn’t open Stripe. Please try again.")
        case .accountMismatch:
            return MBLocalization.string("This device is linked to a different Stripe account than your business. Open Menu → Connect Stripe and reconnect.")
        case .amountTooLarge:
            return MBLocalization.string("Card payments are limited to $50,000 per invoice.")
        case .alreadyPaid:
            return MBLocalization.string("Stripe reports this invoice was already paid.")
        }
    }

    /// Map a URLSession failure to our own words. Same shape as `GoldLifeAuth.signInFailureMessage`:
    /// the two causes a person can act on get their own sentence, everything else is reported as the
    /// network not getting through — never Apple's developer-facing wording.
    static func from(urlSessionError error: Error) -> StripeBackendError {
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed: return .offline
        case .timedOut: return .timedOut
        default: return .unreachable
        }
    }
}

// MARK: - Responses (nonisolated so Decodable runs off the main actor inside the client)

nonisolated struct StripeOnboardResponse: Decodable {
    let connectedAccountId: String
    let onboardingUrl: String
    /// Signed ownership claim for the account; store it and present it when resuming on another device.
    let accountClaim: String?
}

nonisolated struct StripeConnectStatus: Decodable {
    let chargesEnabled: Bool
    let payoutsEnabled: Bool
    let detailsSubmitted: Bool
    let currentlyDueCount: Int
    /// The backend can no longer act on the bound account (deleted, or created under a platform key
    /// that has since been rotated). Optional because a healthy response omits it entirely.
    let needsReconnect: Bool?

    /// The account's signed claim. Only a server that verified the caller's Gold Life token (and that
    /// the bound account is the expected one) sends it, so its presence is the upgrade path's proof.
    let accountClaim: String?

    /// Ready to mint a pay link: can charge and has nothing still required.
    var canCharge: Bool { chargesEnabled && currentlyDueCount == 0 }

    /// The stored binding is dead, not merely unfinished. Decoding this is what keeps the UI off
    /// "Finish Stripe setup" — that button resends the dead account id and walks into the same failure.
    var mustReconnect: Bool { needsReconnect == true }
}

nonisolated struct StripePayLinkResponse: Decodable {
    let url: String
    let paymentLinkId: String
}

nonisolated struct StripePayLinkStatusResponse: Decodable {
    let status: String          // "none" | "open" | "paid"
    let amountPaidCents: Int?
    let paidAt: Int?            // epoch millis

    var isPaid: Bool { status == "paid" }
}

// MARK: - Client

nonisolated struct StripeBackendClient: Sendable {
    static let shared = StripeBackendClient()

    /// The Gold Life ID app token sent as `X-GL-App-Token` on every call (audit 2026-10-03 F2, server
    /// cluster C2): the server checks WHO is asking, not only which install. Short-lived and in memory
    /// only, minted for `aud: gl-business` like the sync engine's (GLSyncTokenProvider).
    private static let appTokens = GLSyncTokenProvider()

    /// Create-or-resume the connected account and get a hosted onboarding URL. Pass the synced
    /// `existingAccountId` (empty on first connect) so a new device resumes the same account.
    func onboard(existingAccountId: String, accountClaim: String) async throws -> StripeOnboardResponse {
        // Onboarding is the ONLY call that may mint the install token — the backend links the bearer to
        // the account during /connect/onboard. Minting on other calls would destroy the "this device was
        // never linked" signal (`StripeInstallTokenStore.exists`) that the reconnect UX relies on, and an
        // unlinked random token is rejected by the backend anyway. The token is the signed-in Gold Life
        // ID's own (F2): signed out there is nothing to bind.
        guard let scope = StripeInstallTokenStore.signedInScope else { throw StripeBackendError.http(401) }
        do {
            return try await onboardOnce(scope: scope, existingAccountId: existingAccountId, accountClaim: accountClaim)
        } catch StripeBackendError.accountMismatch where StripeInstallTokenStore.load(for: scope) != nil {
            // This account's token is bound to a Stripe account that isn't this business's. It can
            // never mint for this business, so it goes, and one fresh token resumes the profile's own
            // account (its synced id and claim) instead.
            StripeInstallTokenStore.delete(for: scope)
            return try await onboardOnce(scope: scope, existingAccountId: existingAccountId, accountClaim: accountClaim)
        }
    }

    private func onboardOnce(scope: String, existingAccountId: String,
                             accountClaim: String) async throws -> StripeOnboardResponse {
        let existing = StripeInstallTokenStore.load(for: scope)
        let hadToken = existing != nil
        guard !StripeInstallTokenStore.ensure().isEmpty else { throw StripeBackendError.http(401) }
        var body: [String: Any] = [:]
        if !existingAccountId.isEmpty {
            body["connectedAccountId"] = existingAccountId
            if !accountClaim.isEmpty { body["accountClaim"] = accountClaim }
        }
        // The account the caller expects: the one the profile names, else the one this token is bound to.
        let expected = existingAccountId.isEmpty ? (existing?.boundAccountId ?? "") : existingAccountId
        do {
            let response: StripeOnboardResponse = try await send("/connect/onboard", method: "POST", body: body,
                                                                 expectedAccountId: expected)
            // The backend just said which account this token is bound to: remember it, so a pay link
            // is only ever minted for the business that names this account (SendPreparer).
            StripeInstallTokenStore.recordBoundAccount(response.connectedAccountId, for: scope)
            return response
        } catch {
            // A failed onboard must not leave a freshly-minted, never-linked token behind — it would
            // flip `exists` and permanently hide the "Reconnect this device" path on this device.
            // But roll back ONLY when the backend definitively rejected us before binding anything:
            // it writes the ownership row BEFORE it builds the account link, so on a 5xx — or on a
            // reply lost in flight — the server may already be bound to the very token we'd delete,
            // and the next Connect would create a SECOND Stripe account for the same business.
            if !hadToken, Self.rejectedBeforeBinding(error) { StripeInstallTokenStore.delete(for: scope) }
            throw error
        }
    }

    /// Whether the onboard call failed in a way that proves the server never bound the token.
    private static func rejectedBeforeBinding(_ error: Error) -> Bool {
        switch error {
        case StripeBackendError.notConfigured: return true              // never left the device
        case StripeBackendError.claimRejected: return true              // refused before any write
        case StripeBackendError.accountMismatch: return true            // refused before any write
        case StripeBackendError.http(let code): return (400..<500).contains(code)
        default: return false                                           // 5xx / no answer / bad decode
        }
    }

    /// Whether the connected account can accept charges right now (the authoritative gate before minting).
    func connectStatus() async throws -> StripeConnectStatus {
        try await send("/connect/status", method: "GET", body: nil)
    }

    /// Mint a locked-amount Payment Link for an invoice. `supersedesLinkId` retires a prior link when the
    /// amount changed (milestone/partial), so a stale-amount link can't still be paid.
    func createPaymentLink(appInvoiceId: String, amountCents: Int, currency: String = "usd",
                           description: String, idempotencyKey: String,
                           supersedesLinkId: String?) async throws -> StripePayLinkResponse {
        var body: [String: Any] = [
            "appInvoiceId": appInvoiceId,
            "amountCents": amountCents,
            "currency": currency,
            "description": description,
            "idempotencyKey": idempotencyKey,
        ]
        if let supersedesLinkId, !supersedesLinkId.isEmpty { body["supersedesLinkId"] = supersedesLinkId }
        return try await send("/payment-links", method: "POST", body: body)
    }

    /// Read the stored paid/open status for an invoice (polled on invoice open / app foreground).
    func payLinkStatus(appInvoiceId: String) async throws -> StripePayLinkStatusResponse {
        try await send("/payment-links/status", method: "POST", body: ["appInvoiceId": appInvoiceId])
    }

    // MARK: The pre-3.3.0 token

    /// Asks the server whether the unscoped pre-3.3.0 `token` belongs to `expectedAccountId` and to the
    /// signed-in Gold Life ID. Never throws: no answer is `.transient`.
    func checkLegacyToken(_ token: String, expectedAccountId: String) async -> StripeInstallTokenStore.LegacyCheck {
        do {
            let (status, data) = try await dispatch("/connect/status", method: "GET", body: nil,
                                                    bearer: token, expectedAccountId: expectedAccountId)
            return Self.legacyCheck(statusCode: status, body: data)
        } catch {
            return .transient
        }
    }

    /// The upgrade path (F2): moves the pre-3.3.0 token to the signed-in account only if the server
    /// proves it is the account `profileAccountId` names; deletes it only on proof it is not. A no-op
    /// when there is none, so every Stripe surface can call it before it reads the token.
    func migrateLegacyTokenIfNeeded(profileAccountId: String) async {
        guard StripeConfig.isConfigured, StripeInstallTokenStore.hasLegacyToken else { return }
        _ = await StripeInstallTokenStore.migrateLegacy(
            scope: StripeInstallTokenStore.signedInScope, profileAccountId: profileAccountId,
            verify: { token, expected in await self.checkLegacyToken(token, expectedAccountId: expected) })
    }

    /// Only a 2xx carrying the account's claim is proof (the server sends it only after verifying the
    /// Gold Life token and the expected account). A 2xx without it is a server that ignores both.
    static func legacyCheck(statusCode: Int, body: Data) -> StripeInstallTokenStore.LegacyCheck {
        switch statusCode {
        case 200..<300:
            guard let status = try? JSONDecoder().decode(StripeConnectStatus.self, from: body) else { return .transient }
            return (status.accountClaim ?? "").isEmpty ? .unverifiable : .matches
        case 401 where errorTag(body) == "invalid_app_token":
            return .transient       // our Gold Life token, not the install token: ask again later
        case 401, 403, 409:
            return .mismatch
        default:
            return .transient
        }
    }

    // MARK: Transport

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]?,
                                    expectedAccountId: String? = nil) async throws -> T {
        let (status, data) = try await dispatch(path, method: method, body: body, bearer: nil,
                                                expectedAccountId: expectedAccountId)
        guard (200..<300).contains(status) else { throw Self.error(forStatus: status, body: data) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StripeBackendError.decoding
        }
    }

    /// One call: the signed-in account's own token (or `bearer` for the upgrade check), the Gold Life
    /// app token, and the account the caller expects (default: the one this token is bound to).
    private func dispatch(_ path: String, method: String, body: [String: Any]?, bearer: String?,
                          expectedAccountId: String?) async throws -> (Int, Data) {
        guard StripeConfig.isConfigured else { throw StripeBackendError.notConfigured }
        let entry = StripeInstallTokenStore.load(for: StripeInstallTokenStore.signedInScope)
        let token = bearer ?? entry?.token ?? ""
        // No token for this Gold Life ID on this device: the backend would refuse it (401) anyway.
        guard !token.isEmpty else { throw StripeBackendError.http(401) }
        let expected = expectedAccountId ?? entry?.boundAccountId ?? ""

        var forceRefresh = false
        for attempt in 0..<2 {
            let appToken = try await Self.appToken(forcingRefresh: forceRefresh)
            let request = try Self.makeRequest(path: path, method: method, body: body, bearer: token,
                                               appToken: appToken, expectedAccountId: expected)
            let res: GLCloudResponse
            do {
                res = try await GLCloudTransport.shared.dispatch(request)
            } catch let error as GLCloudError {
                if case .offline = error { throw StripeBackendError.offline }
                throw StripeBackendError.unreachable
            } catch {
                throw StripeBackendError.from(urlSessionError: error)
            }
            // A Gold Life token the server refused (rotated key, a token that expired in flight): mint
            // a fresh one once. Never a reason to show "reconnect".
            if res.statusCode == 401, Self.errorTag(res.data) == "invalid_app_token", attempt == 0 {
                forceRefresh = true
                continue
            }
            return (res.statusCode, res.data)
        }
        throw StripeBackendError.http(401)
    }

    /// The request every call sends. Internal so a test can read what goes on the wire.
    static func makeRequest(path: String, method: String, body: [String: Any]?, bearer: String,
                            appToken: String, expectedAccountId: String) throws -> GLCloudRequest {
        guard let baseURL = URL(string: StripeConfig.baseURL) else { throw StripeBackendError.notConfigured }
        var headers = [
            "Authorization": "Bearer \(bearer)",
            "X-GL-App-Token": appToken,
        ]
        var queryItems: [URLQueryItem] = []
        var payload = body
        if !expectedAccountId.isEmpty {
            // GET carries it in the query string (no body); every other call in the JSON body.
            if method.uppercased() == "GET" {
                queryItems.append(URLQueryItem(name: "expectedAccountId", value: expectedAccountId))
            } else {
                payload = (payload ?? [:]).merging(["expectedAccountId": expectedAccountId]) { _, new in new }
            }
        }
        let bodyData = try payload.map { try JSONSerialization.data(withJSONObject: $0) }
        if bodyData != nil { headers["Content-Type"] = "application/json" }
        return GLCloudRequest(
            target: .custom(baseURL),
            path: path,
            method: method,
            queryItems: queryItems,
            headers: headers,
            body: bodyData,
            authMode: .none,
            validateStatus: false
        )
    }

    /// The Gold Life app token for `X-GL-App-Token`. Fail closed: a call we can't say who made is never
    /// sent (a payment could otherwise land on an account nobody checked).
    private static func appToken(forcingRefresh: Bool) async throws -> String {
        let state: GLSyncAuthState
        do {
            state = try await appTokens.token(forcingRefresh: forcingRefresh)
        } catch let error as GLCloudError {
            if case .offline = error { throw StripeBackendError.offline }
            throw StripeBackendError.unreachable
        } catch {
            throw StripeBackendError.from(urlSessionError: error)
        }
        guard case .token(let token, _) = state else { throw StripeBackendError.http(401) }
        return token
    }

    /// The Worker's own error tag (never shown to anyone) turned into our closed error list.
    static func error(forStatus status: Int, body: Data) -> StripeBackendError {
        switch (status, errorTag(body)) {
        case (403, "invalid_claim"): return .claimRejected        // the ownership claim no longer holds
        case (409, "account_mismatch"): return .accountMismatch   // another account's token (F2)
        case (400, "amount_too_large"): return .amountTooLarge    // over the per-link ceiling (F81)
        case (409, "already_paid"):                               // the customer already paid (F14)
            return .alreadyPaid(amountCents: errorObject(body)?["amountCents"] as? Int)
        default: return .http(status)
        }
    }

    private static func errorTag(_ body: Data) -> String? {
        errorObject(body)?["error"] as? String
    }

    private static func errorObject(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
