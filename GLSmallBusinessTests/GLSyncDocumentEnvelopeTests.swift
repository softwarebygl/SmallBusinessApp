//
//  GLSyncDocumentEnvelopeTests.swift — a W-9 sealed on one iPhone must open on the next.
//
//  Checklist 1.7. The on-device half of that item (a real second device pulling a real
//  encrypted W-9) needs a real Gold Life ID and stays a manual step — but the CONTRACT
//  it depends on is pure and testable here, and it is the half that can silently rot:
//  the second device never has the first device's key object, only the same 32 bytes
//  re-fetched from the server. These tests recreate exactly that (a fresh
//  `GLSyncDocumentKey` built from the same material) rather than reusing one instance,
//  because reusing it would prove only that a value equals itself.
//
//  The failure this stands against is quiet and permanent: a change to the header, the
//  nonce derivation, or the AAD re-seals fine and only fails on the OTHER device — the
//  one the developer is not holding — and the person is left with a tax document that
//  will not open on the machine they need it on.
//

import CryptoKit
import Foundation
import Testing
@testable import GLSmallBusiness

struct GLSyncDocumentEnvelopeTests {

    /// The server hands out raw bytes; both devices build their own key from them.
    private static let material = Data((0..<32).map { UInt8($0 &* 7 &+ 11) })
    private func key(version: Int = 1, bytes: Data = material) -> GLSyncDocumentKey {
        GLSyncDocumentKey(material: SymmetricKey(data: bytes), version: version)
    }
    /// Stand-in for a scanned W-9: binary, not text, and big enough to span AES blocks.
    private var w9: Data { Data((0..<5_000).map { UInt8(($0 &* 31 &+ 7) % 256) }) }

    // MARK: - The round trip

    @Test func aSealedDocumentOpensOnASecondDeviceBuiltFromTheSameServerBytes() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key())
        // A DIFFERENT key instance, as a second device would have: same bytes, new object.
        let reopened = try GLSyncDocumentEnvelope.open(sealed.envelope, with: key())
        #expect(reopened == w9, "the second device got different bytes than were sealed")
    }

    @Test func theEnvelopeIsNotThePlaintext() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key())
        #expect(sealed.envelope != w9, "the uploaded bytes ARE the document — nothing was encrypted")
        #expect(!sealed.envelope.contains(w9.prefix(64)),
                "a run of plaintext survived into the envelope")
    }

    @Test func theHashDescribesTheENVELOPE_notThePlaintext() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key())
        #expect(sealed.sha256 == glSyncSHA256(sealed.envelope),
                "the reference must name the bytes the server actually receives")
        #expect(sealed.sha256 != glSyncSHA256(w9),
                "naming the plaintext's hash would leak it AND break the server's check")
    }

    // MARK: - The isolation property (this is the security claim, not a nicety)

    @Test func anotherAccountsKeyCannotOpenIt() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key())
        var otherBytes = Self.material
        otherBytes[0] ^= 0xFF                      // a different account's derivation
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.open(sealed.envelope, with: key(bytes: otherBytes))
        }
    }

    @Test func aFlippedBitAnywhereRefusesToOpen() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key())
        // Header, ciphertext and tag each get their own tamper — AES-GCM authenticates the
        // header as AAD, so a header edit must fail just as loudly as a body edit.
        for index in [1, GLSyncDocumentEnvelope.headerByteCount + 3, sealed.envelope.count - 2] {
            var tampered = sealed.envelope
            tampered[tampered.startIndex + index] ^= 0x01
            #expect(throws: GLSyncDocumentError.self) {
                _ = try GLSyncDocumentEnvelope.open(tampered, with: key())
            }
        }
    }

    @Test func plainBytesAreNeverMistakenForAnEnvelope() {
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.open(w9, with: key())
        }
        // Right magic, but nothing after it.
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.open(GLSyncDocumentEnvelope.magic, with: key())
        }
    }

    // MARK: - Versioning

    @Test func anEnvelopeSealedUnderAnotherKeyVersionIsRefused_notMisread() throws {
        let sealed = try GLSyncDocumentEnvelope.seal(w9, with: key(version: 1))
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.open(sealed.envelope, with: key(version: 2))
        }
    }

    @Test func aKeyVersionTooBigForItsOneByteIsRefusedRatherThanTruncated() {
        // 257 would truncate to 1 and produce an envelope that opens with the WRONG key.
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.seal(w9, with: key(version: 257))
        }
    }

    // MARK: - Determinism (the reason the nonce is synthetic)

    @Test func resealingAnUnchangedDocumentReproducesTheSameBytes() throws {
        let first = try GLSyncDocumentEnvelope.seal(w9, with: key())
        let second = try GLSyncDocumentEnvelope.seal(w9, with: key())
        #expect(first.sha256 == second.sha256,
                "a re-push of an unchanged W-9 must be a no-op, not a new blob for every device")
        #expect(first.envelope == second.envelope)
    }

    @Test func twoDifferentDocumentsNeverShareANonce() throws {
        var other = w9
        other[other.startIndex] ^= 0x01
        let a = try GLSyncDocumentEnvelope.seal(w9, with: key())
        let b = try GLSyncDocumentEnvelope.seal(other, with: key())
        let nonceRange = GLSyncDocumentEnvelope.headerByteCount ..< (GLSyncDocumentEnvelope.headerByteCount + GLSyncDocumentEnvelope.nonceByteCount)
        #expect(a.envelope[nonceRange] != b.envelope[nonceRange],
                "one key reusing one nonce across two plaintexts breaks AES-GCM outright")
    }

    @Test func anEmptyDocumentIsRefused() {
        #expect(throws: GLSyncDocumentError.self) {
            _ = try GLSyncDocumentEnvelope.seal(Data(), with: key())
        }
    }
}
