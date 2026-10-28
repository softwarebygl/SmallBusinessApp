//
//  PaymentsPlumbingCoverageTests.swift
//
//  The payments plumbing — the error type users read, and the per-install token
//  that decides whether THIS device can mint pay links. Both were nearly
//  untested (StripeBackendClient 4.4%, StripeInstallTokenStore 25%) despite
//  being the layer where a failure costs the owner a paid invoice.
//
//  These are error-path and edge-case tests: the messages a user actually sees
//  when payments break, and the token store's behaviour when the Keychain is
//  empty, already populated, or asked to overwrite.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct PaymentsPlumbingCoverageTests {
    /// The install token belongs to a signed-in Gold Life ID (audit 2026-10-03 F2). The unit host has
    /// no session and its launch wipe drops any scope, so these tests name the host's own account.
    init() { SecureTINStore.setAccountScope("unit-tests") }

    // MARK: - Error copy (every case a user can be shown)

    /// Every StripeBackendError must produce a message that is plain English and
    /// says something a person can act on — the house rule for error copy. A case
    /// added without a message would surface as a blank alert.
    @Test func everyPaymentErrorHasUsableCopy() {
        let cases: [StripeBackendError] = [
            .notConfigured,
            .http(400), .http(401), .http(403), .http(404), .http(429), .http(500), .http(503),
            .claimRejected,
            .decoding,
            .offline, .timedOut, .unreachable,
            .onboardingCancelled, .browserUnavailable,
        ]
        for e in cases {
            let text = e.errorDescription
            #expect(text != nil, "\(e) has no errorDescription — a blank alert")
            let t = text ?? ""
            #expect(!t.isEmpty)
            // No raw type names or Swift enum syntax leaking to a user.
            #expect(!t.contains("StripeBackendError"))
            #expect(!t.contains("Optional("))
            #expect(!t.contains("Error Domain"))
        }
    }

    /// The status code is a DIAGNOSTIC, never copy. "The payment service returned
    /// an error (500)." is what the owner actually hit on 2026-08-22; a number in
    /// an alert tells them nothing they can do.
    @Test func httpErrorNeverShowsItsStatusCode() {
        for code in [400, 401, 402, 403, 409, 422, 429, 500, 502, 503] {
            let text = StripeBackendError.http(code).errorDescription ?? ""
            #expect(!text.contains("\(code)"), "code \(code) leaked into: \(text)")
        }
    }

    /// 4xx and 5xx are different problems and must not share one sentence: a 4xx
    /// is the owner's setup (act on it), a 5xx is ours (wait and retry).
    @Test func httpErrorSplitsClientFromServerFailures() {
        let clientSide = StripeBackendError.http(400).errorDescription ?? ""
        let serverSide = StripeBackendError.http(500).errorDescription ?? ""
        #expect(clientSide != serverSide)
        // A server failure must never blame the person's connection or their setup.
        #expect(!serverSide.localizedCaseInsensitiveContains("your connection"))
        // …and must say the account wasn't touched, so retrying feels safe.
        #expect(serverSide.localizedCaseInsensitiveContains("nothing on your account changed"))
    }

    /// A binding lost at the backend (401/403, or a rejected ownership claim) is
    /// fixed by reconnecting, never by retrying — callers branch on this instead
    /// of re-deriving it from a status code.
    @Test func bindingLostCoversAuthFailuresOnly() {
        #expect(StripeBackendError.http(401).isBindingLost)
        #expect(StripeBackendError.http(403).isBindingLost)
        #expect(StripeBackendError.claimRejected.isBindingLost)
        #expect(!StripeBackendError.http(500).isBindingLost)
        #expect(!StripeBackendError.http(429).isBindingLost)
        #expect(!StripeBackendError.offline.isBindingLost)
    }

    /// A URLSession failure must be translated into OUR words. Passing
    /// `localizedDescription` through showed people Apple's developer strings
    /// ("An SSL error has occurred and a secure connection to the server cannot
    /// be made."), which names nothing they can do.
    @Test func urlSessionFailuresMapToOurOwnWords() {
        #expect(StripeBackendError.from(urlSessionError: URLError(.notConnectedToInternet)) == .offline)
        #expect(StripeBackendError.from(urlSessionError: URLError(.dataNotAllowed)) == .offline)
        #expect(StripeBackendError.from(urlSessionError: URLError(.timedOut)) == .timedOut)
        // Everything else — DNS, TLS, captive portal, dropped connection.
        #expect(StripeBackendError.from(urlSessionError: URLError(.secureConnectionFailed)) == .unreachable)
        #expect(StripeBackendError.from(urlSessionError: URLError(.cannotFindHost)) == .unreachable)
        #expect(StripeBackendError.from(urlSessionError: NSError(domain: "x", code: 1)) == .unreachable)

        for e in [StripeBackendError.offline, .timedOut, .unreachable] {
            let text = e.errorDescription ?? ""
            #expect(!text.contains("SSL"))
            #expect(!text.contains("hostname"))
        }
    }

    /// The Stripe Worker is configured and lives on the unified backend gateway (moved from the old
    /// AIAssistantTests' Stripe half; its error-copy half is `everyPaymentErrorHasUsableCopy`).
    @Test func stripeConfigPointsAtTheWorker() {
        #expect(StripeConfig.isConfigured)
        #expect(StripeConfig.baseURL == "https://backend.softwarebygl.com/my-business/payments")
    }

    /// `needsReconnect` is what tells the app the stored binding is DEAD rather
    /// than unfinished. Dropping it on the floor is what left the screen showing
    /// "Finish Stripe setup" — a button that walked straight back into the 500.
    @Test func connectStatusDecodesNeedsReconnect() throws {
        let dead = """
        {"chargesEnabled":false,"payoutsEnabled":false,"detailsSubmitted":false,
         "currentlyDueCount":0,"needsReconnect":true}
        """
        let status = try JSONDecoder().decode(StripeConnectStatus.self, from: Data(dead.utf8))
        #expect(status.mustReconnect)
        #expect(!status.canCharge)

        // A healthy response omits the key entirely — it must still decode.
        let healthy = """
        {"chargesEnabled":true,"payoutsEnabled":true,"detailsSubmitted":true,"currentlyDueCount":0}
        """
        let ok = try JSONDecoder().decode(StripeConnectStatus.self, from: Data(healthy.utf8))
        #expect(!ok.mustReconnect)
        #expect(ok.canCharge)
    }

    // MARK: - Install token (Keychain-backed, per device)

    /// `ensure()` is idempotent: the first call mints, every later call returns
    /// the SAME token. A token that changed per call would orphan the device's
    /// link with the backend on every launch.
    @Test func ensureMintsOnceAndIsStable() {
        let first = StripeInstallTokenStore.ensure()
        #expect(!first.isEmpty)
        #expect(StripeInstallTokenStore.ensure() == first)
        #expect(StripeInstallTokenStore.ensure() == first)
        #expect(StripeInstallTokenStore.exists)
    }

    /// The minted token must look like the 32-byte hex it claims to be — length
    /// and alphabet. A short or non-hex token would be silently rejected by the
    /// Worker, which surfaces to the owner as "payments just don't work".
    @Test func mintedTokenIsThirtyTwoBytesOfHex() {
        let token = StripeInstallTokenStore.ensure()
        #expect(token.count == 64, "32 bytes as hex is 64 characters, got \(token.count)")
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(token.lowercased() == token, "hex is emitted lowercase")
    }

    /// THE hole a mutation found: the shape assertions above all pass for a constant
    /// token ("0" x 64 is 64 lowercase hex characters), so nothing caught a generator
    /// that stopped being random. Every install sharing one predictable token is a
    /// payments-security failure, so uniqueness is asserted directly.
    @Test func everyMintedTokenIsUnique() {
        let tokens = (0..<64).map { _ in StripeInstallTokenStore.generate() }
        #expect(Set(tokens).count == tokens.count, "generate() repeated a token")
        for token in tokens {
            #expect(token.count == 64)
            #expect(token.allSatisfy { $0.isHexDigit })
        }
    }

    /// A generator returning a constant, or one stuck on a single nibble, has almost no
    /// distinct characters. Real 32-byte hex uses most of the alphabet.
    @Test func mintedTokensCarryRealEntropy() {
        let token = StripeInstallTokenStore.generate()
        let distinct = Set(token).count
        #expect(distinct >= 10, "only \(distinct) distinct characters - this is not random: \(token)")
        #expect(Set(token) != Set(["0"]), "token is a constant")
    }

    /// `exists` must agree with `read()` — they are two views of one fact, and the
    /// reconnect UX branches on `exists`.
    @Test func existsAgreesWithRead() {
        _ = StripeInstallTokenStore.ensure()
        #expect(StripeInstallTokenStore.exists == !StripeInstallTokenStore.read().isEmpty)
    }

    /// Writing replaces rather than duplicating: a second write must be readable
    /// back as the new value, not leave two Keychain items where the first wins.
    @Test func writeOverwritesTheStoredValue() {
        let replacement = String(repeating: "a", count: 64)
        #expect(StripeInstallTokenStore.write(replacement))
        #expect(StripeInstallTokenStore.read() == replacement)

        // Restore a real token so a later test (or a later run on this simulator)
        // is not left holding the fake one.
        let real = String((0..<64).map { _ in "0123456789abcdef".randomElement()! })
        #expect(StripeInstallTokenStore.write(real))
        #expect(StripeInstallTokenStore.read() == real)
    }
}
