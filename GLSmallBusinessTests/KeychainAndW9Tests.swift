//
//  KeychainAndW9Tests.swift
//  GLSmallBusinessTests
//
//  Serialized: these tests share one Keychain item (the TIN), so they must not run concurrently.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct KeychainAndW9Tests {
    @Test func secureTINWriteReadClearRoundTrip() {
        let p = BusinessProfile()
        p.updateTIN("12-3456789")
        #expect(p.secureTIN == "12-3456789")
        // A second profile reads the same shared Keychain value.
        #expect(BusinessProfile().secureTIN == "12-3456789")
        p.updateTIN("")
        #expect(p.secureTIN == "")
    }

    @Test func updateTINPurgesLegacyPlaintext() {
        let p = BusinessProfile()
        SecureTINStore.write("")          // ensure a clean keychain
        p.w9TIN = "99-3544594"            // legacy plaintext
        #expect(p.secureTIN == "99-3544594")   // read falls back to legacy
        p.updateTIN("11-1111111")        // migrate
        #expect(p.w9TIN == "")           // legacy copy purged
        #expect(p.secureTIN == "11-1111111")
        SecureTINStore.write("")
    }

    @Test func w9CompleteWhenNameClassificationAndTINPresent() {
        SecureTINStore.write("")
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.w9TaxClassificationRaw = W9TaxClassification.sCorporation.rawValue
        p.w9TINTypeRaw = W9TINType.ein.rawValue
        p.w9TIN = "123456789"
        #expect(p.w9IsComplete)
        #expect(p.w9MissingRequirements.isEmpty)
    }

    @Test func w9MissingTINIsReported() {
        SecureTINStore.write("")
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.w9TaxClassificationRaw = W9TaxClassification.individual.rawValue
        p.w9TINTypeRaw = ""           // no TIN type
        p.w9TIN = ""                  // no TIN
        #expect(!p.w9IsComplete)
        #expect(p.w9MissingRequirements.contains { $0.contains("Tax ID") })
    }

    @Test func subcontractorTINIsPerRecordAndClearable() {
        let a = TS.subcontractor()
        let b = TS.subcontractor()
        a.w9TINType = .ein
        a.updateTIN("12-3456789")
        b.updateTIN("123-45-6789")
        #expect(a.secureTIN == "12-3456789")
        #expect(b.secureTIN == "123-45-6789")   // each sub's TIN is stored independently
        #expect(a.w9TINType == .ein)
        #expect(a.hasTIN && b.hasTIN)
        #expect(a.maskedTIN == "•••• 6789")
        a.clearSecureTIN()
        #expect(!a.hasTIN && a.secureTIN == "")
        #expect(b.secureTIN == "123-45-6789")   // clearing one doesn't touch the other
        b.clearSecureTIN()
    }

    @Test func subcontractorNoTINByDefault() {
        let s = Subcontractor()
        #expect(s.tinKey == "")
        #expect(!s.hasTIN && s.secureTIN == "" && s.maskedTIN == "")
        s.updateTIN("   ")            // blank → must not allocate a key or store anything
        #expect(s.tinKey == "")
        #expect(!s.hasTIN)
    }
}
