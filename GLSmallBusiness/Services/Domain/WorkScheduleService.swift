//
//  WorkScheduleService.swift
//  GLSmallBusiness
//
//  The work schedule (workdays and hours, holidays, time off, other days off, date overrides) is
//  one Codable value on the business profile. The Work Schedule screen edits that value in place
//  and saves the whole thing on every change — reverting it when the save is refused — so the
//  screen and a tool share two layers here:
//    - the edit rules, as mutating methods on `WorkSchedule` (pure; the screen's controls call
//      them, so the clamps live in one place): a day's start stays before its end, time off never
//      ends before it starts;
//    - the save (`save`), gated on `.saveWorkSchedule`, which finds or creates the profile.
//  Tool-shaped entry points (`setWeekday`, `setHoliday`, `addTimeOff` …) load the effective
//  schedule, apply one edit and save; they refuse what the screen's controls can't produce.
//

import Foundation
import SwiftData

// MARK: - Edit rules (pure)

nonisolated extension WorkSchedule {

    /// Minutes in a day — the latest an end time can be.
    static let minutesPerDay = 24 * 60

    /// Turns a weekday (0 = Sunday … 6 = Saturday) on or off as a workday.
    mutating func setWorkday(_ weekday: Int, _ isWorkday: Bool) {
        guard weekdayHours.indices.contains(weekday) else { return }
        weekdayHours[weekday].isWorkday = isWorkday
    }

    /// Sets a weekday's start, kept strictly before its end (the screen's clamp: a fat-finger can't
    /// leave an empty window that silently drops the day from availability).
    mutating func setStart(_ minutes: Int, weekday: Int) {
        guard weekdayHours.indices.contains(weekday) else { return }
        weekdayHours[weekday].startMinutes = min(minutes, weekdayHours[weekday].endMinutes - 1)
    }

    /// Sets a weekday's end, kept strictly after its start.
    mutating func setEnd(_ minutes: Int, weekday: Int) {
        guard weekdayHours.indices.contains(weekday) else { return }
        weekdayHours[weekday].endMinutes = max(minutes, weekdayHours[weekday].startMinutes + 1)
    }

    /// Takes a built-in holiday off (or works it). Adds its entry when the schedule has none yet.
    mutating func setHoliday(_ id: String, enabled: Bool) {
        if let index = holidays.firstIndex(where: { $0.id == id }) {
            holidays[index].enabled = enabled
        } else {
            holidays.append(HolidayState(id: id, enabled: enabled, oneTimeYear: nil))
        }
    }

    /// Whether a built-in holiday is taken off.
    func isHolidayOff(_ id: String) -> Bool { holidays.first { $0.id == id }?.enabled ?? false }

    /// Moves a time-off range's first day; a To before it is dragged along (one day is valid).
    mutating func setTimeOffStart(_ date: Date, at index: Int) {
        guard vacations.indices.contains(index) else { return }
        vacations[index].start = date
        if vacations[index].end < date { vacations[index].end = date }
    }

    /// Moves a time-off range's last day, never before its first.
    mutating func setTimeOffEnd(_ date: Date, at index: Int) {
        guard vacations.indices.contains(index) else { return }
        vacations[index].end = max(date, vacations[index].start)
    }

    /// Switches an override between "Day off" and "Custom hours" (the default 8–5 window).
    mutating func setOverrideCustomHours(_ custom: Bool, at index: Int) {
        guard overrides.indices.contains(index) else { return }
        overrides[index].kind = custom
            ? .customHours(startMinutes: WorkSchedule.defaultStartMinutes, endMinutes: WorkSchedule.defaultEndMinutes)
            : .blocked
    }

    /// Sets a custom-hours override's start or end, keeping start strictly before end (an empty
    /// window would silently turn it into a day off). Ignored for a "Day off" override.
    mutating func setOverrideTime(_ minutes: Int, start: Bool, at index: Int) {
        guard overrides.indices.contains(index),
              case .customHours(let s, let e) = overrides[index].kind else { return }
        overrides[index].kind = start
            ? .customHours(startMinutes: min(minutes, e - 1), endMinutes: e)
            : .customHours(startMinutes: s, endMinutes: max(minutes, s + 1))
    }

    /// Minutes from midnight of `date`'s hour and minute.
    static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

// MARK: - Saving

@MainActor
enum WorkScheduleService {

    /// The schedule in effect: the saved one, else the standard week under the legacy workdays mask.
    static func current(in context: ModelContext, legacyMask: Int? = nil) -> WorkSchedule {
        ScheduleQueries.schedule(in: context, legacyMask: legacyMask ?? storedLegacyMask)
    }

    /// The device's legacy workdays mask (only read now; nothing writes it any more).
    static var storedLegacyMask: Int {
        UserDefaults.standard.object(forKey: SchedulingPrefs.workdaysMaskKey) as? Int
            ?? SchedulingPrefs.defaultWorkdaysMask
    }

    /// Saves the whole schedule onto the profile (creating the profile if there is none yet).
    static func save(_ schedule: WorkSchedule, in context: ModelContext,
                     subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveWorkSchedule, subscription)
        let profile: BusinessProfile
        if let existing = try? context.fetch(FetchDescriptor<BusinessProfile>()).first {
            profile = existing
        } else {
            profile = BusinessProfile()
            context.insert(profile)
        }
        // Compared as a value, not as bytes: re-encoding an equal schedule must not dirty the row.
        if profile.workScheduleData == nil || profile.workSchedule != schedule {
            setIfChanged(profile, \.workScheduleData, try? JSONEncoder().encode(schedule))
        }
        context.saveChanges()
    }

    // MARK: One edit at a time (the assistant's shape)

    /// A weekday on or off, optionally with new hours (minutes from midnight; start before end).
    @discardableResult
    static func setWeekday(_ weekday: Int, isWorkday: Bool, startMinutes: Int? = nil, endMinutes: Int? = nil,
                           in context: ModelContext, subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            guard schedule.weekdayHours.indices.contains(weekday) else { throw unknown }
            let start = startMinutes ?? schedule.weekdayHours[weekday].startMinutes
            let end = endMinutes ?? schedule.weekdayHours[weekday].endMinutes
            guard (0...WorkSchedule.minutesPerDay).contains(start), (0...WorkSchedule.minutesPerDay).contains(end),
                  start < end else {
                throw DomainGate.refusal(.invalidHours, .saveWorkSchedule)
            }
            schedule.weekdayHours[weekday] = WeekdayHours(isWorkday: isWorkday, startMinutes: start, endMinutes: end)
        }
    }

    /// Takes one of the built-in holidays off, or works it.
    @discardableResult
    static func setHoliday(_ id: String, enabled: Bool, in context: ModelContext,
                           subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            guard USHoliday.catalog.contains(where: { $0.id == id }) else { throw unknown }
            schedule.setHoliday(id, enabled: enabled)
        }
    }

    /// Adds time off, first day through last day (inclusive).
    @discardableResult
    static func addTimeOff(from start: Date, through end: Date, in context: ModelContext,
                           calendar: Calendar = .current,
                           subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
            guard last >= first else { throw DomainGate.refusal(.invalidDateRange, .saveWorkSchedule) }
            schedule.vacations.append(DateRangeRule(start: first, end: last))
        }
    }

    /// Adds a day off that isn't on the holiday list.
    @discardableResult
    static func addDayOff(_ date: Date, label: String = "", repeatsYearly: Bool = false,
                          in context: ModelContext, calendar: Calendar = .current,
                          subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            schedule.customDaysOff.append(CustomDayOff(date: calendar.startOfDay(for: date),
                                                       repeatsYearly: repeatsYearly,
                                                       label: label.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// Blocks one date, or works it with custom hours (start before end).
    @discardableResult
    static func addOverride(_ date: Date, kind: DateOverrideKind, in context: ModelContext,
                            calendar: Calendar = .current,
                            subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            if case .customHours(let s, let e) = kind {
                guard s >= 0, e <= WorkSchedule.minutesPerDay, s < e else {
                    throw DomainGate.refusal(.invalidHours, .saveWorkSchedule)
                }
            }
            schedule.overrides.append(DateOverride(date: calendar.startOfDay(for: date), kind: kind))
        }
    }

    /// Removes a time-off range, day off or override by its id.
    @discardableResult
    static func removeEntry(_ id: UUID, in context: ModelContext,
                            subscription: SubscriptionManager? = nil) throws -> WorkSchedule {
        try edit(in: context, subscription) { schedule in
            let before = schedule.vacations.count + schedule.customDaysOff.count + schedule.overrides.count
            schedule.vacations.removeAll { $0.id == id }
            schedule.customDaysOff.removeAll { $0.id == id }
            schedule.overrides.removeAll { $0.id == id }
            let after = schedule.vacations.count + schedule.customDaysOff.count + schedule.overrides.count
            guard after < before else { throw unknown }
        }
    }

    private static var unknown: DomainError {
        DomainGate.refusal(.unknownScheduleItem, .saveWorkSchedule)
    }

    /// Load the effective schedule, apply one edit, save it. Refused before anything is read when
    /// the app is read-only.
    private static func edit(in context: ModelContext, _ subscription: SubscriptionManager?,
                             _ change: (inout WorkSchedule) throws -> Void) throws -> WorkSchedule {
        try DomainGate.requireWritable(.saveWorkSchedule, subscription)
        var schedule = current(in: context)
        try change(&schedule)
        try save(schedule, in: context, subscription: subscription)
        return schedule
    }
}
