//
//  GLSyncTransportTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for GLSyncTransport: JSON value boxing/unboxing, error classifications,
//  refusal reasons, user copy localization, and response decoding.
//

import Testing
import Foundation
import GoldLifeCloud
@testable import GLSmallBusiness

struct GLSyncTransportTests {

    @Test func syncJSONValueConversions() {
        let nullVal = GLSyncJSONValue.from(nil)
        #expect(nullVal == .null)
        #expect(nullVal.displayText == "—")
        #expect(nullVal.payload == nil)

        let boolTrue = GLSyncJSONValue.from(true)
        #expect(boolTrue == .bool(true))
        #expect(boolTrue.displayText == "Yes")
        #expect(boolTrue.foundationValue as? Bool == true)

        let boolFalse = GLSyncJSONValue.from(false)
        #expect(boolFalse == .bool(false))
        #expect(boolFalse.displayText == "No")

        let intNum = GLSyncJSONValue.from(42)
        #expect(intNum == .number(42))
        #expect(intNum.displayText == "42")

        let doubleNum = GLSyncJSONValue.from(3.14)
        #expect(doubleNum == .number(3.14))
        #expect(doubleNum.displayText == "3.14")

        let strVal = GLSyncJSONValue.from("test")
        #expect(strVal == .string("test"))
        #expect(strVal.displayText == "test")

        let arrayVal = GLSyncJSONValue.from(["a", "b"])
        #expect(arrayVal == .array([.string("a"), .string("b")]))
        #expect(arrayVal.displayText == "a, b")

        let objVal = GLSyncJSONValue.from(["key": "val", "num": 10])
        #expect(objVal.displayText == "…")
        let payload = objVal.payload
        #expect(payload != nil)
        #expect(payload?["key"] as? String == "val")
    }

    @Test func syncRefusalReasonsAndMessages() {
        for reason in GLSyncRefusalReason.allCases {
            #expect(!reason.userMessage.isEmpty)
        }
    }

    @Test func syncTransportErrorsAndProperties() {
        let errors: [GLSyncTransportError] = [
            .signedOut,
            .unauthorized,
            .rateLimited(retryAfter: 30),
            .badRequest,
            .tooLarge,
            .notFound,
            .hashMismatch,
            .encryptionRequired,
            .documentKeyUnavailable,
            .subscriptionLapsed,
            .server(status: 500),
            .offline,
            .malformedResponse
        ]

        for err in errors {
            _ = err.isTransient
            _ = err.errorDescription
            _ = err.userMessage
        }

        #expect(GLSyncTransportError.offline.isTransient)
        #expect(GLSyncTransportError.server(status: 503).isTransient)
        #expect(!GLSyncTransportError.subscriptionLapsed.isTransient)
        #expect(!GLSyncTransportError.unauthorized.isTransient)
    }

    @Test func syncTransportErrorClassification() {
        let rateLimitedBody = """
        {"error": "rate_limited", "retry_after_seconds": 15}
        """.data(using: .utf8)!
        let err1 = GLSyncTransport.error(status: 429, retryAfter: 60, body: rateLimitedBody)
        if case .rateLimited(let sec) = err1 {
            #expect(sec == 15)
        } else {
            Issue.record("Expected rateLimited error")
        }

        let tooLargeBody = "{\"error\": \"payload_too_large\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 400, retryAfter: nil, body: tooLargeBody) == .tooLarge)

        let notFoundBody = "{\"error\": \"not_found\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 404, retryAfter: nil, body: notFoundBody) == .notFound)

        let hashBody = "{\"error\": \"hash_mismatch\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 400, retryAfter: nil, body: hashBody) == .hashMismatch)

        let encBody = "{\"error\": \"encryption_required\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 400, retryAfter: nil, body: encBody) == .encryptionRequired)

        let subLapsedBody = "{\"error\": \"subscription_lapsed\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 403, retryAfter: nil, body: subLapsedBody) == .subscriptionLapsed)

        let unauthBody = "{\"error\": \"unauthorized\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 401, retryAfter: nil, body: unauthBody) == .unauthorized)

        let badOpBody = "{\"error\": \"bad_op\"}".data(using: .utf8)!
        #expect(GLSyncTransport.error(status: 400, retryAfter: nil, body: badOpBody) == .badRequest)

        let emptyData = Data()
        #expect(GLSyncTransport.error(status: 401, retryAfter: nil, body: emptyData) == .unauthorized)
        #expect(GLSyncTransport.error(status: 404, retryAfter: nil, body: emptyData) == .notFound)
        #expect(GLSyncTransport.error(status: 413, retryAfter: nil, body: emptyData) == .tooLarge)
        #expect(GLSyncTransport.error(status: 400, retryAfter: nil, body: emptyData) == .badRequest)
        #expect(GLSyncTransport.error(status: 500, retryAfter: nil, body: emptyData) == .server(status: 500))
    }

    @Test func syncTransportDecoding() throws {
        let opID = UUID()
        let recordID = UUID()

        let syncResponseJSON: [String: Any] = [
            "new_cursor": 123,
            "results": [
                opID.uuidString: [
                    "status": "applied",
                    "version": 2,
                    "applied_fields": ["name"],
                    "lww_lost": [
                        ["field": "notes", "server_value": "remote notes"]
                    ],
                    "conflicts": [
                        ["field": "phone", "server_value": "555-1234", "server_version": 3]
                    ],
                    "reason": "bad_parent"
                ]
            ],
            "changes": [
                [
                    "id": recordID.uuidString,
                    "type": "customer",
                    "version": 1,
                    "seq": 10,
                    "deleted_at": 1700000000,
                    "payload": ["name": "Alice"]
                ]
            ]
        ]

        let response = try GLSyncTransport.decodeSync(syncResponseJSON)
        #expect(response.newCursor == 123)
        #expect(response.changes.count == 1)
        #expect(response.changes.first?.isTombstone == true)
        #expect(response.results[opID]?.status == .applied)
        #expect(response.results[opID]?.lwwLost.first?.field == "notes")
        #expect(response.results[opID]?.conflicts.first?.field == "phone")
        #expect(response.results[opID]?.reason == .badParent)

        // Snapshot page decoding
        let snapshotJSON: [String: Any] = [
            "oldest_seq": 5,
            "records": [
                [
                    "id": recordID.uuidString,
                    "type": "customer",
                    "version": 1,
                    "seq": 5,
                    "payload": ["name": "Alice"]
                ]
            ]
        ]
        let page = try GLSyncTransport.decodeSnapshot(snapshotJSON)
        #expect(page.oldestSeq == 5)
        #expect(page.records.count == 1)

        // Checksums decoding
        let checksumsJSON: [String: Any] = [
            "tombstones": 3,
            "types": [
                "customer": [
                    "count": 10,
                    "max_seq": 45
                ]
            ]
        ]
        let checksums = try GLSyncTransport.decodeChecksums(checksumsJSON)
        #expect(checksums.tombstones == 3)
        #expect(checksums.types["customer"]?.count == 10)
        #expect(checksums.types["customer"]?.maxSeq == 45)

        // Malformed responses throw
        #expect(throws: GLSyncTransportError.self) {
            _ = try GLSyncTransport.decodeSync(["invalid": true])
        }
        #expect(throws: GLSyncTransportError.self) {
            _ = try GLSyncTransport.decodeSnapshot(["invalid": true])
        }
        #expect(throws: GLSyncTransportError.self) {
            _ = try GLSyncTransport.decodeChecksums(["invalid": true])
        }
    }
}

// MARK: - The Worker's own words reach the client (QA 2026-10-03 F57)

/// Through GoldLifeCloud's real dispatch, not the static mapper. The mapper always knew
/// `subscription_lapsed`; the request path threw the body away before the mapper saw it, so a
/// lapsed upload read as a transient `.server(403)` and took the whole push down with it.
@MainActor
@Suite(.serialized)
struct GLSyncTransportEnvelopeTests {

    private static func transport(_ server: GLSyncStubServer) -> GLSyncTransport {
        let cloud = server.cloud()
        return GLSyncTransport(tokens: server.tokens(cloud), cloud: cloud)
    }

    @Test func aLapsed403FromAttachmentsReachesTheCallerWithItsReason() async throws {
        let server = GLSyncStubServer(lapsed: true)
        server.install()
        defer { GLSyncStubServer.uninstall() }

        do {
            try await Self.transport(server).uploadAttachment(
                bytes: Data("receipt".utf8), sha256: glSyncSHA256(Data("receipt".utf8)),
                name: "receipt.jpg", piiClass: .normal, encrypted: false)
            Issue.record("a lapsed upload was accepted")
        } catch let error as GLSyncTransportError {
            #expect(error == .subscriptionLapsed, """
                the Worker answered 403 {"error":"subscription_lapsed"} and the client read \(error) \
                — the envelope was dropped on the way in
                """)
            #expect(!error.isTransient, "a lapse retried as transient aborts every push")
        }
        #expect(server.paths.contains { $0.hasSuffix("/attachments") },
                "precondition: the upload must have reached the server")
    }

    /// A conflict status is the server speaking, not the phone being offline.
    @Test func a409IsTheServersAnswerNotOffline() async throws {
        let server = GLSyncStubServer(lapsed: false)
        server.override("/checksums", with: .init(status: 409, body: #"{"error":"busy"}"#))
        server.install()
        defer { GLSyncStubServer.uninstall() }

        do {
            _ = try await Self.transport(server).checksums()
            Issue.record("a 409 was read as success")
        } catch let error as GLSyncTransportError {
            #expect(error == .server(status: 409), "a 409 was read as \(error)")
        }
    }

    /// The back-off the Worker asks for survives the trip, whatever case Cloudflare sends the
    /// header name in.
    @Test func a429KeepsItsRetryAfter() async throws {
        let server = GLSyncStubServer(lapsed: false)
        server.override("/checksums", with: .init(status: 429, body: "{}",
                                                  headers: ["retry-after": "7"]))
        server.install()
        defer { GLSyncStubServer.uninstall() }

        do {
            _ = try await Self.transport(server).checksums()
            Issue.record("a 429 was read as success")
        } catch let error as GLSyncTransportError {
            #expect(error == .rateLimited(retryAfter: 7), "a 429 was read as \(error)")
        }
    }
}
