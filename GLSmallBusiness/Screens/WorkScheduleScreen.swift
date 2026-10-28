//
//  WorkScheduleScreen.swift
//  GLSmallBusiness
//
//  The owner's work schedule editor (Settings → Work schedule). Edits the synced WorkSchedule on the
//  BusinessProfile: which weekdays are workdays and their hours, which holidays are taken off, and any
//  vacation / time-off ranges. Availability across the app (next available date, clear date, gaps) is
//  computed from this. Autosaves as you go — it's a settings screen, not a form.
//

import GoldLifeUI
import SwiftUI
import SwiftData

struct WorkScheduleScreen: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query private var profiles: [BusinessProfile]

    @State private var schedule = WorkSchedule.standard
    @State private var loaded = false
    @State private var suppressPersist = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal WorkScheduleService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    var body: some View {
        Form {
            Section {
                ForEach(0..<7, id: \.self) { index in
                    Toggle(Self.weekdayName(index), isOn: $schedule.weekdayHours[index].isWorkday)
                    if schedule.weekdayHours[index].isWorkday {
                        HStack {
                            DatePicker("Start", selection: timeBinding(day: index, start: true),
                                       displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: timeBinding(day: index, start: false),
                                       displayedComponents: .hourAndMinute)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Workdays & hours")
            } footer: {
                Text("Hours bound the openings shown for timed jobs. All-day jobs just use whole workdays.")
            }

            ForEach(HolidayGroup.allCases) { group in
                Section(group.title) {
                    ForEach(USHoliday.catalog.filter { $0.group == group }) { holiday in
                        Toggle(holiday.localizedName, isOn: holidayEnabled(holiday.id))
                    }
                }
            }

            Section {
                ForEach($schedule.vacations) { $range in
                    DatePicker("From", selection: Self.timeOffDate(range, start: true, in: $schedule),
                               displayedComponents: .date)
                    DatePicker("To", selection: Self.timeOffDate(range, start: false, in: $schedule),
                               displayedComponents: .date)
                }
                .onDelete { schedule.vacations.remove(atOffsets: $0) }
                Button {
                    let start = Calendar.current.startOfDay(for: .now)
                    let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
                    schedule.vacations.append(DateRangeRule(start: start, end: end))
                } label: {
                    Label("Add time off", systemImage: "plus")
                }
            } header: {
                Text("Time off")
            } footer: {
                Text("Vacation or any stretch you’re unavailable. These days are skipped just like holidays.")
            }

            Section {
                ForEach($schedule.customDaysOff) { $day in
                    DatePicker("Date", selection: $day.date, displayedComponents: .date)
                    TextField("Label (optional)", text: $day.label)
                    Toggle("Repeats every year", isOn: $day.repeatsYearly)
                }
                .onDelete { schedule.customDaysOff.remove(atOffsets: $0) }
                Button {
                    schedule.customDaysOff.append(CustomDayOff(date: Calendar.current.startOfDay(for: .now),
                                                               repeatsYearly: false, label: ""))
                } label: {
                    Label("Add a day off", systemImage: "plus")
                }
            } header: {
                Text("Other days off")
            } footer: {
                Text("A single day you take off that isn’t on the holiday list.")
            }

            Section {
                ForEach($schedule.overrides) { $override in
                    DatePicker("Date", selection: $override.date, displayedComponents: .date)
                    Picker("This day", selection: Self.overrideIsCustomHours(override, in: $schedule)) {
                        Text("Day off").tag(false)
                        Text("Custom hours").tag(true)
                    }
                    if case .customHours = override.kind {
                        HStack {
                            DatePicker("Start", selection: Self.overrideTime(override, start: true, in: $schedule),
                                       displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: Self.overrideTime(override, start: false, in: $schedule),
                                       displayedComponents: .hourAndMinute)
                        }
                    }
                }
                .onDelete { schedule.overrides.remove(atOffsets: $0) }
                Button {
                    schedule.overrides.append(DateOverride(date: Calendar.current.startOfDay(for: .now), kind: .blocked))
                } label: {
                    Label("Add a date override", systemImage: "plus")
                }
            } header: {
                Text("Specific-date overrides")
            } footer: {
                Text("Work or block a single date — e.g. work this Saturday 9–1, or take a specific Tuesday off. Overrides win over everything else.")
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Work Schedule")))
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Work Schedule"))), for: .scrollContent)   // per-string descender clearance
        .toolbarTitleDisplayMode(.large)
        .onAppear {
            guard !loaded else { return }
            suppressPersist = true
            schedule = effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask)
            loaded = true
        }
        .onChange(of: schedule) { oldValue, newValue in
            if suppressPersist { suppressPersist = false; return }
            // Every control on this screen edits `schedule` directly, so the refusal has to put the
            // whole value back — otherwise the toggle stays flipped on screen while nothing is
            // stored, which reads as a save that worked. `suppressPersist` keeps the restore from
            // re-entering this handler.
            guard ReadOnlyGate.allows(.saveWorkSchedule, into: $readOnlyRefusal) else {
                suppressPersist = true
                schedule = oldValue
                return
            }
            // WorkScheduleService finds or creates the profile and saves — the path the assistant
            // uses. A refusal it throws puts the value back the same way.
            do {
                try WorkScheduleService.save(newValue, in: modelContext)
            } catch {
                suppressPersist = true
                schedule = oldValue
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            }
        }
    }

    // MARK: - Bindings & helpers

    /// A weekday's name in the app's language (law 25): the Spanish app read Sunday…Saturday
    /// (QA 2026-10-03 F44). Index 0 is Sunday; out of range is blank, never a trap.
    static func weekdayName(_ index: Int, calendar: Calendar = .appLanguage) -> String {
        let symbols = calendar.weekdaySymbols   // [Sunday … Saturday], index 0 = Sunday
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func holidayEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { schedule.isHolidayOff(id) },
            set: { schedule.setHoliday(id, enabled: $0) }
        )
    }

    private func timeBinding(day index: Int, start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = start ? schedule.weekdayHours[index].startMinutes
                                    : schedule.weekdayHours[index].endMinutes
                return Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes) * 60)
            },
            set: { newDate in
                // The clamp (start strictly before end) lives in WorkSchedule's edit rules.
                let minutes = WorkSchedule.minutes(of: newDate)
                if start {
                    schedule.setStart(minutes, weekday: index)
                } else {
                    schedule.setEnd(minutes, weekday: index)
                }
            }
        )
    }

    // Rows are bound to their element (`ForEach($schedule.vacations)`), and the builders below
    // take the row's VALUE, never a position. A swipe-delete removes the element while SwiftUI
    // can still read the old row's bindings once more; reading by position then traps "Index
    // out of range" (QA F60). These are static so the tests can drive them without a view.

    /// From/To for a time-off range, kept From ≤ To (same idea as timeBinding's clamp) — a backwards
    /// range would silently match no days, so the "time off" would never block anything. A row
    /// already deleted reads its last value and drops a late write.
    static func timeOffDate(_ range: DateRangeRule, start: Bool,
                            in schedule: Binding<WorkSchedule>) -> Binding<Date> {
        func current() -> DateRangeRule {
            schedule.wrappedValue.vacations.first { $0.id == range.id } ?? range
        }
        return Binding(
            get: { start ? current().start : current().end },
            set: { newDate in
                guard let index = schedule.wrappedValue.vacations.firstIndex(where: { $0.id == range.id }) else { return }
                // Moving From past To drags To along; To never moves before From.
                if start {
                    schedule.wrappedValue.setTimeOffStart(newDate, at: index)
                } else {
                    schedule.wrappedValue.setTimeOffEnd(newDate, at: index)
                }
            }
        )
    }

    /// "Day off" / "Custom hours" for one override row.
    static func overrideIsCustomHours(_ override: DateOverride, in schedule: Binding<WorkSchedule>) -> Binding<Bool> {
        Binding(
            get: {
                let kind = schedule.wrappedValue.overrides.first { $0.id == override.id }?.kind ?? override.kind
                if case .customHours = kind { return true } else { return false }
            },
            set: { custom in
                guard let index = schedule.wrappedValue.overrides.firstIndex(where: { $0.id == override.id }) else { return }
                schedule.wrappedValue.setOverrideCustomHours(custom, at: index)
            }
        )
    }

    /// A custom-hours override's start or end time.
    static func overrideTime(_ override: DateOverride, start: Bool,
                             in schedule: Binding<WorkSchedule>) -> Binding<Date> {
        Binding(
            get: {
                let kind = schedule.wrappedValue.overrides.first { $0.id == override.id }?.kind ?? override.kind
                let minutes: Int
                if case .customHours(let s, let e) = kind {
                    minutes = start ? s : e
                } else {
                    minutes = start ? WorkSchedule.defaultStartMinutes : WorkSchedule.defaultEndMinutes
                }
                return Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes) * 60)
            },
            set: { newDate in
                guard let index = schedule.wrappedValue.overrides.firstIndex(where: { $0.id == override.id }) else { return }
                // Start stays strictly before end (WorkSchedule.setOverrideTime), so a custom-hours
                // override can't silently become a day off.
                schedule.wrappedValue.setOverrideTime(WorkSchedule.minutes(of: newDate), start: start, at: index)
            }
        )
    }
}
