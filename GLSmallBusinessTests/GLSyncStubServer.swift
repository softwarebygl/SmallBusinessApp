//
//  GLSyncStubServer.swift
//  GLSmallBusinessTests
//
//  gl-business-api and the app-token mint, answered in memory (QA 2026-10-03 C22). Requests
//  reach it through GoldLifeCloud's real dispatch over a stub URL session, so a test sees what
//  the transport and the engine do with a real HTTP status and a real error envelope, not
//  what the static mapper does with a body the test typed in by hand.
//
//  Suites that use it are `.serialized`: the handler is one static, and the mint reads
//  GoldLifeCloud's static mock session (`GLSessionEngine.mockJwt`).
//

import Foundation
import SwiftData
import GoldLifeCloud
@testable import GLSmallBusiness

/// Answers every request from `GLSyncStubServer.current`; nothing reaches the network.
final class GLSyncStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = GLSyncStubServer.current, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply = server.handle(request, body: Self.body(of: request))
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                             headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol its upload body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The server's half. Lapsed refuses every write the way the Worker does (README "Subscription
/// entitlement"): `/attachments` answers 403 `{"error":"subscription_lapsed"}`, and every `/sync`
/// op comes back `refused: subscription_lapsed`, uncached, so the same op id can go through later.
nonisolated final class GLSyncStubServer: @unchecked Sendable {

    nonisolated struct Reply: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var current: GLSyncStubServer?

    private let lock = NSLock()
    private var _lapsed: Bool
    private var _snapshotStatus = 200
    private var _paths: [String] = []
    private var _syncedOpIDs: [[String]] = []
    private var _mints = 0
    /// A canned answer for one path suffix, ahead of everything else.
    private var _overrides: [String: Reply] = [:]

    init(lapsed: Bool) { _lapsed = lapsed }

    var lapsed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _lapsed }
        set { lock.lock(); _lapsed = newValue; lock.unlock() }
    }
    var snapshotStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return _snapshotStatus }
        set { lock.lock(); _snapshotStatus = newValue; lock.unlock() }
    }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    /// The op ids of every `/sync` request, one array per request.
    var syncedOpIDs: [[String]] { lock.lock(); defer { lock.unlock() }; return _syncedOpIDs }
    var mints: Int { lock.lock(); defer { lock.unlock() }; return _mints }

    func override(_ suffix: String, with reply: Reply) {
        lock.lock(); _overrides[suffix] = reply; lock.unlock()
    }

    // MARK: Identities

    /// A JWT-shaped string whose payload carries `sub` (the provider reads it unverified).
    static func jwt(sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    static let session = jwt(sub: "stytch-session-stub")
    static let appToken = jwt(sub: "glid-stub")

    // MARK: Wiring

    /// GoldLifeCloud's real dispatch over the stub session.
    func cloud() -> GLCloudTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GLSyncStubProtocol.self]
        return GLCloudTransport(session: URLSession(configuration: config),
                                sessionEngine: GLSessionEngine())
    }

    /// A signed-in token provider over `cloud`.
    func tokens(_ cloud: GLCloudTransport) -> GLSyncTokenProvider {
        GLSyncTokenProvider(transport: cloud, storedSessionJWT: { Self.session },
                            onSessionExpired: {})
    }

    /// Installs this server and the signed-in mock session. Pair with `uninstall()`.
    @MainActor
    func install() {
        Self.current = self
        GLSessionEngine.mockJwt = Self.session
    }

    @MainActor
    static func uninstall() {
        current = nil
        GLSessionEngine.mockJwt = nil
    }

    @MainActor
    func engine(_ container: ModelContainer) -> GLSyncEngine {
        let cloud = cloud()
        return GLSyncEngine(
            container: container,
            tokens: tokens(cloud),
            cloud: cloud,
            documents: GLSyncDocumentCrypto(transport: cloud, storedSessionJWT: { Self.session },
                                            onSessionExpired: {}))
    }

    // MARK: Answers

    func handle(_ request: URLRequest, body: Data) -> Reply {
        let path = request.url?.path ?? ""
        lock.lock()
        _paths.append(path)
        let lapsed = _lapsed
        let snapshotStatus = _snapshotStatus
        let canned = _overrides.first { path.hasSuffix($0.key) }?.value
        lock.unlock()

        if let canned { return canned }
        if path.hasSuffix("auth/app-token") {
            lock.lock(); _mints += 1; lock.unlock()
            return Reply(status: 200, body: #"{"token":"\#(Self.appToken)","expires_in":900}"#)
        }
        if path.hasSuffix("/snapshot") {
            guard snapshotStatus == 200 else {
                return Reply(status: snapshotStatus, body: #"{"error":"internal"}"#)
            }
            return Reply(status: 200, body: #"{"records":[]}"#)
        }
        if path.hasSuffix("/attachments") {
            return lapsed
                ? Reply(status: 403, body: #"{"error":"subscription_lapsed"}"#)
                : Reply(status: 200, body: #"{"id":"stub-blob"}"#)
        }
        if path.hasSuffix("/sync") {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let ops = (object?["ops"] as? [[String: Any]]) ?? []
            let ids = ops.compactMap { $0["op_id"] as? String }
            lock.lock(); _syncedOpIDs.append(ids); lock.unlock()
            var results: [String: Any] = [:]
            for id in ids {
                results[id] = lapsed
                    ? ["status": "refused", "reason": "subscription_lapsed"]
                    : ["status": "applied", "version": 1]
            }
            let reply: [String: Any] = ["results": results, "changes": [], "new_cursor": 1]
            let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            return Reply(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        if path.hasSuffix("/checksums") {
            return Reply(status: 200, body: #"{"types":{"customer":{"count":1,"max_seq":1}},"tombstones":0}"#)
        }
        return Reply(status: 404, body: #"{"error":"not_found"}"#)
    }
}
