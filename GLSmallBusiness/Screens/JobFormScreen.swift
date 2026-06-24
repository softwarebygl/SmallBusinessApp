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
    @State private var notes: String
    @State private var hasPrice: Bool
    @State private var agreedPrice: Double
    @State private var street1: String
    @State private var city: String
    @State private var state: String
    @State private var postal: String

    init(customer: Customer) {
        self.fixedCustomer = customer
        self.editingJob = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
        _durationDays = State(initialValue: 1)
        _notes = State(initialValue: "")
        _hasPrice = State(initialValue: false)
        _agreedPrice = State(initialValue: 0)
        let address = customer.address
        _street1 = State(initialValue: address.street1)
        _city = State(initialValue: address.city)
        _state = State(initialValue: address.state)
        _postal = State(initialValue: address.postalCode)
    }

    init() {
        self.fixedCustomer = nil
        self.editingJob = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
        _durationDays = State(initialValue: 1)
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
        _notes = State(initialValue: job.notes)
        _hasPrice = State(initialValue: job.agreedPrice != nil)
        _agreedPrice = State(initialValue: job.agreedPrice ?? 0)
        let address = job.serviceAddress
        _street1 = State(initialValue: address.street1)
        _city = State(initialValue: address.city)
        _state = State(initialValue: address.state)
        _postal = State(initialValue: address.postalCode)
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
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    Stepper(value: $durationDays, in: 1...60) {
                        Text("Length: \(durationDays) \(durationDays == 1 ? "workday" : "workdays")")
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Ends \(endDateText). Weekends and off-days are skipped per your workdays setting.")
                        .textCase(nil)
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
        job.durationDays = max(1, durationDays)
        job.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        job.agreedPrice = hasPrice ? agreedPrice : nil
        job.serviceAddress = Address(
            street1: street1.trimmingCharacters(in: .whitespacesAndNewlines),
            city: city.trimmingCharacters(in: .whitespacesAndNewlines),
            state: state.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: postal.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        modelContext.saveChanges()
        dismiss()
    }
}
