//
//  ContractFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  Create or edit a Contract: customer, title, service address (auto-filled from customer),
//  schedule dates, agreed price, terms, and notes.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct ContractFormScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var allCustomers: [Customer]
    @Query private var allContracts: [Contract]
    @Query private var profiles: [BusinessProfile]

    private let fixedCustomer: Customer?
    private let editingContract: Contract?

    @State private var pickedCustomer: Customer?
    @State private var title: String
    @State private var number: String
    @State private var startDate: Date
    @State private var durationDays: Int
    @State private var isAllDay: Bool
    @State private var startTime: Date
    @State private var durationMinutes: Int
    @State private var hasAgreedPrice: Bool
    @State private var agreedPrice: Double
    @State private var notes: String
    @State private var terms: String

    @State private var serviceStreet1: String
    @State private var serviceStreet2: String
    @State private var serviceCity: String
    @State private var serviceState: String
    @State private var servicePostalCode: String

    @State private var isSaving = false
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?

    private static var defaultStartTime: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    }

    init(customer: Customer) {
        self.fixedCustomer = customer
        self.editingContract = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _number = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
        _durationDays = State(initialValue: 1)
        _isAllDay = State(initialValue: true)
        _startTime = State(initialValue: Self.defaultStartTime)
        _durationMinutes = State(initialValue: 120)
        _hasAgreedPrice = State(initialValue: false)
        _agreedPrice = State(initialValue: 0)
        _notes = State(initialValue: "")
        _terms = State(initialValue: "")

        let sAddr = customer.serviceAddress
        _serviceStreet1 = State(initialValue: sAddr.street1)
        _serviceStreet2 = State(initialValue: sAddr.street2 ?? "")
        _serviceCity = State(initialValue: sAddr.city)
        _serviceState = State(initialValue: sAddr.state)
        _servicePostalCode = State(initialValue: sAddr.postalCode)
    }

    init() {
        self.fixedCustomer = nil
        self.editingContract = nil
        _pickedCustomer = State(initialValue: nil)
        _title = State(initialValue: "")
        _number = State(initialValue: "")
        _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
        _durationDays = State(initialValue: 1)
        _isAllDay = State(initialValue: true)
        _startTime = State(initialValue: Self.defaultStartTime)
        _durationMinutes = State(initialValue: 120)
        _hasAgreedPrice = State(initialValue: false)
        _agreedPrice = State(initialValue: 0)
        _notes = State(initialValue: "")
        _terms = State(initialValue: "")
        _serviceStreet1 = State(initialValue: "")
        _serviceStreet2 = State(initialValue: "")
        _serviceCity = State(initialValue: "")
        _serviceState = State(initialValue: "")
        _servicePostalCode = State(initialValue: "")
    }

    init(editing contract: Contract) {
        self.fixedCustomer = contract.customer
        self.editingContract = contract
        _pickedCustomer = State(initialValue: contract.customer)
        _title = State(initialValue: contract.title)
        _number = State(initialValue: contract.number)
        _startDate = State(initialValue: contract.startDate)
        _durationDays = State(initialValue: contract.durationDays)
        _isAllDay = State(initialValue: contract.isAllDay)
        _startTime = State(initialValue: contract.startTime ?? Self.defaultStartTime)
        _durationMinutes = State(initialValue: contract.durationMinutes ?? 120)
        _hasAgreedPrice = State(initialValue: contract.agreedPrice != nil)
        _agreedPrice = State(initialValue: contract.agreedPrice ?? 0)
        _notes = State(initialValue: contract.notes)
        _terms = State(initialValue: contract.terms)
        _serviceStreet1 = State(initialValue: contract.serviceAddressStreet1)
        _serviceStreet2 = State(initialValue: contract.serviceAddressStreet2)
        _serviceCity = State(initialValue: contract.serviceAddressCity)
        _serviceState = State(initialValue: contract.serviceAddressState)
        _servicePostalCode = State(initialValue: contract.serviceAddressPostalCode)
    }

    private var activeCustomer: Customer? {
        fixedCustomer ?? pickedCustomer
    }

    var body: some View {
        NavigationStack {
            Form {
                if fixedCustomer == nil && editingContract == nil {
                    Section {
                        Picker(mbLoc("Customer"), selection: $pickedCustomer) {
                            Text(mbLoc("Select a customer")).tag(Customer?.none)
                            ForEach(allCustomers) { cust in
                                Text(cust.listDisplayName).tag(Customer?.some(cust))
                            }
                        }
                    } header: {
                        Text(mbLoc("Customer"))
                    }
                    .onChange(of: pickedCustomer) { _, newCust in
                        if let newCust, serviceStreet1.isEmpty {
                            let sAddr = newCust.serviceAddress
                            serviceStreet1 = sAddr.street1
                            serviceStreet2 = sAddr.street2 ?? ""
                            serviceCity = sAddr.city
                            serviceState = sAddr.state
                            servicePostalCode = sAddr.postalCode
                        }
                    }
                } else if let cust = activeCustomer {
                    Section {
                        HStack {
                            Text(mbLoc("Customer"))
                                .foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(cust.listDisplayName)
                                .fontWeight(.semibold)
                        }
                    }
                }

                Section {
                    TextField(mbLoc("Contract Title"), text: $title)
                } header: {
                    Text(mbLoc("Title"))
                }

                Section {
                    GLAddressField("Service street", street: $serviceStreet1, city: $serviceCity, state: $serviceState, zip: $servicePostalCode)
                        .textContentType(.streetAddressLine1)
                    TextField(mbLoc("Apt / Suite (optional)"), text: $serviceStreet2)
                        .textContentType(.streetAddressLine2)
                    TextField(mbLoc("City"), text: $serviceCity)
                        .textContentType(.addressCity)
                    TextField(mbLoc("State"), text: $serviceState)
                        .textContentType(.addressState)
                        .textInputAutocapitalization(.characters)
                    TextField(mbLoc("Postal code"), text: $servicePostalCode)
                        .textContentType(.postalCode)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                } header: {
                    Text(mbLoc("Service Address"))
                }

                Section {
                    DatePicker(mbLoc("Start Date"), selection: $startDate, displayedComponents: .date)
                    Stepper("\(mbLoc("Duration:")) \(durationDays) \(durationDays == 1 ? mbLoc("day") : mbLoc("days"))", value: $durationDays, in: 1...365)
                    Toggle(mbLoc("All-day schedule"), isOn: $isAllDay)
                    if !isAllDay {
                        DatePicker(mbLoc("Start Time"), selection: $startTime, displayedComponents: .hourAndMinute)
                        Stepper("\(mbLoc("Duration:")) \(durationMinutes / 60)h \(durationMinutes % 60)m", value: $durationMinutes, in: 15...720, step: 15)
                    }
                } header: {
                    HStack {
                        Text(mbLoc("Schedule & Dates"))
                        Spacer()
                        InfoButton(text: "Dates scheduled here appear directly in your Calendar tab.", topic: "Contract Schedule")
                    }
                }

                Section {
                    Toggle(mbLoc("Set Agreed Fixed Price"), isOn: $hasAgreedPrice)
                    if hasAgreedPrice {
                        AutoClearNumberField(placeholder: "0", value: $agreedPrice, style: .currency, clearsAt: 0, wholeCents: true)
                    }
                } header: {
                    HStack {
                        Text(mbLoc("Pricing"))
                        Spacer()
                        InfoButton(text: "Optional agreed price. If left off, the contract total is computed from line items and change orders.", topic: "Agreed Price")
                    }
                }

                Section {
                    TextField(mbLoc("Notes for customer (optional)"), text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    TextField(mbLoc("Terms and conditions (optional)"), text: $terms, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text(mbLoc("Notes & Terms"))
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(editingContract == nil ? mbLoc("New Contract") : mbLoc("Edit Contract")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editingContract == nil ? mbLoc("New Contract") : mbLoc("Edit Contract"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mbLoc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mbLoc("Save")) {
                        save()
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        if isSaving { return true }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if activeCustomer == nil { return true }
        return false
    }

    private func save() {
        guard !isSaving else { return }
        guard let customer = activeCustomer else { return }
        guard ReadOnlyGate.allows(.saveJob, into: $readOnlyRefusal) else { return }
        isSaving = true

        let serviceAddress = Address(
            street1: serviceStreet1.trimmingCharacters(in: .whitespacesAndNewlines),
            street2: serviceStreet2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : serviceStreet2.trimmingCharacters(in: .whitespacesAndNewlines),
            city: serviceCity.trimmingCharacters(in: .whitespacesAndNewlines),
            state: serviceState.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: servicePostalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let targetContract: Contract
        if let editing = editingContract {
            targetContract = editing
            targetContract.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            targetContract.customer = customer
            targetContract.customerName = customer.listDisplayName
            targetContract.customerEmail = customer.email
            targetContract.customerPhone = customer.phoneNumber
            targetContract.serviceAddress = serviceAddress
            targetContract.startDate = startDate
            targetContract.durationDays = durationDays
            targetContract.isAllDay = isAllDay
            targetContract.startTime = isAllDay ? nil : startTime
            targetContract.durationMinutes = isAllDay ? nil : durationMinutes
            targetContract.agreedPrice = hasAgreedPrice ? agreedPrice : nil
            targetContract.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            targetContract.terms = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let nextNum = Contract.nextNumber(after: allContracts, profile: profiles.first)
            targetContract = Contract(
                number: nextNum,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                customerName: customer.listDisplayName,
                customerEmail: customer.email,
                customerPhone: customer.phoneNumber,
                startDate: startDate,
                durationDays: durationDays,
                isAllDay: isAllDay,
                startTime: isAllDay ? nil : startTime,
                durationMinutes: isAllDay ? nil : durationMinutes,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                terms: terms.trimmingCharacters(in: .whitespacesAndNewlines),
                serviceAddress: serviceAddress,
                agreedPrice: hasAgreedPrice ? agreedPrice : nil,
                status: .draft,
                customer: customer
            )
            modelContext.insert(targetContract)
        }

        // Keep linked ScheduledJob in sync for the Calendar
        let job: ScheduledJob
        if let existingJob = targetContract.scheduledJob {
            job = existingJob
        } else {
            job = ScheduledJob(customer: customer)
            job.contract = targetContract
            targetContract.scheduledJob = job
            modelContext.insert(job)
        }
        job.title = targetContract.title
        job.customer = customer
        job.customerName = targetContract.customerName
        job.startDate = targetContract.startDate
        job.durationDays = targetContract.durationDays
        job.isAllDay = targetContract.isAllDay
        job.startTime = targetContract.startTime
        job.durationMinutes = targetContract.durationMinutes
        job.notes = targetContract.notes
        job.serviceAddress = targetContract.serviceAddress
        if hasAgreedPrice {
            job.agreedPrice = agreedPrice
        }

        modelContext.saveChanges()
        dismiss()
    }
}
