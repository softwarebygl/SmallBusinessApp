//
//  GLSyncTokenProvider.swift
//  GLSmallBusiness
//
//  Identity for GLSync (GLSYNC-SPEC.md §4). gl-business-api holds no identity tables — it is
//  a resource server for Gold Life ID APP TOKENS. This is where those come from:
//
//      Stytch session JWT ──▶ POST /auth/app-token {audience:"gl-business"}  (gl-money-api)
//                          ──▶ 15-minute RS256 app JWT, cached IN MEMORY
//
//  NEVER PERSISTED. The token is short-lived by design, so writing it to the Keychain would
//  add a stealable credential with no benefit — a cold launch simply mints a new one.
//
//  SIGNED OUT IS A STATE, NOT A FAILURE. `.signedOut` comes back as a value, never as a
//  thrown error, because My Business is soft-gated: the whole app keeps working local-only,
//  and the user sees a gentle "Not backed up", never a nag and never a block. Degrade, don't
//  punish.
//
//  WEAK SIGNAL NEVER SIGNS ANYONE OUT (REQUIREMENTS law 13, owner ruling 2026-09-28). The mint
//  rides GoldLifeCloud's `.sessionJwt` auth, so the fleet's one 401 refresh-and-retry runs in
//  GoldLifeCloud, not in a copy here (`GLSyncIdentityCall`, below, shared with the document
//  key). Only Stytch itself refusing the session rings `GoldLifeAPI.onSessionExpired`. A
//  refresh that can't reach Stytch, or a fresh token the server still refuses, is a quiet
//  "try again later" that keeps the session and the person's data. This file used to run its
//  own refresh, and a refresh lost to weak signal read as a dead session and signed people out.
//

import Foundation
import Observation
import StytchCore
import GoldLifeCloud
import GoldLifeUI

/// The answer to "can we sync right now". Deliberately not `String?` — nil would make
/// "signed out" and "the mint failed" the same value, and they are not remotely the same
/// thing to the user.
nonisolated enum GLSyncAuthState: Sendable, Equatable {
    /// No Gold Life ID session. Local-only operation; nothing is wrong.
    case signedOut
    /// A live app token for `aud: gl-business`, and the canonical Gold Life ID it was minted
    /// for — the token's verified `sub`, which is the exact id gl-business-api partitions
    /// records by. The engine binds its cursor to it (`GLSyncState.ownerID`) so a cursor can
    /// never be spent against somebody else's account.
    case token(String, subject: String)
}

/// Whose cycle this is (QA 2026-10-03 F18): the Gold Life ID the cycle's first token was minted
/// for, and the Stytch session that minted it. A sync cycle is bound to it at its start, and
/// every request the cycle makes afterwards must still answer to it. The session alone cannot be
/// the key (the mint, not the app, knows which Gold Life ID a session belongs to), and the owner
/// alone cannot either (checking it means minting first, under whoever is signed in NOW).
nonisolated struct GLSyncCycleBinding: Sendable, Equatable {
    /// The app token's verified `sub`: the id gl-business-api partitions every record by.
    let owner: String
    /// The Stytch session subject that minted it.
    let session: String
}

/// The subscription facts the mint stamps into the app token as `ent` (QA 2026-10-03 F17).
///
/// The token is cached for up to 15 minutes, so the standing inside it can be out of date: a
/// person who renews keeps pushing under a `lapsed` token, and every edit they make is refused
/// until it expires. The engine watches these facts and drops the token the moment any of them
/// changes (`GLSyncEngine.entitlementChanged`).
nonisolated struct GLSyncEntitlement: Sendable, Equatable {
    let isSubscribed: Bool
    let serverEntitled: Bool
    let isLapsed: Bool

    @MainActor
    static func current() -> GLSyncEntitlement {
        let subscription = SubscriptionManager.shared
        return GLSyncEntitlement(isSubscribed: subscription.isSubscribed,
                                 serverEntitled: subscription.serverEntitled,
                                 isLapsed: subscription.isLapsed)
    }

    /// The standing now, then again after every change. Ends when the reader stops reading.
    @MainActor
    static func changes() -> AsyncStream<GLSyncEntitlement> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: GLSyncEntitlement.self, bufferingPolicy: .bufferingNewest(1))
        watch(continuation)
        return stream
    }

    /// Observation fires once per registration, so every change sends the new value and
    /// registers again. Both happen in one MainActor turn, so no change can fall between them,
    /// and a stream nobody reads any more stops registering.
    @MainActor
    private static func watch(_ continuation: AsyncStream<GLSyncEntitlement>.Continuation) {
        if case .terminated = continuation.yield(current()) { return }
        withObservationTracking {
            _ = current()
        } onChange: {
            Task { @MainActor in watch(continuation) }
        }
    }
}

actor GLSyncTokenProvider {

    /// The closed audience list on the mint side names exactly this string; anything else is
    /// a 400, never a token.
    static let audience = "gl-business"

    /// Tokens live 15 minutes (`APP_TOKEN_TTL_SECONDS`). Refresh at T-2min so a request that
    /// takes a slow job-site second to leave the device never lands expired.
    static let refreshMargin: TimeInterval = 120

    private struct Cached {
        let token: String
        let subject: String
        let expiresAt: Date
        /// The Stytch SESSION SUBJECT this token was minted for. Freshness alone is NOT enough
        /// to re-serve a cached app token: signing out clears the Stytch session but cannot
        /// reach inside this actor, so a token minted seconds earlier stayed "fresh" for up to
        /// its full TTL and the engine kept syncing under the PREVIOUS person's identity.
        ///
        /// The session's `sub`, not the JWT text: the SDK re-issues the session JWT on a
        /// background heartbeat, and keying on the text would throw away a perfectly good app
        /// token (and burn a mint) every few minutes for the same person.
        let mintedFor: String
        func isFresh(margin: TimeInterval) -> Bool { Date() < expiresAt.addingTimeInterval(-margin) }
    }

    /// The one road out (law 59). A test hands in a transport over a stub session.
    private let transport: GLCloudTransport
    /// The Stytch SDK's stored session JWT: a local Keychain read, never a network call.
    private let storedSessionJWT: @Sendable () -> String?
    /// The dead-session bell (`GoldLifeAPI.onSessionExpired`), rung only when Stytch itself
    /// refused the session.
    private let onSessionExpired: @MainActor @Sendable () async -> Void

    init(transport: GLCloudTransport = .shared,
         storedSessionJWT: @escaping @Sendable () -> String? = { StytchClient.sessions.sessionJwt },
         onSessionExpired: @escaping @MainActor @Sendable () async -> Void = { await GoldLifeAPI.onSessionExpired?() }) {
        self.transport = transport
        self.storedSessionJWT = storedSessionJWT
        self.onSessionExpired = onSessionExpired
    }

    private var cached: Cached?
    /// One mint at a time. Without this, a push and a pull starting together each mint a
    /// token, burning two of the caller's 60-per-window budget for one need.
    private var mint: Task<GLSyncAuthState, Error>?

    /// The current app token, minting one if the cache is empty or inside the refresh
    /// margin. `forcingRefresh` is the 401 path: the cached token was rejected, so it is
    /// discarded before the retry regardless of how fresh it looked.
    ///
    /// `boundTo` is a sync cycle's binding (`cycleBinding()`). Bound, the answer is `.signedOut`
    /// the moment a different session is live, BEFORE any mint: a cycle that outlives its
    /// person must never mint a token for the next one (QA 2026-10-03 F18). Unbound callers
    /// (the Stripe client, account deletion) follow whichever session is live.
    func token(forcingRefresh: Bool = false,
               boundTo binding: GLSyncCycleBinding? = nil) async throws -> GLSyncAuthState {
        try await resolve(forcingRefresh: forcingRefresh, boundTo: binding).state
    }

    /// The binding a sync cycle starts under: who is signed in, and through which session. Nil
    /// when nobody is, or when the session changed while the token was being minted (the token
    /// may then belong to either person, so this cycle does not run; the next trigger asks
    /// again).
    func cycleBinding() async throws -> GLSyncCycleBinding? {
        let (state, session) = try await resolve(forcingRefresh: false, boundTo: nil)
        guard case .token(_, let owner) = state, let session,
              Self.sessionSubject(of: storedSessionJWT()) == session else { return nil }
        return GLSyncCycleBinding(owner: owner, session: session)
    }

    /// `token(...)`, plus the session subject the answer was read under.
    private func resolve(forcingRefresh: Bool,
                         boundTo binding: GLSyncCycleBinding?) async throws -> (state: GLSyncAuthState, session: String?) {
        // Read the live session FIRST, every time. It is a local Keychain read, not a network
        // call, and it is the only thing that can tell this actor that the person signed out —
        // `invalidate()` covers the paths that go through `GoldLifeAuth`, and this covers the
        // ones that do not (a session revoked from another device, an expiry the SDK cleared,
        // a Keychain wipe). Answering `.signedOut` here is fail-CLOSED: the app carries on
        // local-only, which is a state, not a failure (§4).
        guard let sessionSubject = Self.sessionSubject(of: storedSessionJWT()) else {
            cached = nil
            mint = nil
            return (.signedOut, nil)
        }

        // A cycle's request, and somebody else's session is live: the cycle's person signed
        // out. Nothing is minted and nothing is sent; the cache is left to the unbound path.
        if let binding, binding.session != sessionSubject {
            return (.signedOut, sessionSubject)
        }

        if forcingRefresh {
            cached = nil
            mint = nil          // a mint started before we learned the token was bad is stale
        } else if let cached, cached.isFresh(margin: Self.refreshMargin),
                  cached.mintedFor == sessionSubject {
            return (.token(cached.token, subject: cached.subject), sessionSubject)
        } else if let cached, cached.mintedFor != sessionSubject {
            // A DIFFERENT session is live now — somebody signed out and back in, possibly as
            // somebody else. The old token is not merely stale, it is the wrong identity.
            self.cached = nil
            mint = nil
        }

        if let mint { return (try await mint.value, sessionSubject) }
        let task = Task { try await self.performMint(sessionSubject: sessionSubject) }
        mint = task
        defer { mint = nil }
        return (try await task.value, sessionSubject)
    }

    /// The live session's subject, or nil when there is no session. A JWT whose subject can't
    /// be read stands for itself, as before.
    private static func sessionSubject(of sessionJWT: String?) -> String? {
        guard let sessionJWT else { return nil }
        return subject(ofJWT: sessionJWT) ?? sessionJWT
    }

    /// Drop the cached token. Call on sign-out so the next cycle asks a fresh question
    /// instead of presenting a token for an identity that no longer has a session — and on
    /// any change of subscription (`GLSyncEntitlement`), because the mint stamps the account's
    /// standing into the token (`ent`) and a renewal pushed under a `lapsed` token is refused.
    func invalidate() {
        cached = nil
        mint = nil
    }

    // MARK: - The mint

    private func performMint(sessionSubject: String) async throws -> GLSyncAuthState {
        guard storedSessionJWT() != nil else { return .signedOut }

        // Stytch's session JWT is ~5 minutes and refreshes on a background poll, so an app
        // returning from the background can hold one that expired while it slept. GoldLifeCloud
        // refreshes once and retries, which turns that into an invisible hiccup.
        guard case .response(let data, let status) = try await GLSyncIdentityCall.send(
            Self.mintRequest(), via: transport, onSessionExpired: onSessionExpired) else {
            return .signedOut
        }

        guard (200..<300).contains(status) else {
            throw Self.error(status: status, body: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else {
            throw GLSyncTransportError.malformedResponse
        }
        // The `sub` the Worker will verify and scope every record by. Without it the engine
        // cannot tell whose cursor it is holding, so a token we cannot read the subject out of
        // is not usable for syncing at all.
        guard let subject = Self.subject(ofJWT: token) else {
            throw GLSyncTransportError.malformedResponse
        }
        // Trust the server's own TTL rather than assuming 15 minutes: the mint owns that
        // number and may shorten it without shipping an app update.
        let ttl = (object["expires_in"] as? NSNumber)?.doubleValue ?? 15 * 60
        cached = Cached(token: token, subject: subject,
                        expiresAt: Date().addingTimeInterval(ttl), mintedFor: sessionSubject)
        return .token(token, subject: subject)
    }

    /// The `sub` claim of a JWT, read WITHOUT verifying the signature.
    ///
    /// Safe for both uses here because neither is a trust decision: the app token's subject is
    /// re-verified by the Worker on every request (it is the id it partitions by), and the
    /// session's subject is only ever compared against itself to notice that the session
    /// changed. Nothing is authorized on the strength of this parse.
    nonisolated static func subject(ofJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding; Data(base64Encoded:) insists on it.
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String, !subject.isEmpty else { return nil }
        return subject
    }

    /// `POST /auth/app-token` on gl-money-api. GoldLifeCloud attaches the session JWT.
    private static func mintRequest() -> GLCloudRequest {
        GLCloudRequest(
            target: .custom(LocalSecrets.workerURL),
            path: "auth/app-token",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: ["audience": audience]),
            authMode: .sessionJwt,
            validateStatus: false
        )
    }

    /// Deliberately reuses `GLSyncTransportError` rather than introducing a second error
    /// vocabulary for the same failures — the engine has one set of retry rules and one set
    /// of user-facing sentences, and a mint failure is a sync failure to everyone upstream.
    private static func error(status: Int, body: Data) -> GLSyncTransportError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch object?["error"] as? String {
        case "rate_limited":
            let seconds = (object?["retry_after_seconds"] as? Double) ?? 60
            return .rateLimited(retryAfter: seconds)
        case "bad_audience", "bad_body":
            // A contract break between this build and the mint's closed audience list.
            return .badRequest
        default: break
        }
        // 500 `internal_error` is the EXPECTED answer until GLID_SIGNING_KEY_B64 is set in
        // production (apptoken.ts calls absence "a supported state"). Transient by
        // classification, so the engine backs off quietly instead of blaming the user.
        return status == 429 ? .rateLimited(retryAfter: 60) : .server(status: status)
    }
}

// MARK: - One call to the identity Worker

/// One call from the sync layer to the identity Worker (gl-money-api), shared by the app-token
/// mint and the tax-document key so the weak-signal rule lives in ONE place in this app.
///
/// The request rides `.sessionJwt`, so GoldLifeCloud runs the fleet's one 401 refresh-and-retry
/// (law 59). Only Stytch ending the session ends it (law 13, owner ruling 2026-09-28): Stytch
/// refused it (`.sessionExpired`: the bell rings) or the SDK holds none (`.notSignedIn`, the
/// same bell, as `GoldLifeAPI.send` rings it); both answer `.signedOut`. Weak signal never
/// does: a refresh that can't reach Stytch, or a fresh token the server still refuses, is
/// `GLCloudError.authTemporarilyUnavailable`, answered as the 503 it is, so each caller's own
/// status table reads it as "try again later" and the session and data stay. Everything else
/// is the device's network (offline, a timeout, a dropped connection): `.offline`.
nonisolated enum GLSyncIdentityCall {
    enum Outcome: Sendable {
        case response(Data, status: Int)
        case signedOut
    }

    static func send(
        _ request: GLCloudRequest,
        via transport: GLCloudTransport,
        onSessionExpired: @MainActor @Sendable () async -> Void
    ) async throws -> Outcome {
        do {
            let response = try await transport.dispatch(request)
            return .response(response.data, status: response.statusCode)
        } catch let error as GLCloudError {
            switch error {
            case .authTemporarilyUnavailable:
                return .response(Data(), status: 503)
            case .sessionExpired, .notSignedIn:
                await onSessionExpired()
                return .signedOut
            default:
                throw GLSyncTransportError.offline
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GLSyncTransportError.offline
        }
    }
}
