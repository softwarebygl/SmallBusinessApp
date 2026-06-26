//
//  WorkScheduleScreen.swift
//  GLSmallBusiness
//
//  The owner's work schedule editor (Settings → Work schedule). Edits the synced WorkSchedule on the
//  BusinessProfile: which weekdays are workdays and their hours, which holidays are taken off, and any
//  vacation / time-off ranges. Availability across the app (next available date, clear date, gaps) is
//  computed from this. Autosaves as you go — it's a settings screen, not a form.
//

import SwiftUI
import SwiftData

struct WorkScheduleScreen: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query private var profiles: [BusinessProfile]

    @State private var schedule = WorkSchedule.standard
    @State private var loaded = false
    @State private var suppressPersist = false

    var body: some View {
        Form {
            Section {
                ForEach(0..<7, id: \.self) { index in
                    Toggle(weekdayName(index), isOn: $schedule.weekdayHours[index].isWorkday)
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
                        Toggle(holiday.name, isOn: holidayEnabled(holiday.id))
                    }
                }
            }

            Section {
                ForEach($schedule.vacations) { $range in
                    DatePicker("From", selection: $range.start, displayedComponents: .date)
                    DatePicker("To", selection: $range.end, displayedComponents: .date)
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
                ForEach(Array(schedule.overrides.enumerated()), id: \.element.id) { index, _ in
                    DatePicker("Date", selection: $schedule.overrides[index].date, displayedComponents: .date)
                    Picker("This day", selection: isCustomHours(index)) {
                        Text("Day off").tag(false)
                        Text("Custom hours").tag(true)
                    }
                    if isCustomHours(index).wrappedValue {
                        HStack {
                            DatePicker("Start", selection: overrideTime(index, start: true), displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: overrideTime(index, start: false), displayedComponents: .hourAndMinute)
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
        .navigationTitle("Work Schedule")
        .toolbarTitleDisplayMode(.large)
        .onAppear {
            guard !loaded else { return }
            suppressPersist = true
            schedule = effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask)
            loaded = true
        }
        .onChange(of: schedule) { _, newValue in
            if suppressPersist { suppressPersist = false; return }
            persist(newValue)
        }
    }

    // MARK: - Persistence

    private func persist(_ newValue: WorkSchedule) {
        let profile: BusinessProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = BusinessProfile()
            modelContext.insert(profile)
        }
        profile.workSchedule = newValue
        modelContext.saveChanges()
    }

    // MARK: - Bindings & helpers

    private func weekdayName(_ index: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols   // [Sunday … Saturday], index 0 = Sunday
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func holidayEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { schedule.holidays.first { $0.id == id }?.enabled ?? false },
            set: { on in
                if let i = schedule.holidays.firstIndex(where: { $0.id == id }) {
                    schedule.holidays[i].enabled = on
                } else {
                    schedule.holidays.append(HolidayState(id: id, enabled: on, oneTimeYear: nil))
                }
            }
        )
    }

    private func timeBinding(day index: Int, start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = start ? schedule.weekdayHours[index].startMinutes
                                    : schedule.weekdayHours[index].endMinutes
                return Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                // Keep start strictly before end so a fat-finger can't set an empty (end ≤ start) window
                // that silently removes the workday from availability.
                if start {
                    schedule.weekdayHours[index].startMinutes = min(minutes, schedule.weekdayHours[index].endMinutes - 1)
                } else {
                    schedule.weekdayHours[index].endMinutes = max(minutes, schedule.weekdayHours[index].startMinutes + 1)
                }
            }
        )
    }

    private func isCustomHours(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { if case .customHours = schedule.overrides[index].kind { return true } else { return false } },
            set: { custom in
                schedule.overrides[index].kind = custom
                    ? .customHours(startMinutes: WorkSchedule.defaultStartMinutes, endMinutes: WorkSchedule.defaultEndMinutes)
                    : .blocked
            }
        )
    }

    private func overrideTime(_ index: Int, start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes: Int
                if case .customHours(let s, let e) = schedule.overrides[index].kind {
                    minutes = start ? s : e
                } else {
                    minutes = start ? WorkSchedule.defaultStartMinutes : WorkSchedule.defaultEndMinutes
                }
                return Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
            },
            set: { newDate in
                guard case .customHours(let s, let e) = schedule.overrides[index].kind else { return }
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                schedule.overrides[index].kind = start
                    ? .customHours(startMinutes: minutes, endMinutes: e)
                    : .customHours(startMinutes: s, endMinutes: minutes)
            }
        )
    }
}
