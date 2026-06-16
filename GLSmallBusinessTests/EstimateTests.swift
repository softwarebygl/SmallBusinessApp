//
//  EstimateTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct EstimateTests {
    @Test func totalsAndDeposit() {
        let est = TS.estimate(lines: [(1000, false)])
        est.depositType = .percentage
        est.depositValue = 50
        #expect(close(est.subtotal, 1000))
        #expect(close(est.total, 1000))
        #expect(close(est.depositAmount, 500))
    }

    @Test func taxAndDiscount() {
        let est = TS.estimate(taxRatePercent: 10, lines: [(100, true)])
        #expect(close(est.taxAmount, 10))
        #expect(close(est.total, 110))
    }

    @Test func expiredWhenPastValidUntilAndNotDecided() {
        let est = TS.estimate(status: .sent)
        est.validUntil = TS.day(2020, 1, 1)
        #expect(est.isExpired)
        #expect(est.displayStatus == "Expired")
    }

    @Test func acceptedIsNeverExpired() {
        let est = TS.estimate(status: .accepted)
        est.validUntil = TS.day(2020, 1, 1)
        #expect(!est.isExpired)
        #expect(est.displayStatus == "Accepted")
    }

    @Test func customerDisplayNameFallsBackToBusinessThenCustomer() {
        let est = TS.estimate()
        est.customerFirstName = ""
        est.customerLastName = ""
        est.customerBusinessName = "Frog Realty"
        #expect(est.customerDisplayName == "Frog Realty")
        est.customerBusinessName = nil
        #expect(est.customerDisplayName == "Customer")
        est.customerFirstName = "Devin"
        est.customerLastName = "Odom"
        #expect(est.customerDisplayName == "Devin Odom")
    }

    @Test func nextNumberIncrements() {
        #expect(Estimate.nextNumber(after: []) == "EST-0001")
        let a = Estimate(number: "EST-0012")
        #expect(Estimate.nextNumber(after: [a]) == "EST-0013")
    }

    @Test func defaultValidUntilIsThirtyDaysOut() {
        let created = TS.day(2026, 1, 1)
        let est = Estimate(number: "EST-1", createdAt: created)
        let days = Calendar.current.dateComponents([.day], from: created, to: est.validUntil).day ?? 0
        #expect(days == 30)
    }
}
