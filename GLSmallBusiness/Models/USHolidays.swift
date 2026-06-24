//
//  USHolidays.swift
//  GLSmallBusiness
//
//  A built-in catalog of American holidays + the date math to resolve each one for a given year. There
//  is no Apple "US holidays" API (iOS only exposes the user's subscribed Holidays calendar, which needs
//  permission and varies per person), so we ship our own computed list — works offline, no permission.
//  Each holiday has a STABLE id (independent of the date) so a user's "off / on / one-time" choices
//  survive across years and across future edits to this list.
//
//  Grouped Federal · Common closures · Cultural & religious. The common days everyone usually takes off
//  default ON; everything else is present but defaults OFF, so the owner never has to uncheck a long list.
//

import Foundation

nonisolated enum HolidayGroup: String, Codable, Sendable, CaseIterable, Identifiable {
    case federal
    case commonClosure
    case cultural

    var id: String { rawValue }

    var title: String {
        switch self {
        case .federal: String(localized: "Federal")
        case .commonClosure: String(localized: "Common closures")
        case .cultural: String(localized: "Cultural & religious")
        }
    }
}

/// How a holiday's date is computed for a given year.
nonisolated enum HolidayRule: Sendable {
    case fixed(month: Int, day: Int)
    /// nth (1-based) `weekday` (1=Sun … 7=Sat) of `month`; n = -1 means the LAST one.
    case nthWeekday(n: Int, weekday: Int, month: Int)
    /// Offset in days from Thanksgiving (e.g. Black Friday = +1).
    case relativeToThanksgiving(offsetDays: Int)
    /// Offset in days from Western (Gregorian) Easter Sunday (e.g. Good Friday = -2).
    case easterOffset(Int)
}

nonisolated struct USHoliday: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let group: HolidayGroup
    /// True for the days everyone usually takes off — auto-enabled so there's nothing to uncheck.
    let defaultOn: Bool
    let rule: HolidayRule

    static func == (lhs: USHoliday, rhs: USHoliday) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The calendar date this holiday falls on in `year`, or nil if it can't be resolved.
    func date(in year: Int, calendar: Calendar = .current) -> Date? {
        switch rule {
        case .fixed(let month, let day):
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        case .nthWeekday(let n, let weekday, let month):
            return USHoliday.nthWeekday(n: n, weekday: weekday, month: month, year: year, calendar: calendar)
        case .relativeToThanksgiving(let offset):
            guard let thanksgiving = USHoliday.nthWeekday(n: 4, weekday: 5, month: 11, year: year, calendar: calendar)
            else { return nil }
            return calendar.date(byAdding: .day, value: offset, to: thanksgiving)
        case .easterOffset(let offset):
            guard let easter = USHoliday.easter(year: year, calendar: calendar) else { return nil }
            return calendar.date(byAdding: .day, value: offset, to: easter)
        }
    }

    /// nth (1-based) `weekday` of `month`/`year`; n = -1 → the last such weekday in the month.
    static func nthWeekday(n: Int, weekday: Int, month: Int, year: Int, calendar: Calendar = .current) -> Date? {
        if n == -1 {
            guard let firstOfNext = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1)),
                  var day = calendar.date(byAdding: .day, value: -1, to: firstOfNext) else { return nil }
            for _ in 0..<7 {
                if calendar.component(.weekday, from: day) == weekday { return calendar.startOfDay(for: day) }
                day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            }
            return nil
        }
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        var offset = weekday - firstWeekday
        if offset < 0 { offset += 7 }
        let day = offset + 1 + (n - 1) * 7
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Western (Gregorian) Easter Sunday — the Anonymous Gregorian "computus" algorithm.
    static func easter(year: Int, calendar: Calendar = .current) -> Date? {
        let a = year % 19
        let b = year / 100, c = year % 100
        let d = b / 4, e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The full American list. Federal + common closures default ON; cultural/religious default OFF.
    static let catalog: [USHoliday] = [
        // Federal
        .init(id: "us.new-years-day", name: "New Year’s Day", group: .federal, defaultOn: true, rule: .fixed(month: 1, day: 1)),
        .init(id: "us.mlk-day", name: "Martin Luther King Jr. Day", group: .federal, defaultOn: true, rule: .nthWeekday(n: 3, weekday: 2, month: 1)),
        .init(id: "us.presidents-day", name: "Presidents’ Day", group: .federal, defaultOn: true, rule: .nthWeekday(n: 3, weekday: 2, month: 2)),
        .init(id: "us.memorial-day", name: "Memorial Day", group: .federal, defaultOn: true, rule: .nthWeekday(n: -1, weekday: 2, month: 5)),
        .init(id: "us.juneteenth", name: "Juneteenth", group: .federal, defaultOn: true, rule: .fixed(month: 6, day: 19)),
        .init(id: "us.independence-day", name: "Independence Day", group: .federal, defaultOn: true, rule: .fixed(month: 7, day: 4)),
        .init(id: "us.labor-day", name: "Labor Day", group: .federal, defaultOn: true, rule: .nthWeekday(n: 1, weekday: 2, month: 9)),
        .init(id: "us.columbus-day", name: "Columbus / Indigenous Peoples’ Day", group: .federal, defaultOn: true, rule: .nthWeekday(n: 2, weekday: 2, month: 10)),
        .init(id: "us.veterans-day", name: "Veterans Day", group: .federal, defaultOn: true, rule: .fixed(month: 11, day: 11)),
        .init(id: "us.thanksgiving", name: "Thanksgiving", group: .federal, defaultOn: true, rule: .nthWeekday(n: 4, weekday: 5, month: 11)),
        .init(id: "us.christmas", name: "Christmas Day", group: .federal, defaultOn: true, rule: .fixed(month: 12, day: 25)),
        // Common closures
        .init(id: "us.christmas-eve", name: "Christmas Eve", group: .commonClosure, defaultOn: true, rule: .fixed(month: 12, day: 24)),
        .init(id: "us.black-friday", name: "Black Friday", group: .commonClosure, defaultOn: true, rule: .relativeToThanksgiving(offsetDays: 1)),
        .init(id: "us.new-years-eve", name: "New Year’s Eve", group: .commonClosure, defaultOn: true, rule: .fixed(month: 12, day: 31)),
        // Cultural & religious (present, default OFF)
        .init(id: "us.valentines", name: "Valentine’s Day", group: .cultural, defaultOn: false, rule: .fixed(month: 2, day: 14)),
        .init(id: "us.st-patricks", name: "St. Patrick’s Day", group: .cultural, defaultOn: false, rule: .fixed(month: 3, day: 17)),
        .init(id: "us.good-friday", name: "Good Friday", group: .cultural, defaultOn: false, rule: .easterOffset(-2)),
        .init(id: "us.easter", name: "Easter Sunday", group: .cultural, defaultOn: false, rule: .easterOffset(0)),
        .init(id: "us.mothers-day", name: "Mother’s Day", group: .cultural, defaultOn: false, rule: .nthWeekday(n: 2, weekday: 1, month: 5)),
        .init(id: "us.fathers-day", name: "Father’s Day", group: .cultural, defaultOn: false, rule: .nthWeekday(n: 3, weekday: 1, month: 6)),
        .init(id: "us.halloween", name: "Halloween", group: .cultural, defaultOn: false, rule: .fixed(month: 10, day: 31)),
    ]

    static func holiday(id: String) -> USHoliday? { catalog.first { $0.id == id } }
}
