//
//  IPadRootSplitView.swift
//  GLSmallBusiness
//
//  PROTOTYPE — branch: prototype/ipad-single-splitview
//
//  "Pattern C": a single three-column NavigationSplitView for regular width (iPad, large iPhone
//  landscape), replacing the TabView + per-tab nested split. The top-level sections live in the
//  sidebar (column 1), the selected section's list in the content column (column 2), and the
//  selected item in the detail column (column 3).
//
//  Why: the production layout stacks two top chromes on iPad — the TabView's floating tab bar AND
//  each nested split's own sidebar navigation bar — which leaves the empty band above the sidebar
//  title. A single split view has one nav bar per column (side by side, not stacked), so that band
//  disappears. iPhone is untouched: RootView falls back to the existing RootTabView on compact width.
//

import SwiftUI
import SwiftData

/// Chooses the navigation shell by width: the single split view on regular width (iPad, large
/// iPhone landscape); the existing tab bar on compact (iPhone portrait, narrow multitasking).
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if DEBUG
        if DemoMode.wantsDocument {
            DemoDocumentScreenshot()
        } else {
            shell
        }
        #else
        shell
        #endif
    }

    @ViewBuilder
    private var shell: some View {
        if sizeClass == .regular {
            IPadRootSplitView()
        } else {
            RootTabView()
        }
    }
}

/// The top-level sections, shown as the split view's sidebar.
private enum AppSection: String, CaseIterable, Identifiable {
    // Subcontractors and Calendar land in later rounds. Receipts moved into the Menu (Job Records)
    // and Stats onto the Business screen.
    case customers, employees
    var id: Self { self }
    var title: String {
        switch self {
        case .customers: String(localized: "Customers")
        case .employees: String(localized: "Employees")
        }
    }
    var systemImage: String {
        switch self {
        case .customers: "person.2"
        case .employees: "person.text.rectangle"
        }
    }
}

struct IPadRootSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]
    @Query(sort: [SortDescriptor(\Employee.lastName), SortDescriptor(\Employee.firstName)])
    private var employees: [Employee]
    @State private var section: AppSection? = {
        #if DEBUG
        DemoMode.screen == "employees" ? .employees : .customers
        #else
        .customers
        #endif
    }()
    @State private var selectedCustomerID: PersistentIdentifier?
    @State private var selectedEmployeeID: PersistentIdentifier?
    @State private var showingMenu = false
    @State private var showingAddCustomer = false
    @State private var showingAddEmployee = false

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == selectedCustomerID }
    }
    private var selectedEmployee: Employee? {
        employees.first { $0.persistentModelID == selectedEmployeeID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            content
        } detail: {
            detail
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingAddCustomer) { CustomerFormScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingAddEmployee) {
            EmployeeFormScreen { saved in selectedEmployeeID = saved.persistentModelID }
                .glAppearance(colorScheme)
        }
        #if DEBUG
        .onAppear { selectDemoCustomerIfNeeded(); selectDemoEmployeeIfNeeded() }
        .onChange(of: customers.count) { _, _ in selectDemoCustomerIfNeeded() }
        .onChange(of: employees.count) { _, _ in selectDemoEmployeeIfNeeded() }
        #endif
    }

    #if DEBUG
    /// Screenshot helper: in demo mode on the Customers section, show the first customer's
    /// detail instead of the empty "Select a Customer" placeholder. DEBUG-only — never affects users.
    private func selectDemoCustomerIfNeeded() {
        guard DemoMode.isActive, section == .customers, selectedCustomerID == nil,
              let first = customers.first else { return }
        selectedCustomerID = first.persistentModelID
    }

    /// Same idea for Employees, so the iPad detail shows an employee instead of the placeholder.
    private func selectDemoEmployeeIfNeeded() {
        guard DemoMode.isActive, section == .employees, selectedEmployeeID == nil,
              let first = employees.first else { return }
        selectedEmployeeID = first.persistentModelID
    }
    #endif

    // MARK: - Sidebar (sections)

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(AppSection.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .navigationTitle("My Business")
        .toolbarTitleDisplayMode(.large)   // leading-aligned title now the top-leading button is gone
        .contentMargins(.top, 16, for: .scrollContent)   // breathing room below the script title's descenders
        .containerBackground(for: .navigation) {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        // App-level Menu now lives at the bottom of the sidebar as a clearly-labeled control,
        // not a bare monogram in the nav bar (which read as decoration, not a button).
        .safeAreaInset(edge: .bottom) { sidebarMenuButton }
    }

    private var sidebarMenuButton: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            Button { showingMenu = true } label: {
                HStack(spacing: 14) {
                    MenuButtonLabel()
                        .padding(.leading, 2)
                    Text("Menu")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu and settings")
        }
        .background(GLColor.backgroundPrimary.render(in: colorScheme))
    }

    // MARK: - Content (the list for the selected section)

    @ViewBuilder
    private var content: some View {
        switch section {
        case .customers:
            CustomerListColumn(customers: customers,
                               selection: $selectedCustomerID,
                               showingAdd: $showingAddCustomer)
        case .employees:
            EmployeeListColumn(employees: employees,
                               selection: $selectedEmployeeID,
                               showingAdd: $showingAddEmployee)
        case nil:
            BrandPlaceholder(text: String(localized: "Select a section"), systemImage: "square.grid.2x2")
        }
    }

    // MARK: - Detail (the selected item)

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            switch section {
            case .customers:
                if let selectedCustomer {
                    CustomerDetailScreen(customer: selectedCustomer)
                } else {
                    BrandPlaceholder(text: String(localized: "Select a Customer"), systemImage: "person.crop.circle")
                }
            case .employees:
                if let selectedEmployee {
                    EmployeeDetailScreen(employee: selectedEmployee)
                } else {
                    BrandPlaceholder(text: String(localized: "Select an Employee"), systemImage: "person.text.rectangle")
                }
            case nil:
                BrandPlaceholder(text: "")
            }
        }
    }
}

/// The customers list as a split-view content column: selectable rows that drive the detail column.
private struct CustomerListColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let customers: [Customer]
    @Binding var selection: PersistentIdentifier?
    @Binding var showingAdd: Bool

    var body: some View {
        List(selection: $selection) {
            if customers.isEmpty {
                ContentUnavailableView {
                    Label("No Customers", systemImage: "person.2")
                } description: {
                    Text("Tap + to add your first customer.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(customers) { customer in
                    row(customer)
                        .tag(customer.persistentModelID)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .containerBackground(for: .navigation) {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("Customers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Customer")
            }
        }
    }

    private func row(_ customer: Customer) -> some View {
        HStack(spacing: 12) {
            CustomerAvatar(customer: customer, size: 44)
            Text(customer.listDisplayName)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
        .glSelectionStroke(selection == customer.persistentModelID)
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(customers[index]) }
        // Persist now (cascades to the customer's estimates/invoices/receipts) so Stats and the
        // detail pane reflect it immediately — matching every other delete path in the app.
        try? modelContext.save()
    }
}

/// The employees list as a split-view content column: a payday-summary header plus selectable rows
/// (each showing pay rate and the amount currently accrued) that drive the detail column.
private struct EmployeeListColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let employees: [Employee]
    @Binding var selection: PersistentIdentifier?
    @Binding var showingAdd: Bool

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        List(selection: $selection) {
            if employees.isEmpty {
                ContentUnavailableView {
                    Label("No Employees", systemImage: "person.text.rectangle")
                } description: {
                    Text("Tap + to add your first employee.")
                }
                .listRowBackground(Color.clear)
            } else {
                if let summary = PayrollSummary.nextPayday(for: employees) {
                    paydayHeader(summary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                ForEach(employees) { employee in
                    row(employee)
                        .tag(employee.persistentModelID)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .containerBackground(for: .navigation) {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("Employees")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Employee")
            }
        }
    }

    private func paydayHeader(_ summary: PayrollSummary.NextPayday) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT PAYDAY")
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(summary.date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.title3.weight(.semibold))
            Text("\(summary.total.formatted(.currency(code: "USD"))) due to \(summary.count) \(summary.count == 1 ? "employee" : "employees")")
                .font(.subheadline).foregroundStyle(gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.top, 4)
    }

    private func row(_ employee: Employee) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(gold.opacity(0.18))
                Text(employee.initials).font(.subheadline.weight(.semibold)).foregroundStyle(gold)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(employee.listDisplayName).lineLimit(1)
                Text(paySummary(employee)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if employee.accruedGross > 0 {
                Text(employee.accruedGross.formatted(.currency(code: "USD")))
                    .font(.subheadline.weight(.medium)).foregroundStyle(gold)
            }
        }
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
        .glSelectionStroke(selection == employee.persistentModelID)
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }

    private func paySummary(_ employee: Employee) -> String {
        let rate = employee.payType == .hourly
            ? "\(employee.hourlyRate.formatted(.currency(code: "USD")))/hr"
            : "\(employee.annualSalary.formatted(.currency(code: "USD")))/yr"
        return "\(rate) · \(employee.payFrequency.label)"
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(employees[index]) }
        try? modelContext.save()
    }
}

/// Brand-consistent empty state for a split column: the monogram backdrop with an optional prompt.
/// An empty `text` shows just the backdrop (used for sections with no detail).
private struct BrandPlaceholder: View {
    var text: String
    var systemImage: String = "sparkles"

    var body: some View {
        Group {
            if text.isEmpty {
                Color.clear
            } else {
                ContentUnavailableView(text, systemImage: systemImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .navigation) { PrimaryBackground() }
    }
}
