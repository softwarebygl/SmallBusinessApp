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
    @State private var showingSaveToContacts = false

    /// One sheet driver for the screen: edit the employee, add/edit an hours entry or a paycheck
    /// (nil = "new"), or view all hours. A single `.sheet(item:)` avoids stacking many sheet modifiers.
    private enum ActiveSheet: Identifiable {
        case logHours(TimeEntry?)
        case recordPaycheck(Paycheck?)
        case allHours
        case allPaychecks
        var id: String {
            switch self {
            case .logHours(let entry): "hours-\(entry?.persistentModelID.hashValue ?? 0)"
            case .recordPaycheck(let check): "check-\(check?.persistentModelID.hashValue ?? 0)"
            case .allHours: "allHours"
            case .allPaychecks: "allPaychecks"
            }
        }
    }

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                moreInfoRow
                VStack(alignment: .leading, spacing: 12) {
                    GLSectionHeader(title: "Payroll")
                    paydayCard
                    if employee.isOverFortyThisWeek { overtimeFlag }
                    hoursCard
                    paychecksCard
                    ytdCard
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(employee.listDisplayName)
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingSaveToContacts = true } label: {
                        Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .logHours(let entry):
                LogHoursSheet(employee: employee, existing: entry).glAppearance(colorScheme)
            case .recordPaycheck(let check):
                RecordPaycheckSheet(employee: employee, existing: check).glAppearance(colorScheme)
            case .allHours:
                AllHoursSheet(employee: employee).glAppearance(colorScheme)
            case .allPaychecks:
                AllPaychecksSheet(employee: employee).glAppearance(colorScheme)
            }
        }
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: employee)) { showingSaveToContacts = false }
                .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            MonogramAvatar(initials: employee.initials, size: 110)

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

    private var contactCard: some View {
        GLCard(title: "Contact") {
            infoRow("Email", employee.email)
            infoRow("Phone", employee.phone)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }

    private var moreInfoRow: some View {
        NavigationLink {
            EmployeeDetailsScreen(employee: employee)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .frame(width: 24)
                    .foregroundStyle(gold)
                Text("More Info")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
        }
        .buttonStyle(.plain)
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
        GLCard {
            let entries = employee.sortedTimeEntries
            HStack {
                Text("Hours").font(.headline)
                Spacer()
                if entries.count > 5 {
                    Button("View All") { activeSheet = .allHours }
                        .font(.subheadline.weight(.medium)).foregroundStyle(gold)
                }
            }
            if entries.isEmpty {
                Text("No hours logged yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let recent = Array(entries.prefix(5))
                ForEach(recent) { entry in
                    Button { activeSheet = .logHours(entry) } label: { hoursRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != recent.last?.id { Divider() }
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
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    // MARK: - Paychecks

    private var paychecksCard: some View {
        GLCard {
            let checks = employee.sortedPaychecks
            HStack {
                Text("Paychecks").font(.headline)
                Spacer()
                if checks.count > 5 {
                    Button("View All") { activeSheet = .allPaychecks }
                        .font(.subheadline.weight(.medium)).foregroundStyle(gold)
                }
            }
            if checks.isEmpty {
                Text("No paychecks recorded yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let recent = Array(checks.prefix(5))
                ForEach(recent) { check in
                    Button { activeSheet = .recordPaycheck(check) } label: { paycheckRow(check) }
                        .buttonStyle(.plain)
                    if check.id != recent.last?.id { Divider() }
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
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
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

    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

// MARK: - All hours sheet (full, date-filterable list)

private struct AllHoursSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let employee: Employee

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: TimeEntry?

    private var filtered: [TimeEntry] {
        rangeFilter.apply(to: employee.sortedTimeEntries, date: \.date)
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var totalHours: Double { filtered.reduce(0) { $0 + $1.hours } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                if range == .custom {
                    VStack(spacing: 6) {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView("No hours in this range", systemImage: "clock")
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(filtered) { entry in
                                Button { editing = entry } label: { row(entry) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Color.clear)
                            }
                        } footer: {
                            Text("\(totalHours.formatted(.number)) hours · \(filtered.count) \(filtered.count == 1 ? "entry" : "entries")")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("All Hours")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
            .sheet(item: $editing) { entry in
                LogHoursSheet(employee: employee, existing: entry).glAppearance(colorScheme)
            }
        }
    }

    private func row(_ entry: TimeEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                if let customer = entry.customer {
                    Text(customer.listDisplayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(entry.hours.formatted(.number)) hr").foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }
}

// MARK: - All paychecks sheet (full, date-filterable list)

private struct AllPaychecksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let employee: Employee

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: Paycheck?

    private var filtered: [Paycheck] {
        rangeFilter.apply(to: employee.sortedPaychecks, date: \.payDate)
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var totalGross: Double { filtered.reduce(0) { $0 + $1.grossAmount } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                if range == .custom {
                    VStack(spacing: 6) {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView("No paychecks in this range", systemImage: "dollarsign.circle")
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(filtered) { check in
                                Button { editing = check } label: { row(check) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Color.clear)
                            }
                        } footer: {
                            Text("\(totalGross.formatted(.currency(code: "USD"))) gross · \(filtered.count) \(filtered.count == 1 ? "paycheck" : "paychecks")")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("All Paychecks")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } } }
            .sheet(item: $editing) { check in
                RecordPaycheckSheet(employee: employee, existing: check).glAppearance(colorScheme)
            }
        }
    }

    private func row(_ check: Paycheck) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(check.payDate.formatted(date: .abbreviated, time: .omitted))
                Text("\(check.payPeriodStart.formatted(date: .abbreviated, time: .omitted)) – \(check.payPeriodEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(check.grossAmount.formatted(.currency(code: "USD"))).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
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
        modelContext.saveChanges()
        dismiss()
    }

    private func delete() {
        if let entry = existing { modelContext.delete(entry); modelContext.saveChanges() }
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
        modelContext.saveChanges()
        dismiss()
    }

    private func delete() {
        if let check = existing { modelContext.delete(check); modelContext.saveChanges() }
        dismiss()
    }
}
