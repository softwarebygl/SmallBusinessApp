//
//  EnumTests.swift
//  GLSmallBusinessTests
//
//  Label/mapping switches across the model enums — including the W-9 enums and the
//  BusinessProfile accessors that map them to/from their raw-string storage.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct EnumTests {
    @Test func w9ClassificationLabelsFormLabelsAndIdentity() {
        for c in W9TaxClassification.allCases {
            #expect(!c.label.isEmpty)
            #expect(!c.formLabel.isEmpty)
            #expect(c.id == c.rawValue)
        }
        #expect(W9TaxClassification.sCorporation.label == "S Corporation")
        // The exact checkbox wording printed on the W-9 for each classification.
        #expect(W9TaxClassification.individual.formLabel == "Individual/sole proprietor")
        #expect(W9TaxClassification.cCorporation.formLabel == "C corporation")
        #expect(W9TaxClassification.sCorporation.formLabel == "S corporation")
        #expect(W9TaxClassification.partnership.formLabel == "Partnership")
        #expect(W9TaxClassification.trustEstate.formLabel == "Trust/estate")
        #expect(W9TaxClassification.llc.formLabel == "Limited liability company")
        #expect(W9TaxClassification.other.formLabel == "Other")
    }

    @Test func w9TINTypeLabelsAndIdentity() {
        #expect(W9TINType.ssn.label == "SSN")
        #expect(W9TINType.ein.label == "EIN")
        #expect(W9TINType.ssn.id == "ssn")
        #expect(W9TINType.ein.id == "ein")
    }

    /// BusinessProfile's W-9 enum getters/setters map cleanly to/from their raw-string storage:
    /// an empty raw value reads back as nil, and clearing the enum clears the raw string.
    @Test func w9EnumAccessorsRoundTripThroughRawStrings() {
        let p = BusinessProfile()
        #expect(p.w9TaxClassification == nil)              // empty raw → nil
        p.w9TaxClassification = .sCorporation
        #expect(p.w9TaxClassificationRaw == W9TaxClassification.sCorporation.rawValue)
        #expect(p.w9TaxClassification == .sCorporation)
        p.w9TaxClassification = nil
        #expect(p.w9TaxClassificationRaw == "")
        #expect(p.w9TaxClassification == nil)

        #expect(p.w9TINType == nil)
        p.w9TINType = .ein
        #expect(p.w9TINTypeRaw == "ein")                   // the literal string the store keeps
        #expect(p.w9TINType == .ein)
        p.w9TINType = nil
        #expect(p.w9TINTypeRaw == "")
        #expect(p.w9TINType == nil)
    }

    @Test func paymentMethodLabels() {
        #expect(PaymentMethod.transfer.label == "Bank transfer")
        for m in PaymentMethod.allCases { #expect(!m.label.isEmpty) }
    }

    @Test func payTypeLabels() {
        #expect(PayType.hourly.label == "Hourly")
        #expect(PayType.salary.label == "Salary")
        for t in PayType.allCases { #expect(!t.label.isEmpty); #expect(t.id == t.rawValue) }
    }

    @Test func payFrequencyLabelsAndPeriods() {
        #expect(PayFrequency.weekly.periodsPerYear == 52)
        #expect(PayFrequency.biweekly.periodsPerYear == 26)
        #expect(PayFrequency.semimonthly.periodsPerYear == 24)
        #expect(PayFrequency.monthly.periodsPerYear == 12)
        for f in PayFrequency.allCases { #expect(!f.label.isEmpty); #expect(f.id == f.rawValue) }
    }

    @Test func unitOfMeasureLabelsAndAbbreviations() {
        for u in UnitOfMeasure.allCases {
            #expect(!u.label.isEmpty)
            #expect(!u.abbreviation.isEmpty)
        }
        #expect(UnitOfMeasure.squareFoot.abbreviation == "sq ft")
    }

    @Test func newPaymentMethodsExistWithStableRawValues() {
        // Raw values are what CloudKit persists — they must be exactly these strings.
        #expect(PaymentMethod.venmo.rawValue == "venmo")
        #expect(PaymentMethod.cashApp.rawValue == "cashApp")
        #expect(PaymentMethod.zelle.rawValue == "zelle")
        #expect(PaymentMethod.appleCash.rawValue == "appleCash")
        #expect(PaymentMethod.paypal.rawValue == "paypal")
        #expect(PaymentMethod.googlePay.rawValue == "googlePay")
        #expect(PaymentMethod.square.rawValue == "square")
        #expect(PaymentMethod.stripe.rawValue == "stripe")
        #expect(PaymentMethod.venmo.label == "Venmo")
        #expect(PaymentMethod.cashApp.label == "Cash App")
        for m in [PaymentMethod.zelle, .appleCash, .paypal, .googlePay, .square, .stripe] {
            #expect(PaymentMethod.allCases.contains(m))
            #expect(!m.label.isEmpty)
        }
    }

    @Test func paymentMethodDecodesUnknownRawValueAsOther() throws {
        // Mixed-version sync: a method added in a FUTURE build must decode as .other on this
        // build, never throw. Known raw values decode exactly; encoding stays the rawValue.
        let decoder = JSONDecoder()
        let known = try decoder.decode([PaymentMethod].self, from: Data(#"["zelle","check"]"#.utf8))
        #expect(known == [.zelle, .check])
        let future = try decoder.decode([PaymentMethod].self, from: Data(#"["someFutureRail"]"#.utf8))
        #expect(future == [.other])
        // Full round-trip is lossless for every known case.
        let encoded = try JSONEncoder().encode(PaymentMethod.allCases)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"zelle\""))
        #expect(try decoder.decode([PaymentMethod].self, from: encoded) == PaymentMethod.allCases)
    }

    @Test func form1099ThresholdIsYearAware() {
        // OBBBA: $600 through tax year 2025, $2,000 from 2026 on.
        #expect(close(Subcontractor.form1099Threshold(for: 2024), 600))
        #expect(close(Subcontractor.form1099Threshold(for: 2025), 600))
        #expect(close(Subcontractor.form1099Threshold(for: 2026), 2_000))
        #expect(close(Subcontractor.form1099Threshold(for: 2027), 2_000))
    }

    @Test func newUnitsExistWithStableRawValues() {
        #expect(UnitOfMeasure.item.rawValue == "item")
        #expect(UnitOfMeasure.labor.rawValue == "labor")
        #expect(!UnitOfMeasure.item.label.isEmpty)
        #expect(!UnitOfMeasure.item.abbreviation.isEmpty)
        #expect(!UnitOfMeasure.labor.label.isEmpty)
        #expect(!UnitOfMeasure.labor.abbreviation.isEmpty)
        #expect(UnitOfMeasure.allCases.contains(.item))
        #expect(UnitOfMeasure.allCases.contains(.labor))
    }

    @Test func adjustmentAndStatusLabels() {
        for a in AdjustmentType.allCases { #expect(!a.label.isEmpty) }
        for s in EstimateStatus.allCases { #expect(!s.label.isEmpty) }
        for k in LineItemKind.allCases { #expect(!k.label.isEmpty) }
        for s in ChangeOrderStatus.allCases { #expect(!s.label.isEmpty) }
    }

    @Test func complianceKindStoreReadRoundTrip() {
        let p = BusinessProfile()
        for kind in ComplianceKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.systemImage.isEmpty)
            #expect(kind.fallbackFileName.hasSuffix(".pdf"))
            #expect(kind.data(p) == nil)
            let blob = Data("x".utf8)
            kind.store(p, data: blob, name: "cert.pdf")
            #expect(kind.data(p) == blob)
            #expect(kind.fileName(p) == "cert.pdf")
        }
        #expect(ComplianceKind.wcExemption.title == "Workers’ Comp Exemption")
    }
}
