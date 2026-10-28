//
//  GLSyncValueRangeTests.swift
//  GLSmallBusinessTests
//
//  QA F64: a synced number outside Int's range, or one JSON can't carry, must never trap. The
//  server doesn't range-check values, and a pull runs at launch on every device on the account,
//  so one bad row used to crash the app on the splash, reinstall or not.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct GLSyncValueRangeTests {

    @Test func anIntOutsideIntRangeReadsAsTheFallback() {
        #expect(GLSyncValue.int(["n": 1e19], "n", default: 7) == 7)
        #expect(GLSyncValue.int(["n": -1e19], "n", default: 7) == 7)
        #expect(GLSyncValue.int(["n": Double.nan], "n", default: 7) == 7)
        #expect(GLSyncValue.int(["n": Double.infinity], "n", default: 7) == 7)
        #expect(GLSyncValue.int(["n": 42.9], "n") == 42, "an in-range Double still truncates as before")
        #expect(GLSyncValue.int(["n": 5], "n") == 5)
    }

    @Test func aDurationOutsideIntRangeReadsAsNil() throws {
        let context = try DomainFixtures.context()
        let job = ScheduledJob()
        context.insert(job)
        job.durationMinutes = 60
        job.glSyncApply(["durationMinutes": 1e19], in: context)
        #expect(job.durationMinutes == nil)
        job.glSyncApply(["durationMinutes": Double.nan], in: context)
        #expect(job.durationMinutes == nil)
        job.glSyncApply(["durationMinutes": 90.0], in: context)
        #expect(job.durationMinutes == 90)
    }

    @Test func aDateOutsideIntMillisecondsReadsAsNilAndWritesWithoutATrap() {
        #expect(GLSyncValue.date(["d": 1e300], "d") == nil)
        #expect(GLSyncValue.date(["d": Double.infinity], "d") == nil)
        #expect(GLSyncValue.date(["d": 1_699_100_019_000.0], "d") == Date(timeIntervalSince1970: 1_699_100_019))
        // A date that far out can't be produced by a picker; writing one still must not trap.
        #expect(GLSyncValue.date(Date(timeIntervalSince1970: 1e300)) is Int)
        #expect(GLSyncValue.date(Date(timeIntervalSince1970: -1e300)) is Int)
    }

    @Test func aHugeDurationBlocksTimeWithoutOverflow() {
        let job = ScheduledJob()
        job.isAllDay = false
        job.startTime = TS.day(2026, 7, 1)
        job.durationMinutes = Int.max / 2
        #expect(job.occupiedIntervals(schedule: .standard).count == 1)
        #expect(!job.timeText.isEmpty)
    }

    /// NaN can't ride JSON; comparing it used to raise an Objective-C exception (a crash).
    @Test func comparingAValueJSONCantCarryIsUnequalNotACrash() {
        #expect(!GLSyncLocalStore.syncValueEqual(Double.nan, 1.0))
        #expect(!GLSyncLocalStore.syncValueEqual(["k": Double.infinity] as GLSyncPayload, ["k": 1.0] as GLSyncPayload))
        #expect(GLSyncLocalStore.syncValueEqual(1.0, 1.0))
        #expect(GLSyncLocalStore.syncValueEqual(["b": 1, "a": "x"] as GLSyncPayload, ["a": "x", "b": 1] as GLSyncPayload))
    }
}
