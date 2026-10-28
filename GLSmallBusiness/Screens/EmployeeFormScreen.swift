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

import GoldLifeUI
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
    /// Set when a lapsed subscription refuses this save — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EmployeeService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

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

    @State private var initialDigest: String?
    private var digest: String {
        "\(firstName)|\(lastName)|\(email)|\(phone)|\(payType.rawValue)|\(hourlyRate)|\(annualSalary)|\(payFrequency.rawValue)|\(anchorPayday)|\(hireDate)|\(isActive)|\(notes)"
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            if editing == nil {
                Section {
                    HStack {
                        Button { showingContactPicker = true } label: {
                            Label("Import from Phone Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        InfoButton(text: "Pull a name, phone, and email straight from your phone's contacts.", topic: "Import from Phone Contacts")
                    }
                }
            }

            Section("Name") {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
            }

            Section("Contact") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if !os(macOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                PhoneTextField(placeholder: "Phone", text: $phone)
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
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView { contact in
                let draft = ContactsBridge.draft(from: contact)
                firstName = draft.firstName; lastName = draft.lastName
                email = draft.email; phone = draft.phoneNumber
                // Only when the contact carried one — never blank an existing photo.
                if let photo = draft.imageData { importedPhoto = photo }
                showingContactPicker = false
            } onCancel: {
                showingContactPicker = false
            }
            .ignoresSafeArea()
        }
        .navigationTitle(GLScript.padded(editing == nil ? mbLoc("New Employee") : mbLoc("Edit Employee")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editing == nil ? mbLoc("New Employee") : mbLoc("Edit Employee"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !isValid, action: save)
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    /// A photo carried in from the Contacts picker, applied on save.
    @State private var importedPhoto: Data?

    @discardableResult
    private func save() -> Bool {
        // Lapsed = 100% read-only. Refuse BEFORE touching a single property: SwiftData autosaves,
        // so a half-applied edit would persist even though the form said no.
        guard ReadOnlyGate.allows(.saveEmployee, into: $readOnlyRefusal) else { return false }
        // EmployeeService trims, validates and saves — the same path the assistant uses.
        let draft = EmployeeDraft(
            firstName: firstName, lastName: lastName, email: email, phone: phone,
            payType: payType, hourlyRate: hourlyRate, annualSalary: annualSalary,
            payFrequency: payFrequency, anchorPayday: anchorPayday, hireDate: hireDate,
            isActive: isActive, notes: notes
        )
        let saved: Employee
        do {
            if let employee = editing {
                try EmployeeService.update(employee, with: draft, photo: importedPhoto, in: modelContext)
                saved = employee
            } else {
                saved = try EmployeeService.create(draft, photo: importedPhoto, in: modelContext)
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        // The add flow's onSave replaces the navigation path itself; dismissing on top of that
        // is a second stack mutation in the same tick — the exact blank-screen push. One owner.
        if let onSave { onSave(saved) } else { dismiss() }
        return true
    }
}

#Preview("Add") {
    EmployeeFormScreen()
        .modelContainer(for: Employee.self, inMemory: true)
}
