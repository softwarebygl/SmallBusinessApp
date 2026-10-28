//
//  GLSyncTransport.swift
//  GLSmallBusiness
//
//  The five calls GLSync makes against gl-business-api, and the typed shapes on either side
//  of them. Contract: gl-business-api/README.md §3 and gl-business-api/src/types.ts — the
//  structs below mirror those declarations field for field, so a drift on the Worker shows
//  up here as a decode failure rather than as a quietly-missing value.
//
//    POST /sync                   the one round trip: push ops, pull past the cursor
//    GET  /snapshot?after=&limit=  paged full state (bootstrap + self-heal)
//    GET  /checksums              per-type {count, max_seq} drift check
//    POST /attachments            content-addressed blob upload
//    GET  /attachments/{sha256}   blob download
//
//  Decoding is JSONSerialization, not Codable, for one reason that runs through the whole
//  protocol: a record `payload` and a conflict's `server_value` are arbitrary JSON by design
//  (payloads are additive — a newer build's field must ride through an older one untouched).
//  `GLSyncJSONValue` boxes that arbitrary JSON into something `Sendable`, which is what lets
//  a pulled row cross from the engine's actor to the MainActor where SwiftData lives.
//
//  ERROR COPY. Every failure that a person could ever see carries a plain-English sentence
//  with a realistic next step (the app's error-copy rule). Three deliberate silences:
//  `rate_limited` has NO user message at all — it is a quiet retry, never a banner —
//  `signedOut` is a STATE, not a failure (GLSYNC-SPEC.md §4: the app stays fully usable), and
//  `documentKeyUnavailable` is a quiet wait, because the document simply syncs on a later
//  cycle and nothing about the person's work is at risk.
//
//  ONE CALL LIVES ELSEWHERE. `GET /auth/document-key` is on gl-money-api (the identity
//  service) and authenticates with the Gold Life ID SESSION, not with the app token every
//  call here carries, so it belongs to GLSyncDocumentCrypto — which also owns the envelope
//  format that `tax`-class blobs are uploaded in. This file only carries the shared error
//  vocabulary the two agree on.
//

import Foundation
import GoldLifeCloud

// MARK: - Arbitrary JSON, made Sendable

/// A JSON value that can cross an isolation boundary. `[String: Any]` cannot, and the wire
/// protocol is full of genuinely-any values: record payloads, `server_value` in a conflict,
/// `old_value` in an LWW loss.
///
/// Numbers are normalized to `Double` on the way in and handed back as `Double` on the way
/// out, which is exactly what `GLSyncValue`'s read helpers expect (`optionalDouble` accepts
/// either, `int` falls through to the Double branch). Booleans are separated from numbers
/// explicitly — `JSONSerialization` returns both as `NSNumber`, and letting `true` decode as
/// `1` would turn every `Bool` field into a silent `false` on the way back.
nonisolated enum GLSyncJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([GLSyncJSONValue])
    indirect case object([String: GLSyncJSONValue])

    static func from(_ any: Any?) -> GLSyncJSONValue {
        guard let any, !(any is NSNull) else { return .null }
        if let number = any as? NSNumber {
            // CFBooleanGetTypeID is the only reliable Bool/Number split for a bridged
            // NSNumber: `as? Bool` succeeds for 0 and 1 too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = any as? String { return .string(text) }
        if let list = any as? [Any] { return .array(list.map { GLSyncJSONValue.from($0) }) }
        if let dictionary = any as? [String: Any] {
            return .object(dictionary.mapValues { GLSyncJSONValue.from($0) })
        }
        // Not reachable from JSONSerialization output. Null rather than a trap: an
        // unrepresentable value must not take a whole pull down with it.
        return .null
    }

    /// Back to the `Any` graph `GLSyncValue` and `JSONSerialization` speak.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }

    /// The payload dictionary a mapper's `glSyncApply` takes, or nil if this is not an object.
    var payload: GLSyncPayload? {
        guard case .object(let values) = self else { return nil }
        return values.mapValues(\.foundationValue)
    }

    /// For "Recent changes" and conflict badges — a short, human rendering. Never used for
    /// anything the app computes with.
    var displayText: String {
        switch self {
        case .null: return "—"
        case .bool(let value): return value ? "Yes" : "No"
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array(let values): return values.map(\.displayText).joined(separator: ", ")
        case .object: return "…"
        }
    }
}

// MARK: - Wire shapes (gl-business-api/src/types.ts)

/// One server record row. `deletedAt != nil` is a tombstone — the row still arrives so a
/// device learns about the delete; the payload of an old tombstone may be scrubbed.
nonisolated struct GLSyncRecordRow: Sendable {
    let id: UUID
    let type: String
    let parentID: UUID?
    let version: Int
    let seq: Int
    /// Unix milliseconds, nil for a live row.
    let deletedAt: Int?
    let payload: GLSyncJSONValue

    var isTombstone: Bool { deletedAt != nil }
}

nonisolated struct GLSyncFieldConflict: Sendable {
    let field: String
    let serverValue: GLSyncJSONValue
    let serverVersion: Int
}

nonisolated struct GLSyncFieldLoss: Sendable {
    let field: String
    /// The value that WON. The client's own value lost, and reads this back.
    let serverValue: GLSyncJSONValue
}

nonisolated enum GLSyncOpStatus: String, Sendable {
    case applied, conflict, refused, cached
}

/// The machine reasons the Worker refuses an op with. Every one carries a sentence a person
/// can act on — `refused` is the only per-op status that reaches the user as words.
///
/// `CaseIterable` so the localization regression net has a CLOSED denominator: a reason added
/// later without a Spanish translation fails the test instead of quietly shipping English.
nonisolated enum GLSyncRefusalReason: String, Sendable, CaseIterable {
    case appendOnly = "append_only"
    case paidLocked = "paid_locked"
    case illegalTransition = "illegal_transition"
    case badParent = "bad_parent"
    case unknownType = "unknown_type"
    case badOp = "bad_op"
    case singletonExists = "singleton_exists"
    case writeOnce = "write_once"
    case deleted = "deleted"
    /// The subscription lapsed, so the Worker refuses every pushed op (owner ruling
    /// 2026-08-25 — a lapsed account is 100% read-only; gl-business-api README
    /// "Subscription entitlement"). The ONLY reason here that is not a verdict on the
    /// record: nothing is wrong with what they typed, and it becomes writable again the
    /// moment they renew. Its absence was a live bug — nine cases and none of them
    /// matched the server's most common refusal, so the person was shown
    /// `unknownType`'s "Updating the app should fix it", which is advice that cannot
    /// work and sends them to the App Store instead of to their subscription.
    case subscriptionLapsed = "subscription_lapsed"

    /// `MBLocalization.string`, not `mbLoc`: this enum is `nonisolated` (the actor engine reads
    /// it off the main actor), so it cannot hop to the MainActor helper. Same catalog, same
    /// in-app language choice — see `StripeBackendClient`'s error vocabulary for the precedent.
    /// Plain literals here were the bug: they are never extracted, so a Spanish reader got
    /// English and the in-app language switch could not reach them.
    var userMessage: String {
        switch self {
        case .paidLocked:
            // GLSYNC-SPEC.md §5's sentence, re-scoped 2026-08-23. The old wording ("This invoice
            // is already paid — add a change order instead.") was written when only an INVOICE op
            // could earn this reason. The same day's second ruling made the Worker refuse a
            // CUSTOMER delete whose subtree holds a paid invoice (`paidInvoiceInSubtree`), so
            // invoice-only copy is now false on a path that really happens: someone deletes a
            // customer and is told to add a change order, which cannot delete anybody. This
            // names both locks and keeps the one real next step. See PaidInvoiceLock.swift.
            return MBLocalization.string(
                "A paid invoice can’t be changed or deleted, and neither can the customer it belongs to. Add a change order to correct it.")
        case .appendOnly:
            return MBLocalization.string(
                "Payments can't be edited. Record a correcting payment instead.")
        case .illegalTransition:
            return MBLocalization.string(
                "That status change didn't stick. Reopen the record and set it again.")
        case .badParent:
            return MBLocalization.string(
                "This is attached to something that no longer exists.")
        case .deleted:
            return MBLocalization.string(
                "This was deleted on another device, so the change wasn't saved.")
        case .singletonExists:
            return MBLocalization.string(
                "Your business details were already set up. The existing ones were kept.")
        case .writeOnce:
            return MBLocalization.string(
                "That value can only be set once and can't be changed.")
        case .subscriptionLapsed:
            // Names the cause, says where the work IS, and gives the one action that
            // changes the answer. No urgency, no pricing, no discount — the Gold Life
            // rule is degrade, never punish: their records are all still here and still
            // readable, and this sentence has to sound like that is true.
            return MBLocalization.string(
                "Your subscription ended, so this change didn’t back up. It’s still saved here — reactivate to start syncing again.")
        case .unknownType, .badOp:
            // A client/server contract break, not anything the user did or can fix.
            return MBLocalization.string(
                "Something didn't sync. Updating the app should fix it.")
        }
    }
}

nonisolated struct GLSyncOpResult: Sendable {
    let status: GLSyncOpStatus
    let version: Int?
    let appliedFields: [String]
    let lwwLost: [GLSyncFieldLoss]
    let conflicts: [GLSyncFieldConflict]
    let reason: GLSyncRefusalReason?
    /// Returned on `singleton_exists` / `deleted` / delete conflicts.
    let head: GLSyncRecordRow?
}

nonisolated struct GLSyncSyncResponse: Sendable {
    /// Keyed by op id. An op MISSING from this map was not judged — the engine must leave
    /// its outbox row alone rather than assume success.
    let results: [UUID: GLSyncOpResult]
    let changes: [GLSyncRecordRow]
    let newCursor: Int
}

nonisolated struct GLSyncSnapshotPage: Sendable {
    let records: [GLSyncRecordRow]
    /// MIN(seq) of live rows. A cursor older than this means the tombstone window has
    /// closed on us and incremental catch-up can no longer be trusted — full resync.
    let oldestSeq: Int?
}

nonisolated struct GLSyncChecksums: Sendable {
    nonisolated struct Entry: Sendable, Equatable {
        let count: Int
        let maxSeq: Int
    }
    /// Keyed by manifest type. Live rows only.
    let types: [String: Entry]
    let tombstones: Int
}

/// What `/attachments` is told about a blob. `tax` objects MUST arrive client-encrypted or
/// the Worker refuses them (`encryption_required`) — GLSyncDocumentCrypto seals those.
nonisolated enum GLSyncPIIClass: String, Sendable {
    case normal
    case tax
}

// MARK: - Errors

/// Every way a call can fail, with the words the user would see. `userMessage == nil` means
/// "never show this" — the engine logs it and retries.
nonisolated enum GLSyncTransportError: LocalizedError, Sendable, Equatable {
    /// No Gold Life ID session. NOT a failure: the app is fully usable local-only
    /// (GLSYNC-SPEC.md §4). The engine turns this into its `.signedOut` state.
    case signedOut
    /// A 401 that survived one token refresh — the credential is rejected, not merely stale.
    case unauthorized
    /// 429. Quiet by contract: the engine backs off for `retryAfter` and says nothing.
    case rateLimited(retryAfter: TimeInterval)
    /// 400 `bad_body` / `bad_op` — a client bug, not a user mistake.
    case badRequest
    /// 413. Only reachable from `/attachments` (25 MB cap).
    case tooLarge
    case notFound
    /// The bytes did not hash to the sha256 we declared — a corrupted read on this device.
    case hashMismatch
    /// A `tax`-class attachment was offered without client encryption. Unreachable by
    /// construction — `uploadAttachment` refuses that combination before the request, and the
    /// engine seals every tax blob — so reaching it means a client bug, not a user situation.
    case encryptionRequired
    /// The identity service could not hand over the document key: its master secret is not
    /// set yet (503 `document_key_unconfigured`), or it was briefly unreachable. Quiet and
    /// transient — the tax document waits in the outbox and goes up on a later cycle. It is
    /// NEVER a licence to upload that document in the clear.
    case documentKeyUnavailable
    /// 403 `subscription_lapsed` — the token is valid and the account simply may not
    /// write (gl-business-api `POST /attachments`, `GET /account/export`). PERMANENT
    /// until the person renews, which is why it is a case of its own: routed to
    /// `.server(status: 403)` it was classified TRANSIENT, so the upload retried on
    /// every cycle forever AND threw out of `uploadBlobs`, aborting a push whose other
    /// ops had nothing to do with any attachment.
    case subscriptionLapsed
    /// 5xx, or any status the contract does not name.
    case server(status: Int)
    /// The device is offline / the request timed out. Normal on a job site.
    case offline
    /// The response parsed as JSON but not as the shape the contract promises.
    case malformedResponse

    /// `MBLocalization.string` for the same reason `GLSyncRefusalReason` uses it: this enum is
    /// `nonisolated`, so it cannot reach the MainActor `mbLoc`. Plain literals here would read
    /// English to a Spanish user and ignore the in-app language switch.
    var userMessage: String? {
        switch self {
        case .signedOut, .rateLimited, .documentKeyUnavailable:
            return nil
        case .unauthorized:
            return MBLocalization.string("Sign in again to keep syncing.")
        case .offline:
            return MBLocalization.string(
                "You're offline. Your work is saved here and will sync when you reconnect.")
        case .tooLarge:
            return MBLocalization.string(
                "That file is too large to back up. Files must be under 25 MB.")
        case .subscriptionLapsed:
            // ONE sentence for one machine word: the server answers `subscription_lapsed`
            // on both channels (the per-op /sync reason and this endpoint's error
            // envelope), so the person reads the same words whether it was a record or a
            // document that did not go up. Read from the reason rather than copied, so
            // the two can never drift and the catalog holds one key, not two.
            return GLSyncRefusalReason.subscriptionLapsed.userMessage
        case .badRequest, .notFound, .hashMismatch, .encryptionRequired, .server, .malformedResponse:
            return MBLocalization.string(
                "Syncing didn't finish. Your work is saved on this device and we'll try again.")
        }
    }

    var errorDescription: String? { userMessage }

    /// Whether another attempt in a few minutes could plausibly work. A `badRequest` cannot,
    /// so retrying it forever would only burn the rate bucket.
    var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .server, .documentKeyUnavailable: return true
        // `subscriptionLapsed` is false for a different reason than the rest: the others
        // can never succeed, this one cannot succeed UNTIL THE PERSON ACTS. Same answer
        // to "retry in a few minutes?" — no — and the same handling, which is what
        // matters: a refusal retried on a loop burns the rate bucket and re-asks a
        // question only a renewal can answer.
        case .signedOut, .unauthorized, .badRequest, .tooLarge, .notFound, .subscriptionLapsed,
             .hashMismatch, .encryptionRequired, .malformedResponse: return false
        }
    }
}

// MARK: - Transport

nonisolated struct GLSyncTransport: Sendable {

    /// The deployed Worker. Public URL, no credential in it — every call authenticates with
    /// the caller's own 15-minute Gold Life ID app token. Optional, never force-unwrapped
    /// (anti-crash mandate): without it a call fails as `.offline`, the backup's ordinary
    /// "can't reach it right now", instead of trapping.
    static let baseURL = URL(string: "https://backend.softwarebygl.com/cloud")

    /// 25 MB, matching `attachments.ts` MAX_BYTES. Checked here so a doomed upload never
    /// leaves the device.
    static let attachmentByteLimit = 25 * 1024 * 1024

    let tokens: GLSyncTokenProvider
    /// The one road out (law 59). A test hands in a transport over a stub session.
    let cloud: GLCloudTransport
    /// The sync cycle this transport works for, or nil for a one-shot caller (account
    /// deletion). Bound, every request carries a token for the cycle's own person or does not
    /// go out at all (QA 2026-10-03 F18): a cycle still running when its person signs out and
    /// somebody else signs in throws `.signedOut` instead of re-minting for the new session and
    /// pushing the old person's records into the new person's account.
    private(set) var binding: GLSyncCycleBinding?

    init(tokens: GLSyncTokenProvider, cloud: GLCloudTransport = .shared) {
        self.tokens = tokens
        self.cloud = cloud
    }

    /// This transport, answering only to `binding`'s person.
    func bound(to binding: GLSyncCycleBinding) -> GLSyncTransport {
        var copy = self
        copy.binding = binding
        return copy
    }

    // MARK: Endpoints

    /// The one round trip. `ops` must already be chunked to ≤50 by the caller (the Worker
    /// hard-caps at 200 with `bad_body`).
    func sync(deviceID: UUID, cursor: Int, ops: [GLSyncPendingOp]) async throws -> GLSyncSyncResponse {
        let body: [String: Any] = [
            "device_id": deviceID.uuidString.lowercased(),
            "cursor": cursor,
            "ops": ops.map(Self.opBody),
        ]
        let json = try await perform(path: "/sync", method: "POST", jsonBody: body)
        return try Self.decodeSync(json)
    }

    /// One bootstrap page. The paging contract: pass the last row's `seq` back as `after`
    /// and keep going until a page comes back short.
    func snapshot(after seq: Int, limit: Int) async throws -> GLSyncSnapshotPage {
        let json = try await perform(
            path: "/snapshot",
            method: "GET",
            query: [URLQueryItem(name: "after", value: String(seq)),
                    URLQueryItem(name: "limit", value: String(limit))])
        return try Self.decodeSnapshot(json)
    }

    func checksums() async throws -> GLSyncChecksums {
        let json = try await perform(path: "/checksums", method: "GET")
        return try Self.decodeChecksums(json)
    }

    /// Erase everything the sync backend holds for this account.
    ///
    /// Called as the FIRST step of deleting a Gold Life ID, never after. Once the identity is
    /// gone this device can no longer mint a token for this account, so these records could
    /// never be reached — or deleted — again. Deleting the business data first means the worst
    /// case is an account that still exists with nothing in it, which the user can simply
    /// delete again; the reverse would strand a business's books in a database forever.
    ///
    /// Idempotent by construction: a second call finds nothing and still answers 200.
    func deleteAccountData() async throws {
        _ = try await perform(path: "/account", method: "DELETE")
    }

    /// Upload blob bytes. Content-addressed and deduped server-side, so re-uploading an
    /// unchanged logo costs one round trip and no storage.
    ///
    /// `sha256` must be the hash of `bytes` — of exactly what is being sent, not of what it
    /// was made from. The Worker recomputes the digest over the body it received and refuses
    /// a mismatch (`hash_mismatch`), because the key `blobs/{sha256}` is a promise every
    /// account referencing that hash relies on. For an ENCRYPTED document that means the hash
    /// of the envelope, and the payload reference has to carry the same one or the download
    /// asks for a blob that was never stored.
    @discardableResult
    func uploadAttachment(
        bytes: Data,
        sha256: String,
        name: String,
        piiClass: GLSyncPIIClass,
        encrypted: Bool
    ) async throws -> String {
        guard !bytes.isEmpty else { throw GLSyncTransportError.badRequest }
        guard bytes.count <= Self.attachmentByteLimit else { throw GLSyncTransportError.tooLarge }
        // The Worker refuses this combination; failing here saves the round trip AND keeps a
        // plaintext tax document from ever leaving the device on a hopeful attempt.
        guard piiClass != .tax || encrypted else { throw GLSyncTransportError.encryptionRequired }

        let json = try await perform(
            path: "/attachments",
            method: "POST",
            rawBody: bytes,
            headers: [
                "x-sha256": sha256,
                // The Worker truncates, but a header with a newline in it is a malformed
                // request — filenames come from the user, so they are sanitized here.
                "x-name": Self.headerSafe(name),
                "x-pii-class": piiClass.rawValue,
                "x-encrypted": encrypted ? "1" : "0",
                "Content-Type": "application/octet-stream",
            ])
        guard let object = json as? [String: Any], let id = object["id"] as? String else {
            throw GLSyncTransportError.malformedResponse
        }
        return id
    }

    /// Fetch blob bytes by hash. Owner-scoped: a hash this account has no metadata row for
    /// answers 404, never someone else's file.
    func downloadAttachment(sha256: String) async throws -> Data {
        try await performRaw(path: "/attachments/" + sha256, method: "GET")
    }

    // MARK: - Request plumbing

    /// Body shape per README §3. `patch` is re-parsed from its JSON text here — see
    /// `GLSyncPendingOp` for why it travels as text.
    private static func opBody(_ op: GLSyncPendingOp) -> [String: Any] {
        let patch = (op.patchJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        var body: [String: Any] = [
            "op_id": op.opID.uuidString.lowercased(),
            "id": op.recordID.uuidString.lowercased(),
            "type": op.recordType,
            "parent_id": op.parentID.map { $0.uuidString.lowercased() } ?? NSNull(),
            "base_version": op.baseVersion,
            "client_ts": op.clientTS,
            "schema_version": 1,
        ]
        if op.isDelete {
            body["delete"] = true
            body["cascade"] = op.cascade.map { $0.uuidString.lowercased() }
        } else {
            body["patch"] = patch
        }
        return body
    }

    /// One authenticated call, returning parsed JSON. The token dance lives here so no
    /// endpoint has to remember it: a 401 refreshes the app token ONCE and retries; a second
    /// 401 is a real rejection and surfaces "Sign in again to keep syncing."
    private func perform(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Any {
        let data = try await performRaw(
            path: path, method: method, query: query,
            jsonBody: jsonBody, rawBody: rawBody, headers: headers)
        // A 200 with an empty body is not something this contract produces; treating it as
        // an empty object would let a truncated response read as "nothing changed".
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw GLSyncTransportError.malformedResponse
        }
        return json
    }

    private func performRaw(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {

        var body = rawBody
        if let jsonBody {
            guard let encoded = try? JSONSerialization.data(withJSONObject: jsonBody) else {
                throw GLSyncTransportError.badRequest
            }
            body = encoded
        }

        let token = try await currentToken(forcingRefresh: false)

        var (data, status, retryAfter) = try await send(
            path: path, method: method, query: query, body: body,
            headers: headers, token: token, isJSONBody: jsonBody != nil)

        if status == 401 {
            // The app token is 15 minutes and refreshed at T-2min, so this is rare — a
            // device asleep past its own refresh window, or a key rotation.
            let refreshed = try await currentToken(forcingRefresh: true)
            (data, status, retryAfter) = try await send(
                path: path, method: method, query: query, body: body,
                headers: headers, token: refreshed, isJSONBody: jsonBody != nil)
            if status == 401 { throw GLSyncTransportError.unauthorized }
        }

        guard (200..<300).contains(status) else {
            throw Self.error(status: status, retryAfter: retryAfter, body: data)
        }
        return data
    }

    /// The token for the next request, or `.signedOut`. Bound, the token's subject must be the
    /// cycle's owner: the provider already refuses a different SESSION before minting, and this
    /// catches the rest (a session that changed while the mint was on the wire).
    private func currentToken(forcingRefresh: Bool) async throws -> String {
        guard case .token(let token, let subject) = try await tokens.token(
                forcingRefresh: forcingRefresh, boundTo: binding),
              binding.map({ $0.owner == subject }) ?? true else {
            throw GLSyncTransportError.signedOut
        }
        return token
    }

    private func send(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        headers: [String: String],
        token: String,
        isJSONBody: Bool
    ) async throws -> (Data, Int, TimeInterval?) {
        guard let baseURL = Self.baseURL else { throw GLSyncTransportError.offline }
        var mergedHeaders = headers
        if isJSONBody { mergedHeaders["Content-Type"] = "application/json" }
        mergedHeaders["Authorization"] = "Bearer " + token

        let cloudRequest = GLCloudRequest(
            target: .custom(baseURL),
            path: path,
            method: method,
            queryItems: query,
            headers: mergedHeaders,
            body: body,
            authMode: .none,
            // Every status comes back as an answer, body included (QA 2026-10-03 F57). With
            // GoldLifeCloud validating, a non-2xx threw before this code saw the body, so the
            // Worker's `{error: "<word>"}` envelope never reached `Self.error`: a lapsed upload
            // read as a transient `.server(403)` and aborted every push, and a 409 read as
            // offline. `performRaw` judges the status; `Self.error` reads the word.
            validateStatus: false
        )

        do {
            let response = try await cloud.dispatch(cloudRequest)
            return (response.data, response.statusCode, Self.retryAfter(in: response.headers))
        } catch let error as GLCloudError {
            switch error {
            case .offline:
                throw GLSyncTransportError.offline
            case .badStatus(let code, _):
                // With validation off, only the connection itself lands here: a timeout (408)
                // or a dropped connection (0). No server spoke, so there is no body to keep.
                return (Data(), code, nil)
            case .rateLimited(let retryAfter):
                return (Data(), 429, retryAfter)
            default:
                throw GLSyncTransportError.offline
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GLSyncTransportError.offline
        }
    }

    /// Status + the `{error: "<machine_snake_case>"}` envelope → a typed error. The envelope
    /// is authoritative where it disagrees with the status, because the Worker names the
    /// same 400 several different ways.
    ///
    /// Internal rather than private for the same reason the decoders below are: this table is
    /// the client's whole understanding of the Worker's error vocabulary, and a word that
    /// falls through it lands on `.server` — which is TRANSIENT, and therefore retried
    /// forever. That is not a hypothetical: `subscription_lapsed` fell through exactly here.
    /// A table that decides retry behaviour needs a test that can read it.
    static func error(status: Int, retryAfter: TimeInterval?, body: Data) -> GLSyncTransportError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = object?["error"] as? String
        switch code {
        case "rate_limited":
            let seconds = (object?["retry_after_seconds"] as? Double) ?? retryAfter ?? 60
            return .rateLimited(retryAfter: seconds)
        case "payload_too_large": return .tooLarge
        case "not_found": return .notFound
        case "hash_mismatch": return .hashMismatch
        case "encryption_required": return .encryptionRequired
        // The envelope, not the status: 403 alone would fall through to `.server`, which
        // is transient. The Worker sends this exact word from every surface a lapsed
        // account may not use (README "Subscription entitlement"), so ONE case here
        // covers the attachment upload and the account export alike.
        case "subscription_lapsed": return .subscriptionLapsed
        case "unauthorized": return .unauthorized
        case "bad_body", "bad_op": return .badRequest
        default: break
        }
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: retryAfter ?? 60)
        case 400: return .badRequest
        default: return .server(status: status)
        }
    }

    /// `Retry-After` in seconds, whatever the case of its name: Cloudflare over HTTP/2 sends
    /// header names lowercase, and an exact-case lookup lost the Worker's back-off.
    static func retryAfter(in headers: [String: String]) -> TimeInterval? {
        headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
            .flatMap { TimeInterval($0.value.trimmingCharacters(in: .whitespaces)) }
    }

    /// Header values are latin-1 on the wire and must not carry control characters. A
    /// filename is user-typed, so it gets stripped rather than trusted.
    private static func headerSafe(_ value: String) -> String {
        let cleaned = value.unicodeScalars
            .filter { $0.value >= 32 && $0.value < 127 }
            .map(String.init)
            .joined()
        return String(cleaned.prefix(200))
    }
}

// MARK: - Decoding
//
// Hand-written against types.ts. Every field the client ACTS on is required; every field it
// only displays degrades. A row missing its `id` or `type` is dropped rather than guessed,
// because a row the client cannot name is a row it cannot safely write anywhere.

extension GLSyncTransport {

    nonisolated static func decodeSync(_ json: Any) throws -> GLSyncSyncResponse {
        guard let object = json as? [String: Any],
              let rawResults = object["results"] as? [String: Any],
              let cursor = (object["new_cursor"] as? NSNumber)?.intValue else {
            throw GLSyncTransportError.malformedResponse
        }
        var results: [UUID: GLSyncOpResult] = [:]
        for (key, value) in rawResults {
            guard let opID = UUID(uuidString: key),
                  let result = decodeOpResult(value) else { continue }
            results[opID] = result
        }
        let changes = (object["changes"] as? [Any] ?? []).compactMap(decodeRow)
        return GLSyncSyncResponse(results: results, changes: changes, newCursor: cursor)
    }

    nonisolated static func decodeSnapshot(_ json: Any) throws -> GLSyncSnapshotPage {
        guard let object = json as? [String: Any],
              let raw = object["records"] as? [Any] else {
            throw GLSyncTransportError.malformedResponse
        }
        return GLSyncSnapshotPage(
            records: raw.compactMap(decodeRow),
            oldestSeq: (object["oldest_seq"] as? NSNumber)?.intValue)
    }

    nonisolated static func decodeChecksums(_ json: Any) throws -> GLSyncChecksums {
        guard let object = json as? [String: Any],
              let raw = object["types"] as? [String: Any] else {
            throw GLSyncTransportError.malformedResponse
        }
        var types: [String: GLSyncChecksums.Entry] = [:]
        for (key, value) in raw {
            guard let entry = value as? [String: Any] else { continue }
            types[key] = GLSyncChecksums.Entry(
                count: (entry["count"] as? NSNumber)?.intValue ?? 0,
                maxSeq: (entry["max_seq"] as? NSNumber)?.intValue ?? 0)
        }
        return GLSyncChecksums(
            types: types,
            tombstones: (object["tombstones"] as? NSNumber)?.intValue ?? 0)
    }

    nonisolated static func decodeRow(_ value: Any) -> GLSyncRecordRow? {
        guard let object = value as? [String: Any],
              let rawID = object["id"] as? String, let id = UUID(uuidString: rawID),
              let type = object["type"] as? String else { return nil }
        return GLSyncRecordRow(
            id: id,
            type: type,
            parentID: (object["parent_id"] as? String).flatMap(UUID.init(uuidString:)),
            version: (object["version"] as? NSNumber)?.intValue ?? 0,
            seq: (object["seq"] as? NSNumber)?.intValue ?? 0,
            deletedAt: (object["deleted_at"] as? NSNumber)?.intValue,
            payload: GLSyncJSONValue.from(object["payload"]))
    }

    nonisolated static func decodeOpResult(_ value: Any) -> GLSyncOpResult? {
        guard let object = value as? [String: Any],
              let rawStatus = object["status"] as? String,
              let status = GLSyncOpStatus(rawValue: rawStatus) else { return nil }

        let losses = (object["lww_lost"] as? [Any] ?? []).compactMap { entry -> GLSyncFieldLoss? in
            guard let entry = entry as? [String: Any], let field = entry["field"] as? String else { return nil }
            return GLSyncFieldLoss(field: field, serverValue: .from(entry["server_value"]))
        }
        let conflicts = (object["conflicts"] as? [Any] ?? []).compactMap { entry -> GLSyncFieldConflict? in
            guard let entry = entry as? [String: Any], let field = entry["field"] as? String else { return nil }
            return GLSyncFieldConflict(
                field: field,
                serverValue: .from(entry["server_value"]),
                serverVersion: (entry["server_version"] as? NSNumber)?.intValue ?? 0)
        }
        // An unrecognized reason string keeps the `refused` status but loses the sentence —
        // the engine falls back to its generic copy rather than dropping the refusal.
        let reason = (object["reason"] as? String).flatMap(GLSyncRefusalReason.init(rawValue:))

        return GLSyncOpResult(
            status: status,
            version: (object["version"] as? NSNumber)?.intValue,
            appliedFields: object["applied_fields"] as? [String] ?? [],
            lwwLost: losses,
            conflicts: conflicts,
            reason: reason,
            head: object["head"].flatMap(decodeRow))
    }
}
