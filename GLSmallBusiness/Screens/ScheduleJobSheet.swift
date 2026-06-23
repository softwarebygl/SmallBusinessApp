//
//  ScheduleJobSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Schedules a job onto the calendar from an accepted estimate or an invoice (never free-form). Pick
//  a start date + how many workdays; the job carries a snapshot of the title + customer. When "book
//  one job at a time" is on, overlapping an existing booking asks before double-booking (never blocks).
//

import SwiftUI
import SwiftData

/// What a calendar booking is created from — always an estimate or an invoice.
enum ScheduleJobSource {
    case estimate(Estimate)
    case invoice(Invoice)

    var title: String {
        switch self {
        case .estimate(let e): e.jobTitle
        case .invoice(let i): i.jobTitle
        }
    }

    var customerName: String {
        switch self {
        case .estimate(let e): e.customerDisplayName
        case .invoice(let i): i.customerDisplayName
        }
    }
}

struct ScheduleJobSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @AppStorage(SchedulingPrefs.oneJobAtATimeKey) private var oneJobAtATime = true
    @Query private var allJobs: [ScheduledJob]

    let source: ScheduleJobSource

    @State private var startDate: Date = .now
    @State private var durationDays: Int = 1
    @State private var notes: String = ""
    @State private var overlapConfirm = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Job", value: source.title.isEmpty ? "Job" : source.title)
                    if !source.customerName.isEmpty {
                        LabeledContent("Customer", value: source.customerName)
                    }
                }
                Section {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    Stepper(value: $durationDays, in: 1...60) {
                        Text("Length: \(durationDays) \(durationDays == 1 ? "workday" : "workdays")")
                    }
                } footer: {
                    Text("Ends \(endDateText). Weekends and off-days are skipped per your workdays setting.")
                        .textCase(nil)
                }
                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .glFormBackground()
            .navigationTitle("Schedule Job")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Schedule") { attemptSave() } }
            }
            .confirmationDialog("These dates overlap a job you've already booked.",
                                isPresented: $overlapConfirm, titleVisibility: .visible) {
                Button("Schedule anyway") { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You have “book one job at a time” on. Schedule this on top of the existing job?")
            }
        }
    }

    private var endDateText: String {
        let job = ScheduledJob(startDate: startDate, durationDays: durationDays)
        return job.endDay(mask: workdaysMask).formatted(date: .abbreviated, time: .omitted)
    }

    private func attemptSave() {
        if oneJobAtATime, overlapsExisting() {
            overlapConfirm = true
        } else {
            save()
        }
    }

    /// True if the proposed job's workdays intersect any existing booking's workdays.
    private func overlapsExisting() -> Bool {
        let proposed = Set(ScheduledJob(startDate: startDate, durationDays: durationDays)
            .occupiedDays(mask: workdaysMask))
        let booked = SchedulingEngine.occupiedDays(allJobs, mask: workdaysMask)
        return !proposed.isDisjoint(with: booked)
    }

    private func save() {
        let job = ScheduledJob(
            title: source.title,
            customerName: source.customerName,
            startDate: startDate,
            durationDays: durationDays,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        switch source {
        case .estimate(let e): job.estimate = e
        case .invoice(let i): job.invoice = i
        }
        modelContext.insert(job)
        modelContext.saveChanges()
        dismiss()
    }
}
