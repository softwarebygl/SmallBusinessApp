//
//  EmployeeDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  One employee: the payday-due summary up top, then daily hours, recorded paychecks, and the
//  year-to-date totals. Hours and paychecks are added/edited through the two sheets at the bottom
//  of this file. Mirrors CustomerDetailScreen's scaffold (ScrollView + GLCards + monogram backdrop).
//

import SwiftUI
import SwiftData

struct EmployeeDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let employee: Employee

    @State private var activeSheet: ActiveSheet?

    /// One sheet driver for the screen: edit the employee, or add/edit an hours entry or a paycheck
    /// (a nil associated value = "new"). A single `.sheet(item:)` avoids stacking many sheet modifiers.
    private enum ActiveSheet: Identifiable {
        case editEmployee
        case logHours(TimeEntry?)
        case recordPaycheck(Paycheck?)
        var id: String {
            switch self {
            case .editEmployee: "edit"
            case .logHours(let entry): "hours-\(entry?.persistentModelID.hashValue ?? 0)"
            case .recordPaycheck(let check): "check-\(check?.persistentModelID.hashValue ?? 0)"
            }
        }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                paydayCard
                if employee.isOverFortyThisWeek { overtimeFlag }
                hoursCard
                paychecksCard
                ytdCard
                if !employee.notes.isEmpty { notesCard }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(employee.listDisplayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { activeSheet = .editEmployee } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit employee")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .editEmployee:
                EmployeeFormScreen(editing: employee).glAppearance(colorScheme)
            case .logHours(let entry):
                LogHoursSheet(employee: employee, existing: entry).glAppearance(colorScheme)
            case .recordPaycheck(let check):
                RecordPaycheckSheet(employee: employee, existing: check).glAppearance(colorScheme)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(gold.opacity(0.18))
                Text(employee.initials)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(gold)
            }
            .frame(width: 96, height: 96)

            Text(employee.fullName.isEmpty ? employee.listDisplayName : employee.fullName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(paySummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !employee.isActive {
                Text("Inactive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
        }
    }

    private var paySummary: String {
        let rate = employee.payType == .hourly
            ? "\(employee.hourlyRate.formatted(.currency(code: "USD")))/hr"
            : "\(employee.annualSalary.formatted(.currency(code: "USD")))/yr"
        return "\(rate) · \(employee.payFrequency.label)"
    }

    // MARK: - Payday due

    private var paydayCard: some View {
        GLCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT PAYDAY")
                        .font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(employee.nextPayday().formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("DUE")
                        .font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(employee.accruedGross.formatted(.currency(code: "USD")))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(gold)
                }
            }
            if employee.payType == .hourly {
                Text("\(employee.unpaidHours.formatted(.number)) unpaid hours logged.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("One salary period.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { activeSheet = .recordPaycheck(nil) } label: {
                Label("Record this paycheck", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(gold)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var overtimeFlag: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(employee.hoursInWeek().formatted(.number)) hours logged this week — over 40.")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Hours

    private var hoursCard: some View {
        GLCard(title: "Hours") {
            let entries = employee.sortedTimeEntries
            if entries.isEmpty {
                Text("No hours logged yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(10)) { entry in
                    Button { activeSheet = .logHours(entry) } label: { hoursRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != entries.prefix(10).last?.id { Divider() }
                }
                if entries.count > 10 {
                    Text("Showing the 10 most recent of \(entries.count).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            Button { activeSheet = .logHours(nil) } label: {
                Label("Log hours", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func hoursRow(_ entry: TimeEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                if let customer = entry.customer {
                    Text(customer.listDisplayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(entry.hours.formatted(.number)) hr")
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    // MARK: - Paychecks

    private var paychecksCard: some View {
        GLCard(title: "Paychecks") {
            let checks = employee.sortedPaychecks
            if checks.isEmpty {
                Text("No paychecks recorded yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(checks.prefix(10)) { check in
                    Button { activeSheet = .recordPaycheck(check) } label: { paycheckRow(check) }
                        .buttonStyle(.plain)
                    if check.id != checks.prefix(10).last?.id { Divider() }
                }
            }
        }
    }

    private func paycheckRow(_ check: Paycheck) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(check.payDate.formatted(date: .abbreviated, time: .omitted))
                Text("\(check.payPeriodStart.formatted(date: .abbreviated, time: .omitted)) – \(check.payPeriodEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(check.grossAmount.formatted(.currency(code: "USD")))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    // MARK: - YTD + notes

    private var ytdCard: some View {
        GLCard(title: "This year") {
            statRow("Gross paid", employee.ytdGross().formatted(.currency(code: "USD")))
            statRow("Hours", employee.ytdHours().formatted(.number))
            statRow("Paychecks", "\(employee.sortedPaychecks.filter { Calendar.current.component(.year, from: $0.payDate) == Calendar.current.component(.year, from: .now) }.count)")
        }
    }

    private var notesCard: some View {
        GLCard(title: "Notes") {
            Text(employee.notes).font(.subheadline)
        }
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

// MARK: - Log hours sheet

private struct LogHoursSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let employee: Employee
    let existing: TimeEntry?

    @State private var date: Date
    @State private var hours: Double
    @State private var customerID: PersistentIdentifier?
    @State private var note: String

    init(employee: Employee, existing: TimeEntry?) {
        self.employee = employee
        self.existing = existing
        _date = State(initialValue: existing?.date ?? .now)
        _hours = State(initialValue: existing?.hours ?? 0)
        _customerID = State(initialValue: existing?.customer?.persistentModelID)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    LabeledContent("Hours") {
                        AutoClearNumberField(placeholder: "0", value: $hours, style: .number)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Job (optional)") {
                    Picker("Customer", selection: $customerID) {
                        Text("None").tag(PersistentIdentifier?.none)
                        ForEach(customers) { customer in
                            Text(customer.listDisplayName).tag(PersistentIdentifier?.some(customer.persistentModelID))
                        }
                    }
                }
                Section("Note") {
                    TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                }
                if existing != nil {
                    Section {
                        Button(role: .destructive) { delete() } label: { Text("Delete entry") }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle(existing == nil ? "Log Hours" : "Edit Hours")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(hours <= 0)
                }
            }
        }
    }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == customerID }
    }

    private func save() {
        if let entry = existing {
            entry.date = date
            entry.hours = hours
            entry.customer = selectedCustomer
            entry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let entry = TimeEntry(
                date: date, hours: hours,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                rateSnapshot: employee.payType == .hourly ? employee.hourlyRate : 0,
                employee: employee, customer: selectedCustomer
            )
            modelContext.insert(entry)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let entry = existing { modelContext.delete(entry); try? modelContext.save() }
        dismiss()
    }
}

// MARK: - Record paycheck sheet

private struct RecordPaycheckSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let employee: Employee
    let existing: Paycheck?

    @State private var payPeriodStart: Date
    @State private var payPeriodEnd: Date
    @State private var payDate: Date
    @State private var grossAmount: Double
    @State private var hoursPaid: Double
    @State private var method: PaymentMethod
    @State private var note: String

    init(employee: Employee, existing: Paycheck?) {
        self.employee = employee
        self.existing = existing
        let coveredThrough = (employee.paychecks ?? []).map(\.payPeriodEnd).max()
        let start = existing?.payPeriodStart
            ?? coveredThrough.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
            ?? employee.hireDate
        _payPeriodStart = State(initialValue: start)
        _payPeriodEnd = State(initialValue: existing?.payPeriodEnd ?? employee.nextPayday())
        _payDate = State(initialValue: existing?.payDate ?? employee.nextPayday())
        _grossAmount = State(initialValue: existing?.grossAmount ?? employee.accruedGross)
        _hoursPaid = State(initialValue: existing?.hoursPaid ?? (employee.payType == .hourly ? employee.unpaidHours : 0))
        _method = State(initialValue: existing?.method ?? .check)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pay period") {
                    DatePicker("From", selection: $payPeriodStart, displayedComponents: .date)
                    DatePicker("To", selection: $payPeriodEnd, displayedComponents: .date)
                    DatePicker("Paid on", selection: $payDate, displayedComponents: .date)
                }
                Section("Amount") {
                    LabeledContent("Gross") {
                        AutoClearNumberField(placeholder: "$0.00", value: $grossAmount, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                    if employee.payType == .hourly {
                        LabeledContent("Hours") {
                            AutoClearNumberField(placeholder: "0", value: $hoursPaid, style: .number)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Note") {
                    TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                }
                if existing != nil {
                    Section {
                        Button(role: .destructive) { delete() } label: { Text("Delete paycheck") }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle(existing == nil ? "Record Paycheck" : "Edit Paycheck")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(grossAmount <= 0)
                }
            }
        }
    }

    private func save() {
        if let check = existing {
            check.payPeriodStart = payPeriodStart
            check.payPeriodEnd = payPeriodEnd
            check.payDate = payDate
            check.grossAmount = grossAmount
            check.hoursPaid = hoursPaid
            check.method = method
            check.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let check = Paycheck(
                payPeriodStart: payPeriodStart, payPeriodEnd: payPeriodEnd, payDate: payDate,
                grossAmount: grossAmount, hoursPaid: hoursPaid, method: method,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines), employee: employee
            )
            modelContext.insert(check)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let check = existing { modelContext.delete(check); try? modelContext.save() }
        dismiss()
    }
}
