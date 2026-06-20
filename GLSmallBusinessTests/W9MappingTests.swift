//
//  W9MappingTests.swift
//  GLSmallBusinessTests
//
//  BusinessProfile's W-9 enum getters/setters map cleanly to/from their raw-string storage
//  (and an empty/unknown raw value reads back as nil).
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct W9MappingTests {
    @Test func taxClassificationRoundTripsThroughRawString() {
        let p = BusinessProfile()
        #expect(p.w9TaxClassification == nil)              // empty raw → nil

        p.w9TaxClassification = .sCorporation
        #expect(p.w9TaxClassificationRaw == W9TaxClassification.sCorporation.rawValue)
        #expect(p.w9TaxClassification == .sCorporation)

        p.w9TaxClassification = nil
        #expect(p.w9TaxClassificationRaw == "")
        #expect(p.w9TaxClassification == nil)
    }

    @Test func tinTypeRoundTripsThroughRawString() {
        let p = BusinessProfile()
        #expect(p.w9TINType == nil)

        p.w9TINType = .ein
        #expect(p.w9TINTypeRaw == W9TINType.ein.rawValue)
        #expect(p.w9TINType == .ein)

        p.w9TINType = nil
        #expect(p.w9TINTypeRaw == "")
        #expect(p.w9TINType == nil)
    }
}
