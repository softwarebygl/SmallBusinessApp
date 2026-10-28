//
//  EmployeeDetailScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  One employee: a single Payroll card (next payday + due, the hours/bonuses list, and the Log/Pay Now
//  actions), then recorded paychecks and the year-to-date totals. Entries and paychecks are added/edited
//  through the pushed screens at the bottom of this file. Mirrors CustomerDetailScreen's scaffold
//  (ScrollView + GLCards + monogram backdrop).
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import PhotosUI

struct EmployeeDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let employee: Employee

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.employee, employee, label: employee.fullName, in: modelContext)
    }

    @State private var activeSheet: ActiveSheet?
    @State private var showingEdit = false
    @State private var showingSaveToContacts = false
    @State private var photoItem: PhotosPickerItem?
    @State private var imageToCrop: CroppableImage?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EmployeeService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var photoLoadFailed = false

    /// One navigation driver for the screen: add/edit an hours entry or a paycheck (nil = "new"), or
    /// view all hours/paychecks. A single `.navigationDestination(item:)` pushes each onto the stack.
    private enum ActiveSheet: Identifiable, Hashable {
        case logHours(TimeEntry?)
        case logBonus(TimeEntry?)
        case recordPaycheck(Paycheck?)
        case allHours
        case allPaychecks
        var id: String {
            switch self {
            case .logHours(let entry): "hours-\(entry?.persistentModelID.hashValue ?? 0)"
            case .logBonus(let entry): "bonus-\(entry?.persistentModelID.hashValue ?? 0)"
            case .recordPaycheck(let check): "check-\(check?.persistentModelID.hashValue ?? 0)"
            case .allHours: "allHours"
            case .allPaychecks: "allPaychecks"
            }
        }
    }

    var body: some View {
        // The shared deleted-record fence (LiveRecordGate): "This employee was removed" once the
        // employee is deleted out from under the view (e.g. on another device).
        LiveRecordGate(employee, title: "Employee") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contactCard
                moreInfoRow
                GLSection("Payroll") {
                    payrollCard
                    if employee.isOverFortyThisWeek { overtimeFlag }
                    paychecksCard
                    ytdCard
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(employee.listDisplayName))
        .toolbarTitleDisplayMode(.large)   // name is the large title; the whole nav chain is large
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(employee.listDisplayName)), for: .scrollContent)
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, employee.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button { showingSaveToContacts = true } label: {
                        Label("Save to Phone Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(item: $activeSheet) { sheet in
            switch sheet {
            case .logHours(let entry):
                LogHoursSheet(employee: employee, existing: entry)
            case .logBonus(let entry):
                LogBonusSheet(employee: employee, existing: entry)
            case .recordPaycheck(let check):
                RecordPaycheckSheet(employee: employee, existing: check)
            case .allHours:
                AllHoursSheet(employee: employee)
            case .allPaychecks:
                AllPaychecksSheet(employee: employee)
            }
        }
        .navigationDestination(isPresented: $showingEdit) {
            EmployeeFormScreen.editingLive(employee)
        }
        .sheet(isPresented: $showingSaveToContacts) {
            NewContactView(contact: ContactsBridge.contact(from: employee)) { showingSaveToContacts = false }
                .ignoresSafeArea()
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            // Shrunk to 1024 px, upright, off the main thread before the crop screen holds it
            // (Photo Intake Memory Defense, law 62): a 48 MP pick is never decoded at full size.
            guard let data = try? await photoItem.loadTransferable(type: Data.self),
                  let picked = await ImageDownsampler.intakeImage(from: data) else {
                self.photoItem = nil
                photoLoadFailed = true
                return
            }
            imageToCrop = CroppableImage(image: picked)
            self.photoItem = nil
        }
        .photoLoadFailureAlert($photoLoadFailed)
        .fullScreenCover(item: $imageToCrop) { item in
            // The fleet crop screen with a round guide; it draws the 600 px square itself and
            // stays open with an alert if it can't (never saves the uncropped photo).
            GLSquarePhotoCropper(image: item.image, guide: .circle, outputSide: ImageDownsampler.croppedSide) {
                imageToCrop = nil
            } onCropped: { cropped in
                guard ReadOnlyGate.allows(.saveEmployee, into: $readOnlyRefusal) else { imageToCrop = nil; return }
                setPhoto(cropped.jpegData(compressionQuality: 0.85))
                imageToCrop = nil
            }
        }
    }

    /// The photo write both photo controls share, through EmployeeService (gated, saved).
    private func setPhoto(_ data: Data?) {
        do {
            try EmployeeService.setPhoto(data, for: employee, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ProfileAvatar(imageData: employee.profileImageData, initials: employee.initials,
                              size: 110, showsCameraBadge: true)
            }
            .buttonStyle(.plain)

            if employee.profileImageData != nil {
                Button("Remove Photo", role: .destructive) {
                    guard ReadOnlyGate.allows(.saveEmployee, into: $readOnlyRefusal) else { return }
                    setPhoto(nil)
                }
                .font(.subheadline)
            }

            Text(paySummary)
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)

            if !employee.isActive {
                Text("Inactive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GLTheme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(GLTheme.textSecondary.opacity(0.18)))
            }
        }
    }

    private var paySummary: String {
        let rate = employee.payType == .hourly
            ? mbLoc("\(employee.hourlyRate.formatted(.money))/hr")
            : mbLoc("\(employee.annualSalary.formatted(.money))/yr")
        return "\(rate) · \(employee.payFrequency.label)"
    }

    private var contactCard: some View {
        MBTitledCard(title: "Contact") {
            contactRow("Email", .email, employee.email)
            contactRow("Phone", .phone, employee.phone)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }

    private func contactRow(_ label: LocalizedStringKey, _ kind: GLContactLink.Kind, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(GLTheme.textSecondary)
            } else {
                GLContactLink(kind, value).multilineTextAlignment(.trailing)
            }
        }
    }

    private var moreInfoRow: some View {
        GLHubRow(title: "More Info") { EmployeeDetailsScreen(employee: employee) }
    }

    // MARK: - Payroll (next payday + due, entries, actions — one card)

    private var payrollCard: some View {
        MBTitledCard {
            // Next payday + what's due
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT PAYDAY")
                        .font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(GLTheme.textSecondary)
                    Text(employee.nextPayday().formatted(.dateTime.weekday(.wide).month().day().locale(MBLocalization.currentLocale)))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("DUE")
                        .font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(GLTheme.textSecondary)
                    Text(employee.accruedGross.formatted(.money))
                        .font(.title3.weight(.semibold))
                        // Same rule as the list row: red only once a payday has passed unpaid.
                        .foregroundStyle(employee.owedStatus == .pastDue ? GLTheme.statusCritical : GLTheme.accentText)
                    // WCAG 1.4.1: past-due can't be signalled by the red tint alone (list rows
                    // carry a "· Past due" suffix; this is the card's text cue).
                    if employee.owedStatus == .pastDue {
                        Text("Past due")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GLTheme.statusCritical)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            // Recent entries (hours for hourly, bonuses for salary) — no title
            let entries = employee.sortedTimeEntries
            if entries.isEmpty {
                Text(isSalary ? "No bonuses yet." : "No hours logged yet.")
                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let recent = Array(entries.prefix(5))
                ForEach(recent) { entry in
                    Button { activeSheet = isSalary ? .logBonus(entry) : .logHours(entry) } label: { hoursRow(entry) }
                        .buttonStyle(.plain)
                    if entry.id != recent.last?.id { Divider() }
                }
                if entries.count > 5 {
                    Button { activeSheet = .allHours } label: {
                        Text("View All")
                            .font(.subheadline.weight(.medium)).foregroundStyle(GLTheme.accentText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)   // law 16
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().padding(.vertical, 2)

            // Actions: log (leading) · pay now (trailing)
            HStack {
                Button { activeSheet = isSalary ? .logBonus(nil) : .logHours(nil) } label: {
                    Label(isSalary ? "Log bonus" : "Log hours", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                        .frame(minHeight: 44)   // law 16
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { activeSheet = .recordPaycheck(nil) } label: {
                    Label("Pay now", systemImage: "dollarsign.circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GLTheme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var overtimeFlag: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GLTheme.accent)
                .accessibilityHidden(true)
            Text("\(employee.hoursInWeek().formatted(.number.precision(.fractionLength(0...2)))) hours logged this week — over 40.")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius, style: .continuous).fill(GLTheme.accent.opacity(0.12)))
    }

    // MARK: - Hours

    private var isSalary: Bool { employee.payType == .salary }

    private func hoursRow(_ entry: TimeEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                if let customer = entry.customer {
                    Text(customer.listDisplayName).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
            }
            Spacer()
            Text(entry.amount > 0.005
                 ? entry.amount.formatted(.money)
                 : "\(entry.hours.formatted(.number.precision(.fractionLength(0...2)))) hr")
                .foregroundStyle(GLTheme.textSecondary)
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    // MARK: - Paychecks

    private var paychecksCard: some View {
        MBTitledCard {
            let checks = employee.sortedPaychecks
            HStack {
                Text("Paychecks").font(.headline)
                Spacer()
                if checks.count > 5 {
                    Button { activeSheet = .allPaychecks } label: {
                        Text("View All")
                            .font(.subheadline.weight(.medium)).foregroundStyle(GLTheme.accentText)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)   // law 16
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if checks.isEmpty {
                Text("No paychecks recorded yet.")
                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
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
                Text(check.payDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                Text("\(check.payPeriodStart.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) – \(check.payPeriodEnd.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer()
            Text(check.grossAmount.formatted(.money))
                .foregroundStyle(GLTheme.textSecondary)
            Image(systemName: "chevron.right").font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    // MARK: - YTD + notes

    private var ytdCard: some View {
        MBTitledCard(title: "This year") {
            statRow("Gross paid", employee.ytdGross().formatted(.money))
            statRow("Hours", employee.ytdHours().formatted(.number))
            statRow("Paychecks", "\(employee.sortedPaychecks.filter { Calendar.current.component(.year, from: $0.payDate) == Calendar.current.component(.year, from: .now) }.count)")
        }
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

// MARK: - All hours sheet (full, date-filterable list)

struct AllHoursSheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let employee: Employee

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
        /// The segment's label in the app's language (found 2026-09-29: `Text(rawValue)` drew
        /// the English words verbatim in Spanish).
        var title: String {
            switch self {
            case .all: return mbLoc("All")
            case .year: return mbLoc("This year")
            case .custom: return mbLoc("Custom")
            }
        }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: TimeEntry?
    @State private var searchText = ""

    private var filtered: [TimeEntry] {
        let byDate = rangeFilter.apply(to: employee.sortedTimeEntries, date: \.date)
        return searchText.isEmpty ? byDate : byDate.filter { $0.matchesSearch(searchText) }
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var totalHours: Double { filtered.reduce(0) { $0 + $1.hours } }
    private var totalAmount: Double { DomainMoney.roundedSum(filtered.map(\.grossValue)) }
    private var isSalary: Bool { employee.payType == .salary }

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: "All Hours") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        VStack(spacing: 0) {
            // Segmented at normal sizes; a menu at accessibility sizes, where the three
            // segments truncate their labels. The two styles are different types, so the
            // branch is at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            if range == .custom {
                VStack(spacing: 6) {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .padding(.horizontal, GLLayout.rowCardInset)
                .padding(.bottom, 8)
            }
            List {
                GLInListSearchHeader(text: $searchText, prompt: isSalary ? "Search bonuses" : "Search hours").asPlainListRow
                if filtered.isEmpty {
                    ContentUnavailableView(searchText.isEmpty ? (isSalary ? "No bonuses in this range" : "No hours in this range") : "No matches",
                                           systemImage: searchText.isEmpty ? (isSalary ? "gift" : "clock") : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filtered) { entry in
                            Button { editing = entry } label: { row(entry) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                    } footer: {
                        let total = isSalary ? totalAmount.formatted(.money) : mbLoc("\(totalHours.formatted(.number.precision(.fractionLength(0...2)).locale(MBLocalization.currentLocale))) hours")
                        Text(verbatim: "\(total) · \(mbLoc("\(filtered.count) entries"))")
                            .padding(.horizontal, GLLayout.rowCardInset)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
            .dismissesKeyboardOnInteraction()
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .navigationTitle(GLScript.padded(isSalary ? mbLoc("All Bonuses") : mbLoc("All Hours")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(isSalary ? mbLoc("All Bonuses") : mbLoc("All Hours"))), for: .scrollContent)
        .mbSystemBanners()
        .navigationDestination(item: $editing) { entry in
            // Salary employees log bonuses (flat amounts), hourly log hours — edit with the matching sheet.
            if employee.payType == .salary {
                LogBonusSheet(employee: employee, existing: entry)
            } else {
                LogHoursSheet(employee: employee, existing: entry)
            }
        }
    }

    private func row(_ entry: TimeEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                if let customer = entry.customer {
                    Text(customer.listDisplayName).font(.caption).foregroundStyle(GLTheme.textSecondary)
                }
            }
            Spacer()
            Text(entry.amount > 0.005
                 ? entry.amount.formatted(.money)
                 : "\(entry.hours.formatted(.number.precision(.fractionLength(0...2)))) hr")
                .foregroundStyle(GLTheme.textSecondary)
        }
        .font(.subheadline)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - All paychecks sheet (full, date-filterable list)

struct AllPaychecksSheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let employee: Employee

    private enum Range: String, CaseIterable, Identifiable {
        case all = "All", year = "This year", custom = "Custom"
        var id: String { rawValue }
        /// The segment's label in the app's language (found 2026-09-29: `Text(rawValue)` drew
        /// the English words verbatim in Spanish).
        var title: String {
            switch self {
            case .all: return mbLoc("All")
            case .year: return mbLoc("This year")
            case .custom: return mbLoc("Custom")
            }
        }
    }
    @State private var range: Range = .all
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    @State private var to: Date = .now
    @State private var editing: Paycheck?
    @State private var searchText = ""

    private var filtered: [Paycheck] {
        let byDate = rangeFilter.apply(to: employee.sortedPaychecks, date: \.payDate)
        return searchText.isEmpty ? byDate : byDate.filter { $0.matchesSearch(searchText) }
    }
    private var rangeFilter: DateRangeFilter {
        switch range {
        case .all: return .all
        case .year: return .year(Calendar.current.component(.year, from: .now))
        case .custom: return .custom(from: from, to: to)
        }
    }
    private var totalGross: Double { DomainMoney.roundedSum(filtered.map(\.grossAmount)) }

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: "All Paychecks") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        VStack(spacing: 0) {
            // Segmented at normal sizes; a menu at accessibility sizes, where the three
            // segments truncate their labels. The two styles are different types, so the
            // branch is at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            if range == .custom {
                VStack(spacing: 6) {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .padding(.horizontal, GLLayout.rowCardInset)
                .padding(.bottom, 8)
            }
            List {
                GLInListSearchHeader(text: $searchText, prompt: "Search paychecks").asPlainListRow
                if filtered.isEmpty {
                    ContentUnavailableView(searchText.isEmpty ? "No paychecks in this range" : "No matches",
                                           systemImage: searchText.isEmpty ? "dollarsign.circle" : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filtered) { check in
                            Button { editing = check } label: { row(check) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                    } footer: {
                        Text(verbatim: "\(mbLoc("\(totalGross.formatted(.money)) gross")) · \(mbLoc("\(filtered.count) paychecks"))")
                            .padding(.horizontal, GLLayout.rowCardInset)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
            .dismissesKeyboardOnInteraction()
        }
        .background { GLTheme.background.ignoresSafeArea() }
        .navigationTitle(GLScript.padded(mbLoc("All Paychecks")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Paychecks"))), for: .scrollContent)
        .mbSystemBanners()
        .navigationDestination(item: $editing) { check in
            RecordPaycheckSheet(employee: employee, existing: check)
        }
    }

    private func row(_ check: Paycheck) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(check.payDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                Text("\(check.payPeriodStart.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) – \(check.payPeriodEnd.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))")
                    .font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer()
            Text(check.grossAmount.formatted(.money)).foregroundStyle(GLTheme.textSecondary)
        }
        .font(.subheadline)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Log hours sheet

struct LogHoursSheet: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let employee: Employee
    let existing: TimeEntry?

    /// How the entry's pay is specified: a clock-in/out time range, a number of hours, or a flat amount.
    enum EntryMode: String, CaseIterable, Identifiable {
        case range = "Range", hours = "Hours", dollars = "Dollars"
        var id: String { rawValue }
        /// The segment's label in the app's language (`rawValue` stays the stable identity).
        var title: String {
            switch self {
            case .range: return mbLoc("Range")
            case .hours: return mbLoc("Hours")
            case .dollars: return mbLoc("Dollars")
            }
        }
    }

    @State private var mode: EntryMode
    @State private var date: Date
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var hours: Double
    @State private var amount: Double
    @State private var rate: Double
    @State private var customerID: PersistentIdentifier?
    @State private var confirmDelete = false
    @State private var note: String
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EmployeeService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }
    private var savedRate: Double { employee.hourlyRate }

    init(employee: Employee, existing: TimeEntry?) {
        self.employee = employee
        self.existing = existing
        let d = existing?.date ?? .now
        let cal = Calendar.current
        _mode = State(initialValue: (existing?.amount ?? 0) > 0.005 ? .dollars : .hours)
        _date = State(initialValue: d)
        _startAt = State(initialValue: cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
        _endAt = State(initialValue: cal.date(bySettingHour: 17, minute: 0, second: 0, of: d) ?? d)
        _hours = State(initialValue: existing?.hours ?? 0)
        _amount = State(initialValue: existing?.amount ?? 0)
        _rate = State(initialValue: (existing?.rateSnapshot ?? 0) > 0 ? (existing?.rateSnapshot ?? 0) : employee.hourlyRate)
        _customerID = State(initialValue: existing?.customer?.persistentModelID)
        _note = State(initialValue: existing?.note ?? "")
    }

    /// Hours from the clock-in/out range (end may be the next day for overnight shifts).
    private var rangeHours: Double { max(0, endAt.timeIntervalSince(startAt) / 3600) }

    private var saveDisabled: Bool {
        switch mode {
        // Hours can't be valued without a rate — that would save a $0-snapshot entry a later raise
        // could retroactively re-price. Use Dollars for a flat amount instead.
        case .range: return rangeHours <= 0 || rate <= 0
        case .hours: return hours <= 0 || rate <= 0
        case .dollars: return amount <= 0
        }
    }

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: existing == nil ? "Log Hours" : "Edit Entry") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        Form {
            Section {
                // Segmented at normal sizes; a menu at accessibility sizes, where the three
                // segments truncate their labels. The two styles are different types, so the
                // branch is at the view level, not a ternary (MMGoldLifeSignInSheet recipe).
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Picker("Entry type", selection: $mode) {
                            ForEach(EntryMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Entry type", selection: $mode) {
                            ForEach(EntryMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                // Named for VoiceOver; the segments and the menu's value say the rest.
                .labelsHidden()
                .listRowBackground(Color.clear)
                // Zero row insets so the control spans the full card width — lining its edges up with
                // the section rows below instead of floating narrower inside an invisible row.
                .listRowInsets(EdgeInsets())
            }

            if mode != .dollars {
                Section {
                    LabeledContent("Pay rate") {
                        AutoClearNumberField(placeholder: "$0.00", value: $rate, style: .currency)
                            .multilineTextAlignment(.trailing)
                    }
                    // Separate full-row button — a control nested in a LabeledContent value slot doesn't
                    // reliably receive taps in a Form.
                    if abs(rate - savedRate) > 0.005 {
                        Button { rate = savedRate } label: {
                            Label("Reset to saved rate", systemImage: "arrow.uturn.backward")
                                .font(.subheadline).foregroundStyle(GLTheme.accentText)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Editable — override the rate for this entry if needed. The saved \(savedRate.formatted(.money))/hr won’t change.")
                        .textCase(nil)
                }
            }

            switch mode {
            case .range:
                Section {
                    DatePicker("Start", selection: $startAt)
                    DatePicker("End", selection: $endAt)
                } footer: {
                    Text("\(rangeHours.formatted(.number.precision(.fractionLength(0...2)))) hrs → \(DomainMoney.roundedToCents(DomainMoney.product(rangeHours, rate)).formatted(.money)). End can be the next day for overnight shifts.")
                        .textCase(nil)
                }
            case .hours:
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    LabeledContent("Hours") {
                        AutoClearNumberField(placeholder: "0", value: $hours, style: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    .listRowSeparator(.hidden, edges: .bottom)   // the chip strip below is its own visual edge
                    HStack(spacing: 8) {
                        ForEach([4.0, 6, 8, 10, 12], id: \.self) { h in
                            Button { hours = h } label: {
                                // 30 pt of text + the bordered style's padding = a 44 pt chip (law 16).
                                Text(verbatim: "\(Int(h))").frame(maxWidth: .infinity, minHeight: 30)
                            }
                                .buttonStyle(.bordered).tint(gold)
                                .accessibilityLabel("\(Int(h)) hours")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: GLLayout.rowContentPadding, bottom: 10, trailing: GLLayout.rowContentPadding))
                    // A quiet raised strip (the palette's raised surface) that closes the card: square
                    // top edges flow from the rows above, rounded bottom corners match the section's own.
                    .listRowBackground(
                        UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 26, bottomTrailing: 26), style: .continuous)
                            .fill(GLTheme.surfaceRaised)
                    )
                } footer: {
                    Text("\(DomainMoney.roundedToCents(DomainMoney.product(hours, rate)).formatted(.money)) at \(rate.formatted(.money))/hr.")
                        .textCase(nil)
                }
            case .dollars:
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    LabeledContent("Amount") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("A flat amount owed, not tied to hours.").textCase(nil)
                }
            }

            // Was "Job (optional)" and contained no job — only a customer picker,
            // so the one thing the header named was the one thing you could not
            // choose. The header now matches its only control.
            Section("Customer (optional)") {
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
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete entry") }
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(existing == nil ? mbLoc("Log Hours") : mbLoc("Edit Entry")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(existing == nil ? mbLoc("Log Hours") : mbLoc("Edit Entry"))), for: .scrollContent)
        .alert("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: saveDisabled, action: save)
            }
        }
    }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == customerID }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        guard ReadOnlyGate.allows(.logHours, into: $readOnlyRefusal) else { return false }
        let work: LoggedWork
        switch mode {
        case .range: work = .range(start: startAt, end: endAt, rate: rate)
        case .hours: work = .hours(hours, on: date, rate: rate)
        case .dollars: work = .dollars(amount, on: date)
        }
        do {
            try EmployeeService.logTime(work, customer: selectedCustomer, note: note,
                                        for: employee, editing: existing, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }

    private func delete() {
        guard ReadOnlyGate.allows(.deleteHours, into: $readOnlyRefusal) else { return }
        if let entry = existing {
            do {
                try DeletionService.delete([.timeEntry(entry)], origin: .screen, in: modelContext)
            } catch {
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                return
            }
        }
        dismiss()
    }
}

// MARK: - Log bonus sheet (salary)

/// A one-time salary bonus — a flat amount stored as a TimeEntry with no hours. Kept fully editable
/// and deletable so any automation can always be corrected.
struct LogBonusSheet: View /* internal for render-coverage tests */ {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let employee: Employee
    let existing: TimeEntry?

    @State private var date: Date
    @State private var amount: Double
    @State private var note: String
    @State private var confirmDelete = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EmployeeService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(employee: Employee, existing: TimeEntry?) {
        self.employee = employee
        self.existing = existing
        _date = State(initialValue: existing?.date ?? .now)
        _amount = State(initialValue: existing?.amount ?? 0)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: existing == nil ? "Log Bonus" : "Edit Bonus") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                LabeledContent("Amount") {
                    AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("A one-time bonus on top of the salary. It’s added to what’s owed until it’s paid.")
                    .textCase(nil)
            }
            Section("Note") {
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete bonus") }
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(existing == nil ? mbLoc("Log Bonus") : mbLoc("Edit Bonus")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(existing == nil ? mbLoc("Log Bonus") : mbLoc("Edit Bonus"))), for: .scrollContent)
        .alert("Delete this bonus?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: amount <= 0, action: save)
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        guard ReadOnlyGate.allows(.logHours, into: $readOnlyRefusal) else { return false }
        do {
            try EmployeeService.logBonus(amount, on: date, note: note, for: employee,
                                         editing: existing, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }

    private func delete() {
        guard ReadOnlyGate.allows(.deleteHours, into: $readOnlyRefusal) else { return }
        if let existing {
            do {
                try DeletionService.delete([.timeEntry(existing)], origin: .screen, in: modelContext)
            } catch {
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                return
            }
        }
        dismiss()
    }
}

// MARK: - Record paycheck sheet

struct RecordPaycheckSheet: View /* internal for render-coverage tests */ {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let employee: Employee
    let existing: Paycheck?

    /// For a new payment this is the amount applied to what's owed; when editing, it's the recorded gross.
    @State private var amount: Double
    @State private var payDate: Date
    @State private var method: PaymentMethod
    @State private var note: String
    @State private var includeBonus = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EmployeeService threw that the sheet did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var bonusAmount: Double = 0
    @State private var confirmDelete = false

    init(employee: Employee, existing: Paycheck?) {
        self.employee = employee
        self.existing = existing
        _amount = State(initialValue: existing?.grossAmount ?? employee.accruedGross)
        _payDate = State(initialValue: existing?.payDate ?? .now)   // "Pay now" — paid today by default
        // Most people pay the same way every time — default to how the last check went out.
        _method = State(initialValue: existing?.method ?? employee.sortedPaychecks.first?.method ?? .check)
        _note = State(initialValue: existing?.note ?? "")
    }

    private var gold: Color { GLTheme.accentFill }
    private var isNew: Bool { existing == nil }
    private var owed: Double { employee.accruedGross }
    private var payingInFull: Bool { amount + 0.005 >= owed && owed > 0.005 }

    private var totalPaid: Double {
        amount + (isNew && includeBonus ? max(0, bonusAmount) : 0)
    }

    private var paymentFooter: String { Self.paymentFooter(owed: owed, amount: amount) }

    /// What the Payment footer says for this amount against what's owed.
    static func paymentFooter(owed: Double, amount: Double) -> String {
        let payingInFull = amount + 0.005 >= owed && owed > 0.005
        if owed <= 0.005 { return mbLoc("Nothing is owed right now — record any gross amount you’re paying.") }
        if amount > owed + 0.005 {
            let extra = DomainMoney.remaining(amount, less: owed).formatted(.money)
            return mbLoc("Pays everything owed — the extra \(extra) rides on this paycheck as additional pay, not a credit toward future paydays.")
        }
        if payingInFull { return mbLoc("Pays everything owed.") }
        if amount > 0.005 { return mbLoc("Applied to the oldest unpaid pay first; the rest stays owed for next time.") }
        return mbLoc("Enter a gross amount, or tap Pay in full.")
    }

    /// A salary paycheck already recorded in the current pay period — a second one is usually a
    /// double-pay. Never blocked (everything stays correctable); this just says so before saving.
    private var alreadyPaidThisPeriod: Paycheck? {
        guard isNew, employee.payType == .salary,
              let last = employee.sortedPaychecks.first,
              last.payDate >= employee.currentPeriodStart() else { return nil }
        return last
    }

    var body: some View {
        // F24: draws "This employee was removed" once the employee is deleted while open.
        LiveRecordGate(employee, title: isNew ? "Pay Now" : "Edit Paycheck") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        Form {
            if isNew {
                Section {
                    if let prior = alreadyPaidThisPeriod {
                        Text("A paycheck was already recorded this period (\(prior.payDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))) · \(prior.grossAmount.formatted(.money))). Saving records another one.")
                            .font(.footnote).foregroundStyle(GLTheme.accentText)
                    }
                    LabeledContent("Owed") {
                        Text(owed.formatted(.money)).foregroundStyle(GLTheme.textSecondary)
                    }
                    LabeledContent("Gross") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                    // When the amount already covers everything owed, say so instead of just graying
                    // out — a silent disabled "Pay in full" reads like something still needs doing.
                    Button { amount = owed } label: {
                        Text(payingInFull ? "Full amount entered" : "Pay in full").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(gold)
                    .disabled(owed <= 0.005 || payingInFull)
                } header: {
                    Text("Payment")
                } footer: {
                    Text(paymentFooter).textCase(nil)
                }

                Section {
                    Toggle("Include bonus", isOn: $includeBonus.animation())
                    if includeBonus {
                        LabeledContent("Bonus") {
                            AutoClearNumberField(placeholder: "$0.00", value: $bonusAmount, style: .currency, wholeCents: true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    if includeBonus {
                        Text("A one-time bonus paid on top of this payment.").textCase(nil)
                    }
                }
            } else {
                Section("Amount") {
                    LabeledContent("Gross") {
                        AutoClearNumberField(placeholder: "$0.00", value: $amount, style: .currency, wholeCents: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section {
                Picker("Method", selection: $method) {
                    ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Paid on", selection: $payDate, displayedComponents: .date)
            }
            Section("Note") {
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete paycheck") }
                }
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(isNew ? mbLoc("Pay Now") : mbLoc("Edit Paycheck")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(isNew ? mbLoc("Pay Now") : mbLoc("Edit Paycheck"))), for: .scrollContent)
        .alert("Delete this paycheck?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pay it covered goes back to owed. This can’t be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: totalPaid <= 0.005, action: save)
            }
        }
    }

    /// Returns whether the save committed — false re-arms `SaveOnceButton` so a refused tap can be
    /// retried after the person reactivates.
    @discardableResult
    private func save() -> Bool {
        // Refused up front: recording a payment that arrives AFTER the lapse is named in the ruling
        // as one of the things a read-only app must not do.
        guard ReadOnlyGate.allows(.recordPaycheck, into: $readOnlyRefusal) else { return false }
        // EmployeeService owns the settlement rules (FIFO, entry split, bonus note, period start);
        // editing a recorded paycheck corrects its fields only — settlement already happened.
        do {
            if let check = existing {
                try EmployeeService.editPaycheck(check, payDate: payDate, gross: amount,
                                                 method: method, note: note, in: modelContext)
            } else {
                try EmployeeService.recordPaycheck(for: employee, amount: amount,
                                                   bonus: includeBonus ? max(0, bonusAmount) : 0,
                                                   payDate: payDate, method: method, note: note,
                                                   in: modelContext)
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        dismiss()
        return true
    }

    private func delete() {
        guard ReadOnlyGate.allows(.deletePaycheck, into: $readOnlyRefusal) else { return }
        if let check = existing {
            do {
                try DeletionService.delete([.paycheck(check)], origin: .screen, in: modelContext)
            } catch {
                DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                return
            }
        }
        dismiss()
    }
}
