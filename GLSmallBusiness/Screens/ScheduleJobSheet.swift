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
import GoldLifeUI
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

    var serviceAddress: Address {
        switch self {
        case .estimate(let e): e.serviceAddress
        case .invoice(let i): i.serviceAddress
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
    @Query private var profiles: [BusinessProfile]

    let source: ScheduleJobSource

    private var schedule: WorkSchedule { effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask) }

    @State private var startDate: Date = .now
    @State private var durationDays: Int = 1
    @State private var notes: String = ""
    @State private var overlapConfirm = false
    @State private var isSaving = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal JobService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        Form {
            Section {
                LabeledContent("Job", value: source.title.isEmpty ? mbLoc("Job") : source.title)
                if !source.customerName.isEmpty {
                    LabeledContent("Customer", value: source.customerName)
                }
            }
            Section {
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                Stepper(value: $durationDays, in: 1...60) {
                    Text("Length: \(durationDays) workdays")
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
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Schedule Job")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Schedule Job"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Schedule") { attemptSave() }.disabled(isSaving)
            }
        }
        .alert("These dates overlap a job you’ve already booked.",
               isPresented: $overlapConfirm) {
            Button("Schedule anyway") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have “book one job at a time” on. Schedule this on top of the existing job?")
        }
    }

    private var endDateText: String {
        let job = ScheduledJob(startDate: startDate, durationDays: durationDays)
        return job.endDay(schedule: schedule)
            .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))
    }

    private func attemptSave() {
        if oneJobAtATime, overlapsExisting() {
            overlapConfirm = true
        } else {
            save()
        }
    }

    /// The shared overlap check (JobScheduling.overlaps, `.full`), the same one the Job form asks:
    /// this all-day booking's working hours against every existing booking's occupied time
    /// (repeats expanded, bookings that started up to 120 days earlier included).
    private func overlapsExisting() -> Bool {
        let proposal = ScheduledJob(startDate: startDate, durationDays: durationDays)
        return !JobScheduling.overlaps(for: proposal, among: allJobs, schedule: schedule,
                                        rule: .full).isEmpty
    }

    private func save() {
        // A fast double-tap (toolbar Schedule, or "Schedule anyway") can fire again during the
        // dismiss animation and insert a duplicate booking — same guard as JobFormScreen.save().
        // Resettable state (not SaveOnceButton) because a Cancel in the overlap dialog keeps the
        // form open and Schedule must stay tappable.
        guard !isSaving else { return }
        // Lapsed = 100% read-only. Refused before the latch so Schedule stays tappable behind the
        // alert that invites a retry.
        guard ReadOnlyGate.allows(.scheduleJob, into: $readOnlyRefusal) else { return }
        isSaving = true
        do {
            try JobService.schedule(from: source, start: startDate, durationDays: durationDays,
                                    notes: notes, in: modelContext)
        } catch {
            isSaving = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}
