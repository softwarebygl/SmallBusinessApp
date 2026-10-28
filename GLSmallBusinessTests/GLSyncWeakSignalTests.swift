//
//  GLSyncWeakSignalTests.swift
//  GLSmallBusinessTests
//
//  Weak signal never signs anyone out (REQUIREMENTS law 13, owner ruling 2026-09-28: "A
//  weak-signal token refresh must never be treated as a session ending"). The sync layer's
//  two calls to the identity Worker, the app-token mint (`GLSyncTokenProvider`) and the
//  tax-document key (`GLSyncDocumentCrypto`), each used to run their own refresh: a Stytch
//  refresh lost to weak signal kept the old JWT, the retry got 401 again, and that rang
//  `GoldLifeAPI.onSessionExpired`, which revokes the session. Now only Stytch itself refusing
//  the session rings the bell. A refresh that can't reach Stytch, or a fresh token the server
//  still refuses, is a quiet "try again later" that keeps the session.
//
//  Serialized: it drives GoldLifeCloud's static session mocks (`GLSessionEngine.mockJwt`,
//  `mockAuthenticate`) and one stub URL protocol.
//

import Testing
import Foundation
import GoldLifeCloud
@testable import GLSmallBusiness

/// Answers every request from the test's handler; nothing reaches the network.
private final class WeakSignalStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Counts rings of the session-expired bell.
@MainActor
private final class ExpiryBell {
    private(set) var rings = 0
    func ring() { rings += 1 }
}

private func answer(_ request: URLRequest, status: Int, body: String = "{}") throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (response, Data(body.utf8))
}

/// A JWT-shaped string whose payload carries `sub` (the provider reads it unverified).
private func jwt(sub: String) -> String {
    let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

@MainActor
@Suite(.serialized)
struct GLSyncWeakSignalTests {

    private let staleJWT = jwt(sub: "person-1")
    private let freshJWT = jwt(sub: "person-1") + "-fresh"

    /// A transport over the stub session, a signed-in mock session, and a counted bell.
    private func rig(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> (transport: GLCloudTransport, bell: ExpiryBell, ring: @MainActor @Sendable () async -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WeakSignalStubProtocol.self]
        WeakSignalStubProtocol.handler = handler
        GLSessionEngine.mockJwt = staleJWT
        let transport = GLCloudTransport(session: URLSession(configuration: config), sessionEngine: GLSessionEngine())
        let bell = ExpiryBell()
        return (transport, bell, { bell.ring() })
    }

    private func reset() {
        WeakSignalStubProtocol.handler = nil
        GLSessionEngine.mockJwt = nil
        GLSessionEngine.mockAuthenticate = nil
        GLSessionEngine.mockRefresh = nil
    }

    private func provider(_ rig: (transport: GLCloudTransport, bell: ExpiryBell, ring: @MainActor @Sendable () async -> Void)) -> GLSyncTokenProvider {
        GLSyncTokenProvider(transport: rig.transport, storedSessionJWT: { GLSessionEngine.mockJwt }, onSessionExpired: rig.ring)
    }

    private func documents(_ rig: (transport: GLCloudTransport, bell: ExpiryBell, ring: @MainActor @Sendable () async -> Void)) -> GLSyncDocumentCrypto {
        GLSyncDocumentCrypto(transport: rig.transport, storedSessionJWT: { GLSessionEngine.mockJwt }, onSessionExpired: rig.ring)
    }

    // MARK: - The app-token mint

    /// The field-day bug: back from the background with an expired JWT, Stytch's refresh
    /// fails on weak signal and the SDK keeps the session. That is not a session ending.
    @Test
    func aMint401WhoseRefreshCantReachStytchKeepsTheSession() async throws {
        GLSessionEngine.mockAuthenticate = { throw URLError(.notConnectedToInternet) }
        defer { reset() }
        var requests = 0
        let rig = try rig { request in
            requests += 1
            return try answer(request, status: 401)
        }

        await #expect(throws: GLSyncTransportError.server(status: 503)) {
            _ = try await provider(rig).token()
        }
        #expect(rig.bell.rings == 0, "weak signal must never sign anyone out")
        #expect(requests == 1, "the JWT the server just refused is not sent again")
        #expect(GLSyncTransportError.server(status: 503).isTransient, "retried on a later cycle")
    }

    /// Stytch vouched for a fresh JWT and the mint still refused it (the server couldn't check
    /// tokens for a moment): still weak signal, the session kept, one retry only.
    @Test
    func aMintThatRefusesAFreshTokenKeepsTheSession() async throws {
        let fresh = freshJWT
        GLSessionEngine.mockAuthenticate = { GLSessionEngine.mockJwt = fresh }
        defer { reset() }
        var seen: [String?] = []
        let rig = try rig { request in
            seen.append(request.value(forHTTPHeaderField: "Authorization"))
            return try answer(request, status: 401)
        }

        await #expect(throws: GLSyncTransportError.server(status: 503)) {
            _ = try await provider(rig).token()
        }
        #expect(rig.bell.rings == 0)
        #expect(seen == ["Bearer \(staleJWT)", "Bearer \(freshJWT)"])
    }

    /// A stale JWT that Stytch refreshes: the retry mints the app token, nobody notices.
    @Test
    func aMint401ThatStytchRefreshesMintsTheToken() async throws {
        let fresh = freshJWT
        GLSessionEngine.mockAuthenticate = { GLSessionEngine.mockJwt = fresh }
        defer { reset() }
        let appToken = jwt(sub: "6737-0287")
        var sent: [URLRequest] = []
        let rig = try rig { request in
            sent.append(request)
            let refreshed = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)"
            return try answer(request, status: refreshed ? 200 : 401,
                              body: refreshed ? #"{"token":"\#(appToken)","expires_in":900}"# : "{}")
        }

        let state = try await provider(rig).token()
        #expect(state == .token(appToken, subject: "6737-0287"))
        #expect(rig.bell.rings == 0)
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/auth/app-token") == true })
    }

    /// Offline is an internet problem, never a sign-out.
    @Test
    func anOfflineMintKeepsTheSession() async throws {
        defer { reset() }
        let rig = try rig { _ in throw URLError(.notConnectedToInternet) }

        await #expect(throws: GLSyncTransportError.offline) {
            _ = try await provider(rig).token()
        }
        #expect(rig.bell.rings == 0)
    }

    /// The one real ending: Stytch refused the session and its SDK cleared it.
    @Test
    func aMintWhoseSessionStytchRefusedSignsOut() async throws {
        GLSessionEngine.mockAuthenticate = {
            GLSessionEngine.mockJwt = nil
            throw URLError(.userAuthenticationRequired)
        }
        defer { reset() }
        let rig = try rig { request in try answer(request, status: 401) }

        let state = try await provider(rig).token()
        #expect(state == .signedOut)
        #expect(rig.bell.rings == 1)
    }

    // MARK: - The tax-document key

    /// The same weak signal on the document-key fetch: the W-9 waits in the outbox (quiet,
    /// transient), and the person stays signed in.
    @Test
    func aDocumentKey401WhoseRefreshCantReachStytchKeepsTheSession() async throws {
        GLSessionEngine.mockAuthenticate = { throw URLError(.networkConnectionLost) }
        defer { reset() }
        let rig = try rig { request in try answer(request, status: 401) }

        await #expect(throws: GLSyncTransportError.documentKeyUnavailable) {
            _ = try await documents(rig).seal(Data("W-9".utf8))
        }
        #expect(rig.bell.rings == 0, "weak signal must never sign anyone out")
    }

    @Test
    func aDocumentKeyThatRefusesAFreshTokenKeepsTheSession() async throws {
        let fresh = freshJWT
        GLSessionEngine.mockAuthenticate = { GLSessionEngine.mockJwt = fresh }
        defer { reset() }
        var requests = 0
        let rig = try rig { request in
            requests += 1
            return try answer(request, status: 401)
        }

        await #expect(throws: GLSyncTransportError.documentKeyUnavailable) {
            _ = try await documents(rig).seal(Data("W-9".utf8))
        }
        #expect(rig.bell.rings == 0)
        #expect(requests == 2, "one refresh, one retry")
    }

    @Test
    func aDocumentKey401ThatStytchRefreshesSeals() async throws {
        let fresh = freshJWT
        GLSessionEngine.mockAuthenticate = { GLSessionEngine.mockJwt = fresh }
        defer { reset() }
        let key = Data(repeating: 7, count: GLSyncDocumentEnvelope.keyByteCount).base64EncodedString()
        let rig = try rig { request in
            let refreshed = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)"
            #expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/auth/document-key") == true)
            return try answer(request, status: refreshed ? 200 : 401,
                              body: refreshed ? #"{"key":"\#(key)","version":1}"# : "{}")
        }

        let crypto = documents(rig)
        let sealed = try await crypto.seal(Data("W-9".utf8))
        #expect(try await crypto.open(sealed.envelope) == Data("W-9".utf8))
        #expect(rig.bell.rings == 0)
    }

    @Test
    func aDocumentKeyWhoseSessionStytchRefusedSignsOut() async throws {
        GLSessionEngine.mockAuthenticate = {
            GLSessionEngine.mockJwt = nil
            throw URLError(.userAuthenticationRequired)
        }
        defer { reset() }
        let rig = try rig { request in try answer(request, status: 401) }

        await #expect(throws: GLSyncTransportError.signedOut) {
            _ = try await documents(rig).seal(Data("W-9".utf8))
        }
        #expect(rig.bell.rings == 1)
    }
}
