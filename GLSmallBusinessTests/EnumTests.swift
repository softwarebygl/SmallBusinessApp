//
//  EnumTests.swift
//  GLSmallBusinessTests
//
//  Label/mapping switches across the model enums.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct EnumTests {
    @Test func w9ClassificationLabelsAllNonEmpty() {
        for c in W9TaxClassification.allCases {
            #expect(!c.label.isEmpty)
            #expect(c.id == c.rawValue)
        }
        #expect(W9TaxClassification.sCorporation.label == "S Corporation")
    }

    @Test func w9TINTypeLabels() {
        #expect(W9TINType.ssn.label == "SSN")
        #expect(W9TINType.ein.label == "EIN")
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

    @Test func adjustmentAndStatusLabels() {
        for a in AdjustmentType.allCases { #expect(!a.label.isEmpty) }
        for s in EstimateStatus.allCases { #expect(!s.label.isEmpty) }
        for s in InvoiceStatus.allCases { #expect(!s.label.isEmpty) }
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
        #expect(ComplianceKind.wcInsurance.title == "Workers' Comp Insurance")
    }
}
