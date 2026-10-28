//
//  WorkScheduleTests.swift
//  GLSmallBusinessTests
//
//  The built-in US holiday catalog (computed dates) and the WorkCalendar availability precedence
//  (date-override → days-off → weekday). Anchored to 2026 on the harness calendar: June 1 is a Monday
//  (Sat = 6/6, Sun = 6/7), Dec 25 is a Friday, Thanksgiving = Nov 26, Easter = April 5.
//

import Testing
import Foundation
import SwiftUI
@testable import GLSmallBusiness

@MainActor
struct WorkScheduleTests {
    private let cal = TS.calendar

    private func holiday(_ id: String, _ year: Int) -> Date {
        USHoliday.holiday(id: id)!.date(in: year, calendar: cal)!
    }
    private func sameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }

    // MARK: - Holiday date math

    @Test func fixedHolidays() {
        #expect(sameDay(holiday("us.independence-day", 2026), TS.day(2026, 7, 4)))
        #expect(sameDay(holiday("us.christmas", 2026), TS.day(2026, 12, 25)))
        #expect(sameDay(holiday("us.juneteenth", 2026), TS.day(2026, 6, 19)))
    }

    @Test func nthWeekdayHolidays() {
        #expect(sameDay(holiday("us.mlk-day", 2026), TS.day(2026, 1, 19)))        // 3rd Mon Jan
        #expect(sameDay(holiday("us.memorial-day", 2026), TS.day(2026, 5, 25)))   // last Mon May
        #expect(sameDay(holiday("us.labor-day", 2026), TS.day(2026, 9, 7)))       // 1st Mon Sep
        #expect(sameDay(holiday("us.thanksgiving", 2026), TS.day(2026, 11, 26)))  // 4th Thu Nov
    }

    @Test func blackFridayFollowsThanksgiving() {
        #expect(sameDay(holiday("us.black-friday", 2026), TS.day(2026, 11, 27)))
    }

    @Test func easterAndGoodFriday() {
        #expect(sameDay(holiday("us.easter", 2026), TS.day(2026, 4, 5)))
        #expect(sameDay(holiday("us.good-friday", 2026), TS.day(2026, 4, 3)))
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
        #expect(WorkCalendar.isWorkday(TS.day(2026, 6, 1), schedule: s, calendar: cal))    // Monday
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 6, 6), schedule: s, calendar: cal))   // Saturday
    }

    @Test func enabledHolidayBlocksAWorkday() {
        // Christmas (enabled) falls on Friday Dec 25 2026 — normally a workday.
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 12, 25), schedule: .standard, calendar: cal))
    }

    @Test func uncheckedHolidayBecomesWorkday() {
        var s = WorkSchedule.standard
        if let i = s.holidays.firstIndex(where: { $0.id == "us.christmas" }) { s.holidays[i].enabled = false }
        #expect(WorkCalendar.isWorkday(TS.day(2026, 12, 25), schedule: s, calendar: cal))
    }

    @Test func overrideMakesADayOffWorkable() {
        var s = WorkSchedule.standard
        s.overrides = [DateOverride(date: TS.day(2026, 6, 6),   // a Saturday
                                    kind: .customHours(startMinutes: 9 * 60, endMinutes: 13 * 60))]
        let hours = WorkCalendar.workingHours(TS.day(2026, 6, 6), schedule: s, calendar: cal)
        #expect(hours.count == 1)
        #expect(WorkCalendar.isWorkday(TS.day(2026, 6, 6), schedule: s, calendar: cal))
    }

    @Test func vacationBlocksWorkdays() {
        var s = WorkSchedule.standard
        s.vacations = [DateRangeRule(start: TS.day(2026, 6, 1), end: TS.day(2026, 6, 5))]
        #expect(!WorkCalendar.isWorkday(TS.day(2026, 6, 3), schedule: s, calendar: cal))   // Wednesday inside vacation
        #expect(WorkCalendar.isWorkday(TS.day(2026, 6, 8), schedule: s, calendar: cal))    // Monday after
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

    // MARK: - A synced week of the wrong length (QA F60)

    /// The blob syncs from the server, which doesn't check its length. A 5-day week read as-is
    /// trapped the Work Schedule screen (it reads all 7 days) and the assistant's weekday edit.
    @Test func aShortSyncedWeekReadsAsSevenDays() throws {
        var short = WorkSchedule.standard
        short.weekdayHours = Array(short.weekdayHours.prefix(5))
        short.weekdayHours[1].startMinutes = 7 * 60
        let profile = BusinessProfile()
        profile.workScheduleData = try JSONEncoder().encode(short)

        let read = profile.workSchedule
        try #require(read.weekdayHours.count == 7)
        #expect(Array(read.weekdayHours.prefix(5)) == short.weekdayHours, "the days it has are kept")
        #expect(read.weekdayHours[5] == WorkSchedule.standard.weekdayHours[5], "a missing Friday is the standard one")
        #expect(read.weekdayHours[6] == WorkSchedule.standard.weekdayHours[6], "a missing Saturday is the standard one")
        #expect(read.holidays == short.holidays && read.vacations == short.vacations)
    }

    @Test func aLongSyncedWeekReadsAsSevenDays() throws {
        var long = WorkSchedule.standard
        long.weekdayHours += long.weekdayHours.prefix(2)
        let profile = BusinessProfile()
        profile.workScheduleData = try JSONEncoder().encode(long)
        #expect(profile.workSchedule.weekdayHours == WorkSchedule.standard.weekdayHours)
    }

    // MARK: - Rows survive their own swipe-delete (QA F60)

    /// A stand-in for the screen's `@State`, so the row bindings can be driven without a view.
    private final class Box { var value: WorkSchedule; init(_ value: WorkSchedule) { self.value = value } }
    private func binding(_ box: Box) -> Binding<WorkSchedule> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    @Test func deletingTheLastTimeOffWhileItIsBoundDoesNotTrap() {
        let range = DateRangeRule(start: TS.day(2026, 7, 1), end: TS.day(2026, 7, 5))
        var schedule = WorkSchedule.standard
        schedule.vacations = [range]
        let box = Box(schedule)
        let from = WorkScheduleScreen.timeOffDate(range, start: true, in: binding(box))
        let to = WorkScheduleScreen.timeOffDate(range, start: false, in: binding(box))

        // The clamp still holds while the row is there: From past To drags To along.
        from.wrappedValue = TS.day(2026, 7, 9)
        #expect(box.value.vacations.first?.end == TS.day(2026, 7, 9))

        box.value.vacations.remove(atOffsets: IndexSet(integer: 0))   // the swipe-delete
        // SwiftUI may read the deleted row's bindings once more: they answer, never trap…
        _ = from.wrappedValue
        _ = to.wrappedValue
        // …and a late write is dropped rather than landing on another row.
        to.wrappedValue = TS.day(2026, 8, 1)
        #expect(box.value.vacations.isEmpty)
    }

    @Test func deletingTheLastOverrideWhileItIsBoundDoesNotTrap() {
        let override = DateOverride(date: TS.day(2026, 7, 4), kind: .customHours(startMinutes: 540, endMinutes: 780))
        var schedule = WorkSchedule.standard
        schedule.overrides = [override]
        let box = Box(schedule)
        let custom = WorkScheduleScreen.overrideIsCustomHours(override, in: binding(box))
        let start = WorkScheduleScreen.overrideTime(override, start: true, in: binding(box))
        #expect(custom.wrappedValue)

        box.value.overrides.removeAll()   // the swipe-delete
        _ = custom.wrappedValue
        _ = start.wrappedValue
        custom.wrappedValue = false
        #expect(box.value.overrides.isEmpty)
    }

    /// A row keeps editing its OWN element after an earlier row is deleted.
    @Test func aRowStillEditsItsOwnRangeAfterAnEarlierOneIsDeleted() {
        let first = DateRangeRule(start: TS.day(2026, 7, 1), end: TS.day(2026, 7, 2))
        let second = DateRangeRule(start: TS.day(2026, 9, 1), end: TS.day(2026, 9, 2))
        var schedule = WorkSchedule.standard
        schedule.vacations = [first, second]
        let box = Box(schedule)
        let secondTo = WorkScheduleScreen.timeOffDate(second, start: false, in: binding(box))
        box.value.vacations.removeFirst()
        secondTo.wrappedValue = TS.day(2026, 9, 6)
        #expect(box.value.vacations == [DateRangeRule(id: second.id, start: second.start, end: TS.day(2026, 9, 6))])
    }
}
