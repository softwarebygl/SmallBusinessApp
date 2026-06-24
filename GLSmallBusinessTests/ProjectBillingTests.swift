//
//  ProjectBillingTests.swift
//  GLSmallBusinessTests
//
//  Progress-billing math: a job's contracted value (agreed price → estimate → invoiced), the
//  fully-billed-and-collected gate (incl. the $0 / comped case), and project roll-ups.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct ProjectBillingTests {
    @Test func contractedValueUsesAgreedPriceFirst() {
        let job = ScheduledJob(agreedPrice: 500)
        #expect(job.contractedValue == 500)
        #expect(job.invoicedTotal == 0)
    }

    @Test func unpricedJobWithNoInvoicesIsVacuouslyComplete() {
        let job = ScheduledJob()   // no price, no estimate, no invoices → $0 contract
        #expect(job.contractedValue == 0)
        #expect(job.isFullyBilledAndCollected)   // $0 + zero balance is vacuously paid-in-full
    }

    @Test func pricedJobWithNoInvoicesIsNotFullyBilled() {
        let job = ScheduledJob(agreedPrice: 500)
        #expect(!job.isFullyBilledAndCollected)   // contracted 500, invoiced 0
        #expect(job.remainingToInvoice == 500)
    }

    @Test func projectRollsUpItsJobsContractedValues() {
        let a = ScheduledJob(agreedPrice: 500)
        let b = ScheduledJob(agreedPrice: 1000)
        let project = Project(name: "Remodel")
        project.jobs = [a, b]
        #expect(project.contractedValue == 1500)
        #expect(project.invoicedTotal == 0)
        #expect(project.remainingToInvoice == 1500)
    }
}
