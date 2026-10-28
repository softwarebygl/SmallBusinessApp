//
//  CalendarMath.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Pure, testable date math that used to live inside views. Both pieces take an explicit `Calendar`
//  so tests can pin firstWeekday / timezone and exercise month boundaries, leap years, and locales —
//  none of which is reachable when the logic is trapped in a SwiftUI view.
//

import Foundation

enum CalendarGrid {
    /// Day cells for the month containing `monthStart`: leading blanks (nil) aligned to the calendar's
    /// `firstWeekday`, then one Date per day of that month.
    static func monthCells(monthStart: Date, calendar: Calendar) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: monthStart))
        }
        return cells
    }

    /// Very-short weekday symbols rotated so element 0 is the calendar's `firstWeekday`.
    static func orderedShortWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols   // [Sun … Sat]
        let start = calendar.firstWeekday - 1            // 0-based
        return (0..<7).map { symbols[($0 + start) % 7] }
    }
}

enum PayPeriod {
    /// A pay period is valid when its end date is on or after its start date.
    static func isValid(start: Date, end: Date) -> Bool { end >= start }
}
