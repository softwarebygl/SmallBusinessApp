//
//  DateRangeFilter.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  The date-range filtering behind every "View All" list (employee Hours / Paychecks, subcontractor
//  Activity). Pulled out of the SwiftUI sheets so the boundary behavior — inclusive custom end day,
//  year matching, DST / leap-year / year-rollover edges — is one place and is unit-testable.
//

import Foundation

enum DateRangeFilter: Equatable {
    /// Everything.
    case all
    /// A specific calendar year (the UI passes the current year for "This year").
    case year(Int)
    /// An inclusive day range: `from`'s start-of-day through the END of `to`'s day.
    case custom(from: Date, to: Date)

    /// Whether `date` falls inside this range. `custom` is inclusive of both endpoint *days*.
    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .year(let year):
            return calendar.component(.year, from: date) == year
        case .custom(let from, let to):
            let lo = calendar.startOfDay(for: from)
            // Add a day to `to`'s start-of-day so the whole of the `to` day is included; this also
            // keeps it correct across a DST transition (start-of-day arithmetic, not +86 400 s).
            let hi = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
            return date >= lo && date < hi
        }
    }

    /// Filter `items` by the `date` each one carries. Order is preserved.
    func apply<T>(to items: [T], date keyPath: (T) -> Date, calendar: Calendar = .current) -> [T] {
        items.filter { matches(keyPath($0), calendar: calendar) }
    }
}
