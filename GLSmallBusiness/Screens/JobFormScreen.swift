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
import SwiftData

struct JobFormScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allCustomers: [Customer]

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

    var body: some View {
        NavigationStack {
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
                    AddressSearchButton(street1: $street1, city: $city, state: $state, postalCode: $postal)
                    TextField("Street", text: $street1)
                    TextField("City", text: $city)
                    TextField("State", text: $state)
                    TextField("ZIP", text: $postal).keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("Service address")
                }
                Section {
                    Toggle("All-day", isOn: $isAllDay)
                    DatePicker("Date", selection: $startDate, displayedComponents: .date)
                    if isAllDay {
                        Stepper(value: $durationDays, in: 1...60) {
                            Text("Length: \(durationDays) \(durationDays == 1 ? "workday" : "workdays")")
                        }
                    } else {
                        DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                        Stepper(value: $durationMinutes, in: 30...600, step: 30) {
                            Text("Length: \(durationLabel)")
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
                            Text("On these days").font(.caption).foregroundStyle(.secondary)
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
                                Text("After \(recurCount) \(recurCount == 1 ? "visit" : "visits")")
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
                            TextField("0", value: $agreedPrice, format: .currency(code: currencyCode))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .glFormBackground()
            .navigationTitle(editingJob == nil ? "New Job" : "Edit Job")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SaveOnceButton(disabled: !canSave, action: save)
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
        }
    }

    private var canSave: Bool {
        if editingJob != nil { return true }
        if fixedCustomer != nil { return true }
        return pickedCustomer != nil   // a from-scratch job needs a customer
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    private var durationLabel: String {
        let hours = durationMinutes / 60, minutes = durationMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours) hr \(minutes) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }

    private var weekdaySelector: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols   // [Sun … Sat], index 0 = Sunday
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let on = recurWeekdayMask & (1 << index) != 0
                Button {
                    recurWeekdayMask ^= (1 << index)
                } label: {
                    Text(symbols[index]).font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(on ? GLColor.gold.render(in: colorScheme) : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[index])
            }
        }
    }

    private var scheduleFooter: String {
        isAllDay
            ? "Ends \(endDateText). Weekends and off-days are skipped per your work schedule."
            : "A timed job can share a day with other jobs."
    }

    private var endDateText: String {
        ScheduledJob(startDate: startDate, durationDays: durationDays)
            .endDay(mask: SchedulingPrefs.defaultWorkdaysMask)
            .formatted(date: .abbreviated, time: .omitted)
    }

    private func save() {
        let job: ScheduledJob
        if let editingJob {
            job = editingJob
        } else {
            job = ScheduledJob()
            if let target = fixedCustomer ?? pickedCustomer {
                job.customer = target
                job.customerName = target.listDisplayName
            }
            modelContext.insert(job)
        }

        job.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        job.startDate = Calendar.current.startOfDay(for: startDate)
        job.isAllDay = isAllDay
        if isAllDay {
            job.durationDays = max(1, durationDays)
            job.startTime = nil
            job.durationMinutes = nil
        } else {
            job.durationDays = 1
            let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
            job.startTime = Calendar.current.date(bySettingHour: comps.hour ?? 9, minute: comps.minute ?? 0,
                                                  second: 0, of: job.startDate)
            job.durationMinutes = max(30, durationMinutes)
        }
        job.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        job.agreedPrice = hasPrice ? agreedPrice : nil
        job.serviceAddress = Address(
            street1: street1.trimmingCharacters(in: .whitespacesAndNewlines),
            city: city.trimmingCharacters(in: .whitespacesAndNewlines),
            state: state.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: postal.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        job.recurrenceFrequency = recurrence
        if recurrence != nil {
            job.recurrenceWeekdayMask = recurWeekdayMask
            job.recurrenceEndDate = recurEndKind == .onDate ? Calendar.current.startOfDay(for: recurEndDate) : nil
            job.recurrenceCount = recurEndKind == .afterN ? max(1, recurCount) : 0
        } else {
            job.recurrenceWeekdayMask = 0
            job.recurrenceEndDate = nil
            job.recurrenceCount = 0
        }

        modelContext.saveChanges()
        dismiss()
    }
}
