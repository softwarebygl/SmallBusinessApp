//
//  GLSyncDocumentCrypto.swift
//  GLSmallBusiness
//
//  Client-side envelope encryption for TAX-CLASS documents — today exactly one field,
//  `Subcontractor.w9Data`: the W-9 PDF with the subcontractor's SSN or EIN on line 4.
//
//  WHY IT EXISTS. gl-business-api refuses a `pii_class: tax` attachment that does not arrive
//  with `x-encrypted: 1` (attachments.ts), so until this file landed the engine STRIPPED
//  `w9Data` from every patch and the PDF stayed on one device. CloudKit syncs that document
//  today, so shipping the server cutover that way would have taken the file away from the
//  one moment it matters — a new phone, a lost phone. That regression was rejected in the
//  architecture ruling; this is the half of it that lives on the device.
//
//      plaintext PDF ──seal──▶ envelope ──▶ POST /attachments  (x-pii-class: tax, x-encrypted: 1)
//                        ▲
//         document key ──┘  GET /auth/document-key on gl-money-api — the IDENTITY service,
//                           a different Worker, a different store, a different secret.
//
//  NOT ZERO-KNOWLEDGE, DELIBERATELY, and no copy in this app may ever say otherwise. The key
//  is HKDF-derived server-side from a master secret Gold Life holds (gl-money-api
//  src/documentkey.ts), because a key that only ever existed on the device would make a lost
//  phone a lost W-9 — the punishing option, rejected. What IS true, and all that may be
//  claimed: the ciphertext and the key live in two separate systems, so breaching the file
//  store alone yields bytes nobody can read.
//
//  THE KEY IS MEMORY-ONLY. It is cached for the life of the process and never written to
//  disk, the Keychain, or a log — one 15-minute-ish network call per launch is cheaper than
//  owning a second stealable copy of the thing that opens every tax document. It is also
//  dropped on sign-out (`invalidate()`), which is a correctness rule and not hygiene: the
//  key is derived from the caller's canonical id, so re-using a cached one for the next
//  person to sign in on this device would seal their W-9 under someone else's key.
//
//  The fetch goes through `GLSyncIdentityCall`, the same call the app-token mint makes, against
//  the same Worker: this endpoint needs the STATUS code (503 means "not turned on yet" and must
//  not read as a failure the user caused), and GoldLifeCloud's one 401 refresh-and-retry signs a
//  person out only when Stytch itself refused the session. Weak signal is a quiet "try again
//  later" (law 13, owner ruling 2026-09-28).
//

import CryptoKit
import Foundation
import StytchCore
import GoldLifeCloud

// MARK: - The key

/// One derivation of the per-account document key.
nonisolated struct GLSyncDocumentKey: Sendable {
    /// The server's 32 bytes, used DIRECTLY as the AES-256 key. documentkey.ts calls them
    /// "an AES-256 key, which is what the client wraps documents with"; expanding them again
    /// here would be a second contract only this side remembers, and a future platform (the
    /// Android port, the web) would have to rediscover it to open the same file.
    let material: SymmetricKey
    /// Which derivation produced it (`DOCUMENT_KEY_VERSION` on the server). It rides in every
    /// envelope so a v2 key could one day coexist with documents v1 sealed.
    let version: Int
}

/// What `seal` produces: the bytes to upload, and the ONLY hash that may describe them.
nonisolated struct GLSyncSealedDocument: Sendable {
    let envelope: Data
    /// SHA-256 of `envelope`. The server recomputes this over what it actually received and
    /// refuses a mismatch (`hash_mismatch`), and R2 keys the blob by it — so the payload
    /// reference has to carry this hash, never the plaintext's.
    let sha256: String
}

/// Everything that can go wrong that is NOT a network fact. Network failures keep using
/// `GLSyncTransportError` (the engine has one set of retry rules and one set of sentences;
/// a second error vocabulary for the same situations would fork both).
nonisolated enum GLSyncDocumentError: LocalizedError, Sendable {
    /// The service handed back something that is not a 32-byte key.
    case malformedKey
    /// An envelope sealed by a key version this build cannot ask for.
    case unsupportedKeyVersion(Int)
    /// Downloaded bytes that are not one of our envelopes at all.
    case notAnEnvelope
    case sealFailed
    /// Wrong key, or tampered bytes. AES-GCM cannot tell the two apart, and neither can we.
    case openFailed

    /// Shown only on the seal side, where a permanent failure means one document will not be
    /// backed up while everything else about the record still is.
    /// `MBLocalization.string`, not `mbLoc`: this enum is `nonisolated` and is read from the
    /// sync actor, so it cannot hop to the MainActor helper. A plain literal would never be
    /// extracted, and a Spanish reader would get English.
    var userMessage: String {
        switch self {
        case .malformedKey, .sealFailed:
            return MBLocalization.string(
                "That tax document couldn't be backed up. Your other changes were saved.")
        case .unsupportedKeyVersion:
            return MBLocalization.string(
                "That tax document needs a newer version of My Business. Update the app to back it up.")
        case .notAnEnvelope, .openFailed:
            return MBLocalization.string(
                "That tax document couldn't be opened on this device. The copy on your other device is unaffected.")
        }
    }

    var errorDescription: String? { userMessage }

    /// One sentence for any error the document path can hand back, so the caller does not
    /// have to know which of the two vocabularies it came from. The fallback is the seal-side
    /// sentence because that is the only place a person ever sees one of these.
    static func message(for error: Error) -> String {
        if let error = error as? GLSyncDocumentError { return error.userMessage }
        if let text = (error as? GLSyncTransportError)?.userMessage { return text }
        // `sealFailed`'s own sentence rather than a second copy of it: one string, so the
        // fallback is localized by construction and cannot drift from the case it stands in for.
        return GLSyncDocumentError.sealFailed.userMessage
    }
}

// MARK: - The envelope format
//
// Layout, little of it negotiable once a document has been sealed with it:
//
//     0..3   magic "GLE1"     — this is one of ours, and which format
//     4      key version      — which derivation opens it
//     5..    AES-GCM combined — 12-byte nonce ‖ ciphertext ‖ 16-byte tag
//
// The 5-byte header is passed to AES-GCM as ADDITIONAL AUTHENTICATED DATA, so flipping the
// version byte in R2 breaks the tag instead of silently redirecting a decrypt.

nonisolated enum GLSyncDocumentEnvelope {

    /// "GLE1" — Gold Life Envelope, format 1.
    static let magic = Data([0x47, 0x4C, 0x45, 0x31])
    /// magic + one version byte.
    static let headerByteCount = 5
    /// AES-GCM's nonce width. Not a choice — CryptoKit's `combined` layout assumes it.
    static let nonceByteCount = 12
    /// AES-256.
    static let keyByteCount = 32

    /// HKDF domain separation for the nonce sub-key. FROZEN: change this string and every
    /// document already sealed becomes unopenable, because its nonce can no longer be
    /// reproduced. It is versioned so a future format can move without pretending it didn't.
    private static let nonceInfo = Data("gl-business/document-nonce/v1".utf8)

    /// Seal one document. Pure — bytes and a key in, bytes out — so it is testable with a
    /// fixed key and no network, no store, no actor.
    static func seal(_ plaintext: Data, with key: GLSyncDocumentKey) throws -> GLSyncSealedDocument {
        guard !plaintext.isEmpty else { throw GLSyncDocumentError.sealFailed }
        // The header spends ONE byte on the version, which is plenty for a number the server
        // is not expected to ever bump; refusing beats silently truncating it to a version
        // that opens with different bytes.
        guard let version = UInt8(exactly: key.version) else {
            throw GLSyncDocumentError.unsupportedKeyVersion(key.version)
        }

        var header = magic
        header.append(version)

        guard let sealed = try? AES.GCM.seal(plaintext,
                                             using: key.material,
                                             nonce: nonce(for: plaintext, with: key),
                                             authenticating: header),
              let combined = sealed.combined else {
            throw GLSyncDocumentError.sealFailed
        }

        let envelope = header + combined
        return GLSyncSealedDocument(envelope: envelope, sha256: glSyncSHA256(envelope))
    }

    /// Open one envelope, or throw. There is deliberately no "return the bytes as-is if they
    /// don't look encrypted" fallback: bytes that fail to open must never reach a record,
    /// because a W-9 that renders as garbage is worse than a W-9 that is simply not here yet.
    static func open(_ envelope: Data, with key: GLSyncDocumentKey) throws -> Data {
        guard envelope.count > headerByteCount, envelope.prefix(magic.count) == magic else {
            throw GLSyncDocumentError.notAnEnvelope
        }
        let version = Int(envelope[envelope.startIndex + magic.count])
        guard version == key.version else { throw GLSyncDocumentError.unsupportedKeyVersion(version) }

        let header = envelope.prefix(headerByteCount)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.dropFirst(headerByteCount)),
              let plaintext = try? AES.GCM.open(box, using: key.material, authenticating: header) else {
            throw GLSyncDocumentError.openFailed
        }
        return plaintext
    }

    /// The nonce is DERIVED FROM THE DOCUMENT, not random — a synthetic IV.
    ///
    /// Content addressing is why. R2 stores a blob under the sha256 of the bytes it received,
    /// and the payload reference must name that same hash. With a random nonce, re-sealing an
    /// UNCHANGED W-9 would produce different bytes, a different hash and a different
    /// reference every time — so any whole-record push would look like an edit, re-upload the
    /// PDF, and bounce a brand-new hash out to every other device. Deterministic sealing
    /// makes a re-push of an unchanged document a no-op, which is the only way the dedupe in
    /// `GLSyncEngine.uploadedHashes` and R2's own can mean anything.
    ///
    /// The rule this must not break is that one key must never use one nonce for two
    /// DIFFERENT plaintexts. Deriving the nonce by HMAC over the plaintext makes that a
    /// SHA-256 collision rather than a coin flip, which is the same reasoning behind
    /// AES-GCM-SIV. What it costs, said plainly: two byte-identical documents seal to
    /// identical bytes, so the store can tell they are the same file. For a W-9 that is not
    /// worth trading a re-upload storm for.
    ///
    /// The HMAC key is HKDF-separated from the encryption key so the nonce derivation and the
    /// cipher never share key material.
    private static func nonce(for plaintext: Data, with key: GLSyncDocumentKey) -> AES.GCM.Nonce {
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key.material,
                                              info: nonceInfo,
                                              outputByteCount: keyByteCount)
        let code = HMAC<SHA256>.authenticationCode(for: plaintext, using: nonceKey)
        // SHA-256 is 32 bytes and the nonce is 12, so this initializer cannot fail on width;
        // `try!` would still be a crash waiting for a CryptoKit change, and an all-zero nonce
        // would be a silent one, so it degrades to a fresh RANDOM nonce instead. That costs
        // the dedupe for this one document and keeps it correct and secret.
        return (try? AES.GCM.Nonce(data: Data(code).prefix(nonceByteCount))) ?? AES.GCM.Nonce()
    }
}

// MARK: - The key's lifecycle

/// Fetches the account's document key once per process, caches it in memory, and seals and
/// opens documents with it. An actor because the cache is shared state the engine touches
/// from its own actor, and because one in-flight fetch must serve every caller waiting on it.
actor GLSyncDocumentCrypto {

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

    private var cached: GLSyncDocumentKey?
    /// One fetch at a time. Without it, a push holding two W-9s asks the identity service
    /// twice for the same 32 bytes.
    private var fetch: Task<GLSyncDocumentKey, Error>?

    /// Encrypt a document for upload. Throws rather than returning plaintext when the key is
    /// unreachable — the caller MUST hold the upload back, never send it in the clear.
    func seal(_ plaintext: Data) async throws -> GLSyncSealedDocument {
        let key = try await currentKey()
        return try GLSyncDocumentEnvelope.seal(plaintext, with: key)
    }

    /// Decrypt a downloaded document.
    func open(_ envelope: Data) async throws -> Data {
        let key = try await currentKey()
        return try GLSyncDocumentEnvelope.open(envelope, with: key)
    }

    /// Drop the cached key. Call on sign-out: the key belongs to a canonical id, not to a
    /// device, so keeping it across a change of account is how one person's tax document ends
    /// up sealed under another person's key.
    func invalidate() {
        cached = nil
        fetch = nil
    }

    private func currentKey() async throws -> GLSyncDocumentKey {
        if let cached { return cached }
        if let fetch { return try await fetch.value }
        let task = Task { try await self.fetchKey() }
        fetch = task
        defer { fetch = nil }
        return try await task.value
    }

    // MARK: The fetch

    private func fetchKey() async throws -> GLSyncDocumentKey {
        guard storedSessionJWT() != nil else {
            throw GLSyncTransportError.signedOut
        }

        // Weak signal comes back as a 503, which the table below reads as
        // `.documentKeyUnavailable`: the W-9 waits in the outbox, quietly.
        guard case .response(let data, let status) = try await GLSyncIdentityCall.send(
            Self.keyRequest(), via: transport, onSessionExpired: onSessionExpired) else {
            throw GLSyncTransportError.signedOut
        }

        guard (200..<300).contains(status) else { throw Self.error(status: status, body: data) }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = object["key"] as? String,
              let material = Data(base64Encoded: encoded),
              material.count == GLSyncDocumentEnvelope.keyByteCount else {
            throw GLSyncDocumentError.malformedKey
        }
        // Required, not defaulted: the version is stamped into every envelope this key seals,
        // and guessing it would label documents with a derivation that may not have made them.
        guard let version = (object["version"] as? NSNumber)?.intValue else {
            throw GLSyncDocumentError.malformedKey
        }

        let key = GLSyncDocumentKey(material: SymmetricKey(data: material), version: version)
        cached = key
        return key
    }

    /// `GET /auth/document-key` on gl-money-api. GoldLifeCloud attaches the session JWT.
    private static func keyRequest() -> GLCloudRequest {
        GLCloudRequest(
            target: .custom(LocalSecrets.workerURL),
            path: "auth/document-key",
            method: "GET",
            authMode: .sessionJwt,
            validateStatus: false
        )
    }

    /// Status + the `{error: "<machine_snake_case>"}` envelope → a typed error, mapped so the
    /// engine's existing retry rules apply unchanged.
    private static func error(status: Int, body: Data) -> GLSyncTransportError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch object?["error"] as? String {
        case "document_key_unconfigured":
            // The EXPECTED answer until DOCUMENT_KEY_MASTER_B64 is set in production.
            return .documentKeyUnavailable
        case "rate_limited":
            return .rateLimited(retryAfter: (object?["retry_after_seconds"] as? Double) ?? 60)
        default: break
        }
        switch status {
        case 429: return .rateLimited(retryAfter: 60)
        case 503: return .documentKeyUnavailable
        default: return .server(status: status)
        }
    }
}
