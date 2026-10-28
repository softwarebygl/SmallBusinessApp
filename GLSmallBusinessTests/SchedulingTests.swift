//
//  SchedulingTests.swift
//  GLSmallBusinessTests
//
//  The Calendar scheduling logic: workdays, a job's occupied days (skipping off-days), the next
//  available date, and the gaps between booked work. Anchored to June 2026, where the 1st is a Monday
//  (Sat = 6/6, Sun = 6/7), so weekday math is concrete. Mon–Fri is the default workdays mask.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct SchedulingTests {
    private let monFri = SchedulingPrefs.defaultWorkdaysMask          // Mon–Fri
    private let allDays = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)

    // MARK: - Workdays

    @Test func isWorkdayRespectsMask() {
        #expect(SchedulingPrefs.isWorkday(TS.day(2026, 6, 1), mask: monFri))    // Monday
        #expect(!SchedulingPrefs.isWorkday(TS.day(2026, 6, 6), mask: monFri))   // Saturday
        #expect(!SchedulingPrefs.isWorkday(TS.day(2026, 6, 7), mask: monFri))   // Sunday
        #expect(SchedulingPrefs.isWorkday(TS.day(2026, 6, 6), mask: allDays))   // Saturday counts when all-days
    }

    @Test func zeroMaskFallsBackToDefault() {
        // A 0 mask would stall every walk — it's treated as Mon–Fri.
        #expect(SchedulingPrefs.isWorkday(TS.day(2026, 6, 1), mask: 0))
        #expect(!SchedulingPrefs.isWorkday(TS.day(2026, 6, 6), mask: 0))
    }

    // MARK: - Occupied days

    @Test func occupiedDaysAreConsecutiveWorkdays() {
        let days = TS.job(start: TS.day(2026, 6, 1), days: 3).occupiedDays(mask: monFri)   // Mon start
        #expect(days == [TS.day(2026, 6, 1), TS.day(2026, 6, 2), TS.day(2026, 6, 3)])
    }

    @Test func occupiedDaysSkipWeekend() {
        let days = TS.job(start: TS.day(2026, 6, 5), days: 3).occupiedDays(mask: monFri)   // Fri start → Fri, Mon, Tue
        #expect(days == [TS.day(2026, 6, 5), TS.day(2026, 6, 8), TS.day(2026, 6, 9)])
    }

    @Test func startingOnAnOffDayBeginsNextWorkday() {
        let j = TS.job(start: TS.day(2026, 6, 6), days: 2)                     // Sat start
        let days = j.occupiedDays(mask: monFri)
        #expect(days == [TS.day(2026, 6, 8), TS.day(2026, 6, 9)])              // Mon, Tue
        #expect(j.endDay(mask: monFri) == TS.day(2026, 6, 9))
    }

    @Test func durationClampedToAtLeastOne() {
        #expect(ScheduledJob(durationDays: 0).durationDays == 1)
        #expect(ScheduledJob(durationDays: -5).durationDays == 1)
    }

    // MARK: - Next available

    @Test func nextAvailableWithNoJobs() {
        #expect(SchedulingEngine.nextAvailable([], from: TS.day(2026, 6, 1), mask: monFri) == TS.day(2026, 6, 1))
        // From a Saturday → the next Monday.
        #expect(SchedulingEngine.nextAvailable([], from: TS.day(2026, 6, 6), mask: monFri) == TS.day(2026, 6, 8))
    }

    @Test func nextAvailableSkipsBookedDays() {
        let booked = [TS.job(start: TS.day(2026, 6, 1), days: 3)]             // Mon–Wed
        #expect(SchedulingEngine.nextAvailable(booked, from: TS.day(2026, 6, 1), mask: monFri) == TS.day(2026, 6, 4))
    }

    // MARK: - Gaps

    @Test func gapBetweenTwoJobs() {
        let booked = [TS.job(start: TS.day(2026, 6, 1), days: 1),
                      TS.job(start: TS.day(2026, 6, 8), days: 1)]               // Mon 6/1 and Mon 6/8
        let gaps = SchedulingEngine.gaps(booked, from: TS.day(2026, 6, 1), horizonDays: 30, mask: monFri)
        #expect(gaps.count == 1)
        // Open workdays between are Tue–Fri (6/2–6/5); the weekend is skipped.
        #expect(gaps.first?.start == TS.day(2026, 6, 2))
        #expect(gaps.first?.end == TS.day(2026, 6, 5))
        #expect(gaps.first?.workdays == 4)
    }

    @Test func noGapsWithoutJobs() {
        // No booked work after an open run → no bounded gap to report (just open availability).
        #expect(SchedulingEngine.gaps([], from: TS.day(2026, 6, 1), horizonDays: 30, mask: monFri).isEmpty)
    }

    @Test func trailingOpenRunIsNotAGap() {
        // One job up front; everything after it is open-ended availability, not a gap.
        let booked = [TS.job(start: TS.day(2026, 6, 1), days: 1)]
        #expect(SchedulingEngine.gaps(booked, from: TS.day(2026, 6, 1), horizonDays: 30, mask: monFri).isEmpty)
    }

    @Test func displayTitleAndGapIdentity() {
        #expect(ScheduledJob(title: "  ").displayTitle == "Job")
        #expect(ScheduledJob(title: "Deck build").displayTitle == "Deck build")
        let gaps = SchedulingEngine.gaps([TS.job(start: TS.day(2026, 6, 1), days: 1),
                                          TS.job(start: TS.day(2026, 6, 8), days: 1)],
                                         from: TS.day(2026, 6, 1), horizonDays: 30, mask: monFri)
        #expect(gaps.first?.id == gaps.first?.start)
    }
}
