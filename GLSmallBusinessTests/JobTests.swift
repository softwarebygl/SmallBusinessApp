//
//  JobTests.swift
//  GLSmallBusinessTests
//
//  The first-class Job model: its status accessor, from-scratch defaults, and the title fallback.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct JobTests {
    @Test func statusAccessorRoundTrips() {
        let job = ScheduledJob(title: "Tile")
        #expect(job.status == .scheduled)
        job.status = .inProgress
        #expect(job.statusRaw == JobStatus.inProgress.rawValue)
        #expect(job.status == .inProgress)
    }

    @Test func unknownStatusRawFallsBackToScheduled() {
        let job = ScheduledJob()
        job.statusRaw = "garbage"
        #expect(job.status == .scheduled)
    }

    @Test func fromScratchJobHasNoSourceAndKeepsItsPrice() {
        let job = ScheduledJob(title: "Regrout", customerName: "Doe, Jane",
                               startDate: TS.day(2026, 6, 1), durationDays: 2, agreedPrice: 450)
        #expect(!job.hasSource)
        #expect(job.agreedPrice == 450)
        #expect(job.displayTitle == "Regrout")
        #expect(job.status == .scheduled)
        #expect(job.completedAt == nil)
    }

    @Test func blankTitleDisplaysAsJob() {
        #expect(ScheduledJob(title: "   ").displayTitle == "Job")
    }
}
