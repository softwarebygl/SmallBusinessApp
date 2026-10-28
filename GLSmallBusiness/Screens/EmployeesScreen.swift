//
//  EmployeesScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Employees tab (iPhone / compact). Each row shows the "Owed" amount currently accrued, tinted by
//  owed status (gold upcoming / red past due). iPad drives the same list/detail through
//  IPadRootSplitView. The toolbar's Year-End Report shares the accountant handoff (wage summary +
//  paycheck ledger CSVs) for a selectable tax year. Menu > Documents also pushes it (the default,
//  stackless form) as the Employee Wages year-end door.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct EmployeesScreen: View {
    /// True only for the Contacts tab pane: wraps its own path-driven NavigationStack and gains the
    /// tab-root chrome (Menu button, Contacts segmented control). Pushed hosts (Menu > Documents >
    /// Employee Wages) keep the default and render inside the PARENT's stack, because a
    /// NavigationStack inside a pushed destination breaks the bar and its routes. Same contract
    /// and default as AllJobsScreen.isTabRoot, so a bare initializer can never nest a stack.
    var isTabRoot: Bool = false
    /// True for All Documents' "Employee Wages" row: the same list, titled with that row's name
    /// (law 22, audit 2026-10-03 L12), since its … menu holds the year-end wage export.
    var isWageDoor: Bool = false

    /// The bar title: the row's name on the wage door, "Employees" everywhere else.
    static func title(isWageDoor: Bool) -> String {
        isWageDoor ? mbLoc("Employee Wages") : mbLoc("Employees")
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: [SortDescriptor(\Employee.lastName), SortDescriptor(\Employee.firstName)])
    private var employees: [Employee]
    @Query private var businessProfiles: [BusinessProfile]

    @State private var showingPaywall = false
    @State private var showingMenu = false
    @State private var path: [Route] = []
    /// The pushed host's single driver, since it has no path of its own.
    @State private var pushedRoute: Route?

    /// A single navigation driver for the stack. Mixing a `path` binding with
    /// `navigationDestination(isPresented:)` corrupts the stack — appending to the path while the
    /// presented add-form dismisses pushes a blank screen — so both the add form and the detail ride
    /// the same path here.
    private enum Route: Hashable {
        case add
        case detail(Employee)
    }
    @State private var exportFiles: [URL] = []
    @State private var showingExportShare = false
    @State private var searchText = ""
    @State private var selectedYear = Calendar.current.component(.year, from: .now)
    @State private var didAutoSelectYear = false
    @State private var pendingDelete: [Employee]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    private var yearOptions: [Int] {
        let now = Calendar.current.component(.year, from: .now)
        return Array((now - 4)...now).reversed()
    }

    /// Open on the most recent year with paychecks, so a January visit shows last year's wage
    /// picture (when W-2s are actually filed) instead of an empty in-progress year. Runs once.
    private func autoSelectActiveYear() {
        // Don't latch on an empty roster (fresh install, CloudKit sync in flight) — the onChange
        // re-call must still get a real shot once employees actually arrive.
        guard !didAutoSelectYear, !employees.isEmpty else { return }
        didAutoSelectYear = true
        let now = Calendar.current.component(.year, from: .now)
        for year in stride(from: now, through: now - 4, by: -1)
        where employees.contains(where: { $0.ytdGross(year: year) > 0.005 || $0.ytdHours(year: year) > 0.005 }) {
            selectedYear = year
            return
        }
    }

    private var visibleEmployees: [Employee] {
        ContactSearch.visible(employees, query: searchText)
    }

    var body: some View {
        if isTabRoot {
            NavigationStack(path: $path) {
                list
                    .navigationDestination(for: Route.self) { destination(for: $0) }
                    .glMinimalBackButtons()
            }
        } else {
            list
                .navigationDestination(item: $pushedRoute) { destination(for: $0) }
        }
    }

    private var list: some View {
        List {
            if isTabRoot { ContactsSegmentPicker(host: .employees).asListRow }
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .employees)).asPlainListRow
            if employees.isEmpty {
                emptyState
            } else {
                ForEach(visibleEmployees) { employee in
                    Button { open(.detail(employee)) } label: { row(employee) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { pendingDelete = [employee] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this employee?",
                                 message: "Their hours and paychecks are removed too. This can’t be undone.") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(Self.title(isWageDoor: isWageDoor))), for: .scrollContent)   // breathing room below the script title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .contactSearchNoResults(searchText, foundNobody: visibleEmployees.isEmpty)
        .navigationTitle(GLScript.padded(Self.title(isWageDoor: isWageDoor)))
        .toolbarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingExportShare, onDismiss: cleanUpExport) { ActivityView(items: exportFiles) }
        .paywallSheet(isPresented: $showingPaywall)
        .onAppear { autoSelectActiveYear() }
        .onChange(of: employees.map(\.persistentModelID)) { _, _ in autoSelectActiveYear() }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .add:
            if isTabRoot {
                // On save, replace the add route with the detail so Back returns to the list, not
                // the now-stale form. One path mutation, one driver — no blank push.
                EmployeeFormScreen { saved in path = [.detail(saved)] }
            } else {
                // Pushed host: same outcome as the tab root. Swapping the single driver's value
                // replaces the form with the new detail in place, so Back returns to the list.
                EmployeeFormScreen { saved in pushedRoute = .detail(saved) }
            }
        case .detail(let employee):
            EmployeeDetailScreen(employee: employee)
        }
    }

    /// Push a route on whichever driver this host owns.
    private func open(_ route: Route) {
        if isTabRoot { path.append(route) } else { pushedRoute = route }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Tab root only: pushed from the Menu, it would open a second Menu over the first.
        if isTabRoot {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingMenu = true } label: { MenuButtonLabel() }
                    .accessibilityLabel("Menu")
            }
        }

        // "+" IS PERMANENT — it used to disappear into "…" the moment there was
        // an exportable year, moving the add action after the first success.
        ToolbarItem(placement: .topBarTrailing) {
            Button { addEmployee() } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add Employee")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if hasExportableYear {
                Menu {
                    // The wage CSVs are only written to disk when the report is actually exported —
                    // never eagerly on tab visit — and are removed when the share sheet closes.
                    Button {
                        generateExport()
                        if !exportFiles.isEmpty { showingExportShare = true }
                    } label: {
                        Label("Employee Wage Report", systemImage: "square.and.arrow.up")
                    }
                    Picker("Tax year", selection: $selectedYear) {
                        ForEach(yearOptions, id: \.self) { Text(verbatim: String($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: - Row

    private func row(_ employee: Employee) -> some View {
        PersonRowCard(
            name: employee.listDisplayName,
            subtitle: employee.owedStatus.owedSubtitle(employee.accruedGross),
            subtitleColor: employee.owedStatus.tint(in: colorScheme)
        ) {
            ProfileAvatar(imageData: employee.profileImageData, initials: employee.initials)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No employees", systemImage: "person.text.rectangle")
        } description: {
            Text("Tap + to add your first employee.")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    /// Open the new-employee form, or the paywall if a free user is at the employee cap.
    private func addEmployee() {
        if AccessGate.attemptCreate(Employee.self, cap: FreeTier.employees, in: modelContext,
                                    subscription: subscription, operation: .saveEmployee,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            open(.add)
        }
    }

    private func delete(_ items: [Employee]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteEmployee, into: $readOnlyRefusal) else { return }
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.employee), origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// Whether the selected year's report would have any rows (same inclusion rule as
    /// EmployeePayExport) — drives showing the Year-End Report menu item without writing any
    /// files to disk.
    private var hasExportableYear: Bool {
        // Gate on ANY option year (not the selected one) — otherwise flipping the picker to an empty
        // year hides the whole menu, picker included, stranding the selection there.
        employees.contains(where: \.isActive) || yearOptions.contains { year in
            employees.contains { $0.ytdGross(year: year) > 0.005 || $0.ytdHours(year: year) > 0.005 }
        }
    }

    /// Writes the year-end wage CSVs to the temp directory. Called ONLY from the export action —
    /// never eagerly on tab visit — written with complete protection (encrypted at rest whenever
    /// the device is locked), and removed again when the share sheet closes.
    private func generateExport() {
        // "NO EXPORT" — the owner's ruling names it in those words: exporting is the app doing
        // something on their behalf, not a record they are reading.
        guard ReadOnlyGate.allows(.exportWages, into: $readOnlyRefusal) else { return }
        exportFiles = EmployeePayExport.files(
            employees: employees,
            year: selectedYear,
            business: businessProfiles.first
        )
    }

    /// Delete the wage CSVs as soon as the share sheet is done with them.
    private func cleanUpExport() {
        for url in exportFiles { try? FileManager.default.removeItem(at: url) }
        exportFiles = []
    }
}

#Preview {
    EmployeesScreen(isTabRoot: true)
        .modelContainer(for: Employee.self, inMemory: true)
}
