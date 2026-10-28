//
//  CalendarMathTests.swift
//  GLSmallBusinessTests
//
//  Covers the date math extracted out of CalendarScreen / RecordPaycheckSheet. Each test pins an
//  explicit Gregorian/UTC calendar so month boundaries, leap years, and firstWeekday are deterministic
//  regardless of the machine's locale.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct CalendarGridTests {
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = firstWeekday
        return c
    }

    private func firstOfMonth(_ year: Int, _ month: Int, in c: Calendar) -> Date {
        c.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    @Test func oneNonNilCellPerDayOfMonth() {
        let c = calendar(firstWeekday: 1)
        let june = firstOfMonth(2026, 6, in: c)
        let days = CalendarGrid.monthCells(monthStart: june, calendar: c).compactMap { $0 }
        #expect(days.count == 30)                              // June has 30 days
        #expect(c.component(.day, from: days.first!) == 1)     // first real cell is the 1st
        #expect(c.component(.day, from: days.last!) == 30)     // last real cell is the 30th
    }

    @Test func leapVsNonLeapFebruary() {
        let c = calendar(firstWeekday: 1)
        let feb2024 = CalendarGrid.monthCells(monthStart: firstOfMonth(2024, 2, in: c), calendar: c)
        let feb2026 = CalendarGrid.monthCells(monthStart: firstOfMonth(2026, 2, in: c), calendar: c)
        #expect(feb2024.compactMap { $0 }.count == 29)         // leap year
        #expect(feb2026.compactMap { $0 }.count == 28)
    }

    @Test func leadingBlanksFollowFirstWeekday() {
        // June 1, 2026 is a Monday.
        let sun = calendar(firstWeekday: 1)   // Sunday-first → one blank before Monday
        let mon = calendar(firstWeekday: 2)   // Monday-first → no leading blank
        let leadingSun = CalendarGrid.monthCells(monthStart: firstOfMonth(2026, 6, in: sun), calendar: sun)
            .prefix(while: { $0 == nil }).count
        let leadingMon = CalendarGrid.monthCells(monthStart: firstOfMonth(2026, 6, in: mon), calendar: mon)
            .prefix(while: { $0 == nil }).count
        #expect(leadingSun == 1)
        #expect(leadingMon == 0)
    }

    @Test func weekdaySymbolsRotateWithFirstWeekday() {
        let sun = CalendarGrid.orderedShortWeekdaySymbols(calendar: calendar(firstWeekday: 1))
        let mon = CalendarGrid.orderedShortWeekdaySymbols(calendar: calendar(firstWeekday: 2))
        #expect(sun.count == 7)
        #expect(mon.count == 7)
        // Monday-first is the Sunday-first ordering rotated left by one.
        #expect(mon == Array(sun.dropFirst()) + Array(sun.prefix(1)))
    }
}

@MainActor
struct PayPeriodTests {
    @Test func endOnOrAfterStartIsValid() {
        #expect(PayPeriod.isValid(start: TS.day(2026, 6, 1), end: TS.day(2026, 6, 7)))
        #expect(PayPeriod.isValid(start: TS.day(2026, 6, 7), end: TS.day(2026, 6, 7)))   // equal is allowed
    }

    @Test func reversedRangeIsInvalid() {
        #expect(!PayPeriod.isValid(start: TS.day(2026, 6, 7), end: TS.day(2026, 6, 1)))
    }
}
