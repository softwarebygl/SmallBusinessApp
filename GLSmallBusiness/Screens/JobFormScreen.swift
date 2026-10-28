//
//  JobFormScreen.swift
//  GLSmallBusiness
//
//  Create or edit a first-class Job from scratch (no estimate/invoice required). Lightweight by design:
//  customer, service address (auto-filled from the customer, editable), title, schedule, an optional
//  agreed price, and notes. Three entry points:
//    • init(customer:)  — from a customer's Jobs list (customer is fixed)
//    • init()           — from the Calendar "New job" action (pick the customer here)
//    • init(editing:)   — edit an existing job
//  Mirrors InvoiceFormScreen's create/edit shape.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct JobFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allCustomers: [Customer]
    @Query private var allJobs: [ScheduledJob]
    @Query private var profiles: [BusinessProfile]
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @AppStorage(SchedulingPrefs.oneJobAtATimeKey) private var oneJobAtATime = true

    /// The customer for a NEW job opened from a customer. `nil` for a from-scratch Calendar job or an edit.
    private let fixedCustomer: Customer?
    private let editingJob: ScheduledJob?

    @State private var pickedCustomer: Customer?
    @State private var title: String
    @State private var startDate: Date
    @State private var durationDays: Int
    @State private var isAllDay: Bool
    @State private var startTime: Date
    @State private var durationMinutes: Int
    @State private var notes: String

    private static var defaultStartTime: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    }
    @State private var hasPrice: Bool
    @State private var agreedPrice: Double
    @State private var street1: String
    @State private var city: String
    @State private var state: String
    @State private var postal: String
    @State private var recurrence: RecurrenceFrequency?
    @State private var recurWeekdayMask: Int = 0
    @State private var recurEndKind: RecurEnd = .never
    @State private var recurEndDate: Date = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now
    @State private var recurCount: Int = 12

    private enum RecurEnd: Hashable { case never, onDate, afterN }

    @State private var overlapConfirm = false
    @State private var isSaving = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal JobService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(customer: Customer) {
        self.fixedCustomer = customer
        self.editingJob = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
        _durationDays = State(initialValue: 1)
        _isAllDay = State(initialValue: true)
        _startTime = State(initialValue: Self.defaultStartTime)
        _durationMinutes = State(initialValue: 120)
        _notes = State(initialValue: "")
        _hasPrice = State(initialValue: false)
        _agreedPrice = State(initialValue: 0)
        let address = customer.address
        _street1 = State(initialValue: address.street1)
        _city = State(initialValue: address.city)
        _state = State(initialValue: address.state)
        _postal = State(initialValue: address.postalCode)
    }

    /// From-scratch (Calendar "New job"), optionally pre-filled to a gap the owner tapped — a multi-day
    /// run (`prefillDays`) or an intra-day window (`prefillWindow`, which makes it a timed job).
    init(prefillStart: Date? = nil, prefillDays: Int? = nil, prefillWindow: DateInterval? = nil) {
        self.fixedCustomer = nil
        self.editingJob = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: prefillWindow?.start ?? prefillStart ?? .now))
        _durationDays = State(initialValue: max(1, prefillDays ?? 1))
        _isAllDay = State(initialValue: prefillWindow == nil)
        _startTime = State(initialValue: prefillWindow?.start ?? Self.defaultStartTime)
        _durationMinutes = State(initialValue: prefillWindow.map { max(30, Int($0.duration / 60)) } ?? 120)
        _notes = State(initialValue: "")
        _hasPrice = State(initialValue: false)
        _agreedPrice = State(initialValue: 0)
        _street1 = State(initialValue: "")
        _city = State(initialValue: "")
        _state = State(initialValue: "")
        _postal = State(initialValue: "")
    }

    init(editing job: ScheduledJob) {
        self.fixedCustomer = nil
        self.editingJob = job
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: job.title)
        _startDate = State(initialValue: job.startDate)
        _durationDays = State(initialValue: job.durationDays)
        _isAllDay = State(initialValue: job.isAllDay)
        _startTime = State(initialValue: job.startTime ?? Self.defaultStartTime)
        _durationMinutes = State(initialValue: job.durationMinutes ?? 120)
        _notes = State(initialValue: job.notes)
        _hasPrice = State(initialValue: job.agreedPrice != nil)
        _agreedPrice = State(initialValue: job.agreedPrice ?? 0)
        let address = job.serviceAddress
        _street1 = State(initialValue: address.street1)
        _city = State(initialValue: address.city)
        _state = State(initialValue: address.state)
        _postal = State(initialValue: address.postalCode)
        _recurrence = State(initialValue: job.recurrenceFrequency)
        _recurWeekdayMask = State(initialValue: job.recurrenceWeekdayMask)
        _recurEndKind = State(initialValue: job.recurrenceEndDate != nil ? .onDate
                                          : (job.recurrenceCount > 0 ? .afterN : .never))
        _recurEndDate = State(initialValue: job.recurrenceEndDate
                                          ?? (Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now))
        _recurCount = State(initialValue: job.recurrenceCount > 0 ? job.recurrenceCount : 12)
    }

    private var isFromScratch: Bool { fixedCustomer == nil && editingJob == nil }

    private var sortedCustomers: [Customer] {
        allCustomers.sorted {
            $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending
        }
    }

    @State private var initialDigest: String?
    private var digest: String {
        "\(String(describing: pickedCustomer?.persistentModelID))|\(title)|\(startDate)|\(durationDays)|\(isAllDay)|\(startTime)|\(durationMinutes)|\(notes)|\(hasPrice)|\(agreedPrice)|\(street1)|\(city)|\(state)|\(postal)|\(String(describing: recurrence))|\(recurWeekdayMask)|\(String(describing: recurEndKind))|\(recurEndDate)|\(recurCount)"
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            if isFromScratch {
                Section("Customer") {
                    Picker("Customer", selection: $pickedCustomer) {
                        Text("Select a customer").tag(Customer?.none)
                        ForEach(sortedCustomers) { customer in
                            Text(customer.listDisplayName).tag(Customer?.some(customer))
                        }
                    }
                }
            }
            Section("Job") {
                TextField("What is the job?", text: $title)
            }
            Section {
                GLAddressField("Street", street: $street1, city: $city, state: $state, zip: $postal)
                    .textContentType(.streetAddressLine1)
                TextField("City", text: $city)
                    .textContentType(.addressCity)
                TextField("State", text: $state)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("ZIP", text: $postal).keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Service address")
            }
            Section {
                Toggle("All-day", isOn: $isAllDay)
                DatePicker("Date", selection: $startDate, displayedComponents: .date)
                if isAllDay {
                    Stepper(value: $durationDays, in: 1...60) {
                        Text("Length: \(durationDays) workdays")
                    }
                } else {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                    Stepper(value: $durationMinutes, in: 30...600, step: 30) {
                        Text("Length: \(Opening.durationLabel(minutes: durationMinutes))")
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text(scheduleFooter).textCase(nil)
            }
            Section {
                Picker("Repeats", selection: $recurrence) {
                    Text("Does not repeat").tag(RecurrenceFrequency?.none)
                    ForEach(RecurrenceFrequency.allCases) { frequency in
                        Text(frequency.label).tag(RecurrenceFrequency?.some(frequency))
                    }
                }
                if let recurrence, recurrence != .monthly {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On these days").font(.caption).foregroundStyle(GLTheme.textSecondary)
                        weekdaySelector
                    }
                }
                if recurrence != nil {
                    Picker("Ends", selection: $recurEndKind) {
                        Text("Never").tag(RecurEnd.never)
                        Text("On date").tag(RecurEnd.onDate)
                        Text("After N visits").tag(RecurEnd.afterN)
                    }
                    if recurEndKind == .onDate {
                        DatePicker("End date", selection: $recurEndDate, displayedComponents: .date)
                    } else if recurEndKind == .afterN {
                        Stepper(value: $recurCount, in: 1...365) {
                            Text("After \(recurCount) visits")
                        }
                    }
                }
            } header: {
                Text("Repeats")
            }
            Section("Price") {
                Toggle("Set an agreed price", isOn: $hasPrice)
                if hasPrice {
                    HStack {
                        Text("Amount")
                        Spacer()
                        // An agreed price is an amount: entered in whole cents (law 60).
                        AutoClearNumberField(placeholder: "0", value: $agreedPrice, style: .currency,
                                             clearsAt: 0, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .navigationTitle(GLScript.padded(editingJob == nil ? mbLoc("New Job") : mbLoc("Edit Job")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editingJob == nil ? mbLoc("New Job") : mbLoc("Edit Job"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editingJob == nil ? "Add" : "Save") { attemptSave() }
                    .disabled(!canSave)
            }
        }
        .onChange(of: pickedCustomer) { _, newValue in
            // Auto-fill the service address from the chosen customer, only if untouched.
            guard let newValue, street1.isEmpty, city.isEmpty, state.isEmpty, postal.isEmpty else { return }
            street1 = newValue.address.street1
            city = newValue.address.city
            state = newValue.address.state
            postal = newValue.address.postalCode
        }
        .alert("This overlaps a job you’ve already booked.",
               isPresented: $overlapConfirm) {
            Button("Schedule anyway") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“Book one job at a time” is on. All-day jobs warn on the same day; timed jobs warn when the times overlap.")
        }
    }

    private var canSave: Bool {
        if editingJob != nil { return true }
        if fixedCustomer != nil { return true }
        return pickedCustomer != nil   // a from-scratch job needs a customer
    }

    /// The owner's effective work schedule (workdays + holidays + vacations + overrides) — drives the
    /// "Ends …" preview and the overlap check so both agree with what the calendar will actually book.
    private var schedule: WorkSchedule { effectiveWorkSchedule(profiles.first, legacyMask: workdaysMask) }

    private var weekdaySelector: some View {
        // Symbols in the app's chosen language; the locale copy leaves the index math untouched.
        var localized = Calendar.current
        localized.locale = MBLocalization.currentLocale
        let symbols = localized.veryShortWeekdaySymbols   // [Sun … Sat], index 0 = Sunday
        let fullSymbols = localized.weekdaySymbols
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let on = recurWeekdayMask & (1 << index) != 0
                Button {
                    recurWeekdayMask ^= (1 << index)
                } label: {
                    Text(symbols[index]).font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(on ? GLTheme.accentFill : GLTheme.textSecondary.opacity(0.15)))
                        .foregroundStyle(on ? GLTheme.onAccent : GLTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)   // ≥44pt tap target; circle stays 32
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fullSymbols[index])
                // An on day reads "Selected" (it was drawn gold and said nothing).
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var scheduleFooter: String {
        isAllDay
            ? mbLoc("Ends \(endDateText). Weekends and off-days are skipped per your work schedule.")
            : mbLoc("A timed job can share a day with other jobs.")
    }

    private var endDateText: String {
        ScheduledJob(startDate: startDate, durationDays: durationDays)
            .endDay(schedule: schedule)
            .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))
    }

    private func attemptSave() {
        if oneJobAtATime, overlapsExisting() {
            overlapConfirm = true
        } else {
            save()
        }
    }

    /// The form's fields as JobService takes them. The form has no Apt/Suite field, so an edit
    /// carries the job's current street2 through untouched.
    private var draft: JobDraft {
        let recurrenceEnd: JobRecurrenceEnd = switch recurEndKind {
        case .never: .never
        case .onDate: .onDate(recurEndDate)
        case .afterN: .afterVisits(recurCount)
        }
        return JobDraft(
            title: title, startDate: startDate, isAllDay: isAllDay, durationDays: durationDays,
            startTime: startTime, durationMinutes: durationMinutes, notes: notes,
            agreedPrice: hasPrice ? agreedPrice : nil,
            serviceAddress: Address(street1: street1, street2: editingJob?.serviceAddress.street2,
                                    city: city, state: state, postalCode: postal),
            recurrence: recurrence.map { JobRecurrence(frequency: $0, weekdayMask: recurWeekdayMask, end: recurrenceEnd) })
    }

    /// The shared overlap check (JobScheduling.overlaps, `.full`): occupied time windows — all-day
    /// jobs fill the working hours, timed jobs only their window — including a booking that started
    /// up to 120 days earlier and runs into this one.
    private func overlapsExisting() -> Bool {
        !JobScheduling.overlaps(for: JobService.proposal(from: draft), among: allJobs,
                                excluding: editingJob, schedule: schedule, rule: .full).isEmpty
    }

    private func save() {
        guard !isSaving else { return }
        // Lapsed = 100% read-only. Refused before the latch so the retry the alert invites is one
        // the Save button can actually take.
        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
        isSaving = true
        // JobService applies the form's rules and saves — the same path the assistant uses.
        do {
            if let editingJob {
                try JobService.update(editingJob, with: draft, origin: .screen, in: modelContext)
            } else {
                try JobService.create(draft, for: fixedCustomer ?? pickedCustomer, origin: .screen, in: modelContext)
            }
        } catch {
            isSaving = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}
