//
//  EmployeeFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Add / edit an employee. Mirrors CustomerFormScreen: a pushed Form with the cream
//  `glFormBackground`, a trailing Save (the back button replaces Cancel), and an `onSave`
//  callback so a new employee can be auto-selected on iPad.
//

import SwiftUI
import SwiftData

struct EmployeeFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let editing: Employee?
    var onSave: ((Employee) -> Void)? = nil

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var phone: String
    @State private var payType: PayType
    @State private var hourlyRate: Double
    @State private var annualSalary: Double
    @State private var payFrequency: PayFrequency
    @State private var anchorPayday: Date
    @State private var hireDate: Date
    @State private var isActive: Bool
    @State private var notes: String
    @State private var showingContactPicker = false

    init(editing: Employee? = nil, onSave: ((Employee) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _firstName     = State(initialValue: editing?.firstName ?? "")
        _lastName      = State(initialValue: editing?.lastName ?? "")
        _email         = State(initialValue: editing?.email ?? "")
        _phone         = State(initialValue: editing?.phone ?? "")
        _payType       = State(initialValue: editing?.payType ?? .hourly)
        _hourlyRate    = State(initialValue: editing?.hourlyRate ?? 0)
        _annualSalary  = State(initialValue: editing?.annualSalary ?? 0)
        _payFrequency  = State(initialValue: editing?.payFrequency ?? .weekly)
        _anchorPayday  = State(initialValue: editing?.anchorPayday ?? .now)
        _hireDate      = State(initialValue: editing?.hireDate ?? .now)
        _isActive      = State(initialValue: editing?.isActive ?? true)
        _notes         = State(initialValue: editing?.notes ?? "")
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool { !trim(firstName).isEmpty || !trim(lastName).isEmpty }

    var body: some View {
        Form {
            if editing == nil {
                Section {
                    HStack {
                        Button { showingContactPicker = true } label: {
                            Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        InfoButton(text: "Pull a name, phone, and email straight from your phone's contacts.")
                    }
                }
            }

            Section("Name") {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
            }

            Section("Contact") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if !os(macOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("Phone", text: $phone)
                    .textContentType(.telephoneNumber)
                    #if !os(macOS)
                    .keyboardType(.phonePad)
                    #endif
            }

            Section("Pay") {
                Picker("Pay type", selection: $payType) {
                    ForEach(PayType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if payType == .hourly {
                    LabeledContent("Hourly rate") {
                        AutoClearNumberField(placeholder: "$0.00", value: $hourlyRate, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("Annual salary") {
                        AutoClearNumberField(placeholder: "$0", value: $annualSalary, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Picker("Pays", selection: $payFrequency) {
                    ForEach(PayFrequency.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Next payday", selection: $anchorPayday, displayedComponents: .date)
            }

            Section("Employment") {
                DatePicker("Hire date", selection: $hireDate, displayedComponents: .date)
                Toggle("Active", isOn: $isActive)
            }

            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .glFormBackground()
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView { contact in
                let draft = ContactsBridge.draft(from: contact)
                firstName = draft.firstName; lastName = draft.lastName
                email = draft.email; phone = draft.phoneNumber
                showingContactPicker = false
            } onCancel: {
                showingContactPicker = false
            }
            .ignoresSafeArea()
        }
        .navigationTitle(editing == nil ? "New Employee" : "Edit Employee")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !isValid, action: save)
            }
        }
    }

    private func save() {
        let saved: Employee
        if let employee = editing {
            employee.firstName = trim(firstName)
            employee.lastName = trim(lastName)
            employee.email = trim(email)
            employee.phone = trim(phone)
            employee.payType = payType
            employee.hourlyRate = hourlyRate
            employee.annualSalary = annualSalary
            employee.payFrequency = payFrequency
            employee.anchorPayday = anchorPayday
            employee.hireDate = hireDate
            employee.isActive = isActive
            employee.notes = trim(notes)
            saved = employee
        } else {
            let employee = Employee(
                firstName: trim(firstName), lastName: trim(lastName),
                email: trim(email), phone: trim(phone),
                payType: payType, hourlyRate: hourlyRate, annualSalary: annualSalary,
                payFrequency: payFrequency, anchorPayday: anchorPayday,
                hireDate: hireDate, isActive: isActive, notes: trim(notes)
            )
            modelContext.insert(employee)
            saved = employee
        }
        onSave?(saved)
        dismiss()
    }
}

#Preview("Add") {
    EmployeeFormScreen()
        .modelContainer(for: Employee.self, inMemory: true)
}
