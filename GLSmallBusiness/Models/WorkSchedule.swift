//
//  WorkSchedule.swift
//  GLSmallBusiness
//
//  The owner's work schedule: which weekdays are workdays and their hours, the holidays they take off,
//  vacation ranges, custom days off, and one-off date overrides. Stored as a Codable blob on
//  BusinessProfile (so it syncs across devices) and consumed by the scheduling engine.
//
//  `WorkCalendar` is the pure availability layer over a WorkSchedule: `workingHours(date)` returns the
//  open time window(s) for a day, applying the precedence  date-override → days-off → weekday-setting.
//  Times are stored as minutes from midnight so the config is timezone-free and trivially Codable.
//

import Foundation

// MARK: - Config pieces

nonisolated struct WeekdayHours: Codable, Hashable, Sendable {
    var isWorkday: Bool
    var startMinutes: Int   // minutes from midnight (e.g. 8:00 AM = 480)
    var endMinutes: Int     // e.g. 5:00 PM = 1020
}

nonisolated enum DateOverrideKind: Codable, Hashable, Sendable {
    case blocked
    case customHours(startMinutes: Int, endMinutes: Int)
}

/// A one-off rule for a specific date: either block it, or work it with non-standard hours.
nonisolated struct DateOverride: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: DateOverrideKind
}

/// A vacation (or any multi-day) block, inclusive of both ends.
nonisolated struct DateRangeRule: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
}

/// A user-added day off the built-in holiday list doesn't cover.
nonisolated struct CustomDayOff: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var date: Date
    var repeatsYearly: Bool
    var label: String
}

/// On/off state for a built-in holiday, keyed by its stable id. `oneTimeYear` nil = repeats every year.
nonisolated struct HolidayState: Codable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    var oneTimeYear: Int?
}

nonisolated struct WorkSchedule: Codable, Hashable, Sendable {
    /// Exactly 7 entries; index = Calendar weekday − 1 (0 = Sunday … 6 = Saturday).
    var weekdayHours: [WeekdayHours]
    var holidays: [HolidayState]
    var vacations: [DateRangeRule]
    var customDaysOff: [CustomDayOff]
    var overrides: [DateOverride]

    static let defaultStartMinutes = 8 * 60     // 8:00 AM
    static let defaultEndMinutes = 17 * 60      // 5:00 PM

    /// Mon–Fri 8–5 with the common US holidays enabled — used when nothing is stored yet.
    static var standard: WorkSchedule {
        let week = (0..<7).map { index in
            WeekdayHours(isWorkday: (1...5).contains(index),   // Mon(1)…Fri(5)
                         startMinutes: defaultStartMinutes, endMinutes: defaultEndMinutes)
        }
        let holidays = USHoliday.catalog.map { HolidayState(id: $0.id, enabled: $0.defaultOn, oneTimeYear: nil) }
        return WorkSchedule(weekdayHours: week, holidays: holidays,
                            vacations: [], customDaysOff: [], overrides: [])
    }

    /// Seed from the legacy device-local workdays bitmask so the existing Settings choice carries over.
    static func fromLegacyMask(_ mask: Int) -> WorkSchedule {
        standard.applyingWeekdayMask(mask)
    }

    /// A copy whose 7 weekday workday flags come from the legacy bitmask, leaving hours / holidays /
    /// vacations / overrides intact. Lets the existing Settings workdays picker (which still writes the
    /// @AppStorage mask) drive workdays while holidays etc. come from the stored schedule — the bridge
    /// until the full work-schedule editor lands.
    func applyingWeekdayMask(_ mask: Int) -> WorkSchedule {
        var copy = self
        let resolved = mask == 0 ? SchedulingPrefs.defaultWorkdaysMask : mask
        for index in 0..<min(7, copy.weekdayHours.count) {
            copy.weekdayHours[index].isWorkday = (resolved & (1 << index)) != 0
        }
        return copy
    }
}

// MARK: - Availability (pure)

nonisolated enum WorkCalendar {
    /// The open working window(s) for a date. Empty ⇒ a non-working day. Precedence:
    /// 1) a specific-date override, 2) a day off (enabled holiday / vacation / custom), 3) the weekday.
    static func workingHours(_ date: Date, schedule: WorkSchedule, calendar: Calendar = .current) -> [DateInterval] {
        let day = calendar.startOfDay(for: date)

        if let override = schedule.overrides.first(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            switch override.kind {
            case .blocked: return []
            case .customHours(let start, let end): return interval(on: day, start, end, calendar)
            }
        }

        if isDayOff(day, schedule: schedule, calendar: calendar) { return [] }

        let index = calendar.component(.weekday, from: day) - 1
        guard schedule.weekdayHours.indices.contains(index) else { return [] }
        let hours = schedule.weekdayHours[index]
        return hours.isWorkday ? interval(on: day, hours.startMinutes, hours.endMinutes, calendar) : []
    }

    static func isWorkday(_ date: Date, schedule: WorkSchedule, calendar: Calendar = .current) -> Bool {
        !workingHours(date, schedule: schedule, calendar: calendar).isEmpty
    }

    /// True when an enabled holiday, a vacation range, or a custom day off blocks this date. (An
    /// *unchecked* holiday does not block — it falls through to the weekday setting.)
    static func isDayOff(_ date: Date, schedule: WorkSchedule, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)

        for vacation in schedule.vacations {
            let start = calendar.startOfDay(for: vacation.start)
            let end = calendar.startOfDay(for: vacation.end)
            if day >= start && day <= end { return true }
        }

        for custom in schedule.customDaysOff {
            if custom.repeatsYearly {
                if sameMonthDay(custom.date, day, calendar) { return true }
            } else if calendar.isDate(custom.date, inSameDayAs: day) {
                return true
            }
        }

        let year = calendar.component(.year, from: day)
        for state in schedule.holidays where state.enabled {
            if let only = state.oneTimeYear, only != year { continue }
            guard let holiday = USHoliday.holiday(id: state.id),
                  let holidayDate = holiday.date(in: year, calendar: calendar) else { continue }
            if calendar.isDate(holidayDate, inSameDayAs: day) { return true }
        }
        return false
    }

    private static func interval(on day: Date, _ startMinutes: Int, _ endMinutes: Int,
                                 _ calendar: Calendar) -> [DateInterval] {
        guard endMinutes > startMinutes,
              let start = calendar.date(byAdding: .minute, value: startMinutes, to: day),
              let end = calendar.date(byAdding: .minute, value: endMinutes, to: day) else { return [] }
        return [DateInterval(start: start, end: end)]
    }

    private static func sameMonthDay(_ a: Date, _ b: Date, _ calendar: Calendar) -> Bool {
        let ca = calendar.dateComponents([.month, .day], from: a)
        let cb = calendar.dateComponents([.month, .day], from: b)
        return ca.month == cb.month && ca.day == cb.day
    }
}
