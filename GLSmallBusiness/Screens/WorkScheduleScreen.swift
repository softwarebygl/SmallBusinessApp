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
                if start { schedule.weekdayHours[index].startMinutes = minutes }
                else { schedule.weekdayHours[index].endMinutes = minutes }
            }
        )
    }
}
