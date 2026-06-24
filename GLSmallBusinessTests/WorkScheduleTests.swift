//
//  WorkScheduleTests.swift
//  GLSmallBusinessTests
//
//  The built-in US holiday catalog (computed dates) and the WorkCalendar availability precedence
//  (date-override → days-off → weekday). Anchored to 2026: June 1 is a Monday (Sat = 6/6, Sun = 6/7),
//  Dec 25 is a Friday, Thanksgiving = Nov 26, Easter = April 5.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct WorkScheduleTests {
    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func holiday(_ id: String, _ year: Int) -> Date {
        USHoliday.holiday(id: id)!.date(in: year, calendar: cal)!
    }
    private func sameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }

    // MARK: - Holiday date math

    @Test func fixedHolidays() {
        #expect(sameDay(holiday("us.independence-day", 2026), date(2026, 7, 4)))
        #expect(sameDay(holiday("us.christmas", 2026), date(2026, 12, 25)))
        #expect(sameDay(holiday("us.juneteenth", 2026), date(2026, 6, 19)))
    }

    @Test func nthWeekdayHolidays() {
        #expect(sameDay(holiday("us.mlk-day", 2026), date(2026, 1, 19)))        // 3rd Mon Jan
        #expect(sameDay(holiday("us.memorial-day", 2026), date(2026, 5, 25)))   // last Mon May
        #expect(sameDay(holiday("us.labor-day", 2026), date(2026, 9, 7)))       // 1st Mon Sep
        #expect(sameDay(holiday("us.thanksgiving", 2026), date(2026, 11, 26)))  // 4th Thu Nov
    }

    @Test func blackFridayFollowsThanksgiving() {
        #expect(sameDay(holiday("us.black-friday", 2026), date(2026, 11, 27)))
    }

    @Test func easterAndGoodFriday() {
        #expect(sameDay(holiday("us.easter", 2026), date(2026, 4, 5)))
        #expect(sameDay(holiday("us.good-friday", 2026), date(2026, 4, 3)))
    }

    @Test func commonClosuresDefaultOnCulturalDefaultOff() {
        let s = WorkSchedule.standard
        func enabled(_ id: String) -> Bool { s.holidays.first { $0.id == id }?.enabled ?? false }
        #expect(enabled("us.thanksgiving"))     // federal
        #expect(enabled("us.black-friday"))     // common closure
        #expect(!enabled("us.halloween"))       // cultural
        #expect(!enabled("us.valentines"))      // cultural
    }

    // MARK: - Availability precedence

    @Test func defaultScheduleWorksMonFriNotWeekend() {
        let s = WorkSchedule.standard
        #expect(WorkCalendar.isWorkday(date(2026, 6, 1), schedule: s))    // Monday
        #expect(!WorkCalendar.isWorkday(date(2026, 6, 6), schedule: s))   // Saturday
    }

    @Test func enabledHolidayBlocksAWorkday() {
        // Christmas (enabled) falls on Friday Dec 25 2026 — normally a workday.
        #expect(!WorkCalendar.isWorkday(date(2026, 12, 25), schedule: .standard))
    }

    @Test func uncheckedHolidayBecomesWorkday() {
        var s = WorkSchedule.standard
        if let i = s.holidays.firstIndex(where: { $0.id == "us.christmas" }) { s.holidays[i].enabled = false }
        #expect(WorkCalendar.isWorkday(date(2026, 12, 25), schedule: s))
    }

    @Test func overrideMakesADayOffWorkable() {
        var s = WorkSchedule.standard
        s.overrides = [DateOverride(date: date(2026, 6, 6),   // a Saturday
                                    kind: .customHours(startMinutes: 9 * 60, endMinutes: 13 * 60))]
        let hours = WorkCalendar.workingHours(date(2026, 6, 6), schedule: s)
        #expect(hours.count == 1)
        #expect(WorkCalendar.isWorkday(date(2026, 6, 6), schedule: s))
    }

    @Test func vacationBlocksWorkdays() {
        var s = WorkSchedule.standard
        s.vacations = [DateRangeRule(start: date(2026, 6, 1), end: date(2026, 6, 5))]
        #expect(!WorkCalendar.isWorkday(date(2026, 6, 3), schedule: s))   // Wednesday inside vacation
        #expect(WorkCalendar.isWorkday(date(2026, 6, 8), schedule: s))    // Monday after
    }

    @Test func legacyMaskCarriesOver() {
        // Mon–Fri mask → weekdays work, weekend doesn't.
        let s = WorkSchedule.fromLegacyMask(SchedulingPrefs.defaultWorkdaysMask)
        #expect(s.weekdayHours[1].isWorkday)    // Monday (index 1)
        #expect(!s.weekdayHours[0].isWorkday)   // Sunday (index 0)
        #expect(!s.weekdayHours[6].isWorkday)   // Saturday (index 6)
    }

    @Test func encodesAndDecodesRoundTrip() throws {
        let s = WorkSchedule.standard
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WorkSchedule.self, from: data) == s)
    }
}
