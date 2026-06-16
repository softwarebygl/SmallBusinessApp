//
//  AccessTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
import CryptoKit
@testable import GLSmallBusiness

@MainActor
struct AccessTests {
    @Test func hashIsDeterministicCaseInsensitiveAndHex() {
        let a = AccessCodes.hash("GL-ABCD-1234")
        let b = AccessCodes.hash("gl-abcd-1234")
        #expect(a == b)                                 // uppercased before hashing
        #expect(a.count == 64)                          // SHA-256 hex
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func hashMatchesStandardSHA256OfUppercasedCode() {
        let code = "gl-test-code"
        let expected = SHA256.hash(data: Data(code.uppercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(AccessCodes.hash(code) == expected)
    }

    @Test func unknownCodeDoesNotMatch() {
        #expect(AccessCodes.match("GL-0000-0000") == nil)
    }

    @Test func redeemingGarbageIsInvalid() {
        #expect(AccessManager.shared.redeem("GL-0000-0000") == .invalid)
        #expect(AccessManager.shared.redeem("not-a-code") == .invalid)
    }

    @Test func redeemResultEquatable() {
        #expect(RedeemResult.invalid == RedeemResult.invalid)
        #expect(RedeemResult.expired != RedeemResult.invalid)
    }
}
