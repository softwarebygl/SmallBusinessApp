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
import GoldLifeUI
import GoldLifeMoney
import SwiftData
import UIKit

/// Chooses the navigation shell by width: the single split view on regular width (iPad, large
/// iPhone landscape); the existing tab bar on compact (iPhone portrait, narrow multitasking).
struct RootView: View {
    /// One router for the whole app: the Contacts segment (and future deep links) live here,
    /// shared by both shells so the state survives a shell swap.
    @State private var router = AppRouter()

    var body: some View {
        #if DEBUG
        if DemoMode.wantsBypassDocument {
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
        // No backup notice here any more: backup is the Gold Life account, not iCloud, so the
        // signed-out "not backed up" state lives with the account controls (GoldLifeIDViews) where
        // the fix is one tap away. A one-shot alert at the root was a nag with nowhere to go.
        chrome
            .environment(router)
            // No .glDemoBanner() here: SampleDataHost (GatePhase.swift) mounts it
            // once around whichever root is active — a second mount here drew the
            // banner twice, stacked.
    }

    @ViewBuilder
    private var chrome: some View {
        // Key the shell on the DEVICE, not the size class. iPad always uses the split (which collapses
        // gracefully in Split View / Stage Manager), so resizing into a narrow multitasking width never
        // tears down the shell and silently loses in-progress form input or the current selection.
        // (Keying on horizontalSizeClass swapped iPad <-> iPhone shells mid-edit and dropped state.)
        if UIDevice.current.userInterfaceIdiom == .pad {
            IPadRootSplitView()
        } else {
            RootTabView()
        }
    }
}

/// The top-level sections, shown as the split view's sidebar. Contacts holds all three
/// people lists behind the shared segmented control (the iPhone tab merge, mirrored).
private enum AppSection: String, CaseIterable, Identifiable {
    // Receipts moved into the Menu (Job Records) and Stats onto the Business screen.
    case contacts, contracts, money, assistant
    var id: Self { self }
    var title: String {
        switch self {
        case .contacts: mbLoc("Contacts")
        case .contracts: mbLoc("Contracts")
        case .money: mbLoc("Money")
        case .assistant: mbLoc("Sentinel")
        }
    }
    var systemImage: String {
        switch self {
        case .contacts: "person.2"
        case .contracts: "doc.text.fill"
        case .money: "dollarsign.circle"
        case .assistant: "sparkles"
        }
    }
}

struct IPadRootSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]
    @Query(sort: [SortDescriptor(\Employee.lastName), SortDescriptor(\Employee.firstName)])
    private var employees: [Employee]
    @Query(sort: [SortDescriptor(\Subcontractor.lastName), SortDescriptor(\Subcontractor.firstName)])
    private var subcontractors: [Subcontractor]
    @Environment(AppRouter.self) private var envRouter: AppRouter?
    private var router: AppRouter { envRouter ?? .fallback }
    @State private var section: AppSection? = {
        #if DEBUG
        // People -demoScreen names land on Contacts; the segment is AppRouter's init.
        if let s = DemoMode.screen {
            if s == "calendar" || s == "calendar_pushed" {
                return .contracts
            }
            if s == "money" {
                return .money
            }
        }
        return .contacts
        #else
        return .contacts
        #endif
    }()
    @State private var selectedCustomerID: PersistentIdentifier?
    @State private var selectedEmployeeID: PersistentIdentifier?
    @State private var selectedSubcontractorID: PersistentIdentifier?
    @State private var showingMenu = false
    @State private var showingAddCustomer = false
    @State private var showingAddEmployee = false
    @State private var showingAddSubcontractor = false
    /// Each Contacts column's search text. Kept HERE, not in the columns, so it survives the
    /// split's re-keys (`detailResetCount`) and a segment flip, like each iPhone pane keeps its own.
    @State private var customerSearch = ""
    @State private var employeeSearch = ""
    @State private var subcontractorSearch = ""
    @State private var moneySearch = ""
    @State private var moneySegment: Int = 0
    @State private var selectedTransactionSyncID: UUID?
    @State private var selectedSubscriptionSyncID: UUID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The person whose detail root is on screen right now (nil while a pushed screen covers it,
    /// or while a placeholder shows). Set by the roots' onAppear/onDisappear.
    @State private var visibleDetailRoot: PersistentIdentifier?
    /// Bumped when a person is picked while a screen is pushed over the current person's
    /// detail: it re-keys the split (see `pickRebuildsDetail`).
    @State private var detailResetCount = 0

    init(initialSection: String? = nil) {
        if let s = initialSection.flatMap(AppSection.init(rawValue:)) {
            _section = State(initialValue: s)
        }
    }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == selectedCustomerID }
    }
    private var selectedEmployee: Employee? {
        employees.first { $0.persistentModelID == selectedEmployeeID }
    }
    private var selectedSubcontractor: Subcontractor? {
        subcontractors.first { $0.persistentModelID == selectedSubcontractorID }
    }

    var body: some View {
        NavigationSplitView {
            // Each column is its own navigation controller, so each one pins its
            // own back buttons (GoldLifeUI ruling S6).
            sidebar.glMinimalBackButtons()
        } content: {
            content.glMinimalBackButtons()
        } detail: {
            detail
        }
        // The SPLIT VIEW's identity is the section + segment. A segment flip must reset
        // the detail column's pushed screens — QA-reproduced: an employee's Log Hours
        // form stayed up (Save live) over the Customers segment, and Back landed on a
        // customer, silently discarding the entry. An .id on the inner NavigationStack
        // alone did NOT pop the column's navigation controller (verified on the iPad
        // simulator), so the whole split re-keys. The SELECTIONS and the router live in
        // THIS view's @State/environment and survive; column-local pushes (e.g. a job's
        // detail pushed inside the Jobs column) deliberately reset with the rebuild.
        // A pick made while a screen is pushed over the current person's detail also re-keys it
        // (`detailResetCount`, F23): the pushed form belongs to the person who is no longer shown.
        .id(section == .contacts ? "contacts-\(router.contactsKind.rawValue)-\(detailResetCount)"
                                 : "section-\(section?.rawValue ?? "none")")
        .onChange(of: router.ipadSection) { _, newSection in
            if let parsed = AppSection(rawValue: newSection), section != parsed {
                section = parsed
            }
        }
        .onChange(of: section) { _, newSection in
            if let raw = newSection?.rawValue, router.ipadSection != raw {
                router.ipadSection = raw
            }
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        #if DEBUG
        .onAppear { selectDemoCustomerIfNeeded(); selectDemoEmployeeIfNeeded(); selectDemoSubcontractorIfNeeded() }
        .onChange(of: customers.count) { _, _ in selectDemoCustomerIfNeeded() }
        .onChange(of: employees.count) { _, _ in selectDemoEmployeeIfNeeded() }
        .onChange(of: subcontractors.count) { _, _ in selectDemoSubcontractorIfNeeded() }
        #endif
    }

    #if DEBUG
    /// Screenshot helper: in demo mode on the Customers segment, show the first customer's
    /// detail instead of the empty "Select a Customer" placeholder. DEBUG-only — never affects users.
    private func selectDemoCustomerIfNeeded() {
        guard DemoMode.isActive, section == .contacts, router.contactsKind == .customers,
              selectedCustomerID == nil, let first = customers.first else { return }
        selectedCustomerID = first.persistentModelID
    }

    /// Same idea for Employees, so the iPad detail shows an employee instead of the placeholder.
    private func selectDemoEmployeeIfNeeded() {
        guard DemoMode.isActive, section == .contacts, router.contactsKind == .employees,
              selectedEmployeeID == nil, let first = employees.first else { return }
        selectedEmployeeID = first.persistentModelID
    }

    /// Same idea for Subcontractors.
    private func selectDemoSubcontractorIfNeeded() {
        guard DemoMode.isActive, section == .contacts, router.contactsKind == .subcontractors,
              selectedSubcontractorID == nil, let first = subcontractors.first else { return }
        selectedSubcontractorID = first.persistentModelID
    }
    #endif

    // MARK: - Sidebar (sections)

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(AppSection.allCases.filter { $0 != .assistant || MBFeatureFlags.assistantEnabled }) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .navigationTitle(GLScript.padded(mbLoc("My Business")))
        .toolbarTitleDisplayMode(.large)   // leading-aligned title now the top-leading button is gone
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("My Business"))), for: .scrollContent)
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
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
                        .foregroundStyle(GLTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.glCaption.weight(.semibold))
                        .foregroundStyle(GLTheme.textTertiary)
                }
                .padding(.horizontal, GLLayout.rowContentPadding)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu and settings")
        }
        .background(GLTheme.background)
    }

    // MARK: - Content (the list for the selected section)

    @ViewBuilder
    private var content: some View {
        switch section {
        case .contacts:
            // The columns swap by segment (selection state lives up here, so it survives
            // flips); the shared picker pins above whichever list is showing.
            Group {
                switch router.contactsKind {
                case .customers:
                    CustomerListColumn(customers: customers,
                                       selection: picking($selectedCustomerID),
                                       showingAdd: $showingAddCustomer,
                                       searchText: $customerSearch)
                case .employees:
                    EmployeeListColumn(employees: employees,
                                       selection: picking($selectedEmployeeID),
                                       showingAdd: $showingAddEmployee,
                                       searchText: $employeeSearch)
                case .subcontractors:
                    SubcontractorListColumn(subcontractors: subcontractors,
                                            selection: picking($selectedSubcontractorID),
                                            showingAdd: $showingAddSubcontractor,
                                            searchText: $subcontractorSearch)
                }
            }
        case .contracts:
            // Contracts section: the LIST is the column (the Calendar fills the detail
            // pane by default — both visible at once, the wide pane fits the grid).
            AllContractsScreen()
        case .money:
            MoneyListColumn(
                selectedTransactionID: $selectedTransactionSyncID,
                selectedSubscriptionID: $selectedSubscriptionSyncID,
                segment: $moneySegment,
                searchText: $moneySearch
            )
            .mbMoneyHostEnvironment()
        case .assistant:
            // The split view's content closure IS this column's navigation controller, and the
            // Menu already sits at the bottom of the sidebar — so the assistant drops both, like
            // every other column (AllJobsScreen(isTabRoot:), CalendarScreen(ownsStack:)).
            AssistantScreen(ownsStack: false)
        case nil:
            BrandPlaceholder(text: mbLoc("Select a section"), systemImage: "square.grid.2x2")
        }
    }

    // MARK: - Picking a person (F23)

    /// The middle column's selection, routed through `pickRebuildsDetail` first.
    private func picking(_ current: Binding<PersistentIdentifier?>) -> Binding<PersistentIdentifier?> {
        Binding(
            get: { current.wrappedValue },
            set: { picked in
                if horizontalSizeClass == .regular,
                   Self.pickRebuildsDetail(showing: current.wrappedValue, picked: picked,
                                           visibleRoot: visibleDetailRoot) {
                    detailResetCount += 1
                }
                current.wrappedValue = picked
            })
    }

    /// True when picking `picked` must also close what is pushed over the current detail.
    ///
    /// Each detail root is keyed on its person (`DetailRootIdentity`), so its own state — an
    /// open Edit form's flag, a Log Hours push, a photo still loading — starts fresh for the
    /// next person. Keying the root alone did not pop this column's pushed screens on iOS 26
    /// (24bd5ed: an employee's Log Hours form stayed up, Save live, over another root), and a
    /// form left up saves its first person's values onto the person now selected. So a pick
    /// made while the current person's root is covered (`visibleRoot` is no longer them) also
    /// re-keys the split, the reset already proven for segment flips. Regular width only: in a
    /// collapsed split the list shows only once the detail is popped, so there is nothing to close.
    static func pickRebuildsDetail(showing: PersistentIdentifier?, picked: PersistentIdentifier?,
                                   visibleRoot: PersistentIdentifier?) -> Bool {
        guard let showing, picked != showing else { return false }
        return visibleRoot != showing
    }

    // MARK: - Detail (the selected item)

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            Group {
                #if DEBUG
                if DemoMode.pushableDocument != nil {
                    // Screenshot demo: show the requested document in the detail column, so it appears
                    // inside the real 3-column split (sidebar + list + document) — not bare full-screen.
                    DemoPushedScreen()
                } else {
                    detailContent
                }
                #else
                detailContent
                #endif
            }
            .glMinimalBackButtons()
        }
        .glAmbientBackground { PrimaryBackground() }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            switch section {
            case .contacts:
                switch router.contactsKind {
                case .customers:
                    if let selectedCustomer {
                        CustomerDetailScreen(customer: selectedCustomer)
                            .modifier(DetailRootIdentity(id: selectedCustomer.persistentModelID,
                                                         visible: $visibleDetailRoot))
                    } else {
                        BrandPlaceholder(text: mbLoc("Select a customer"), systemImage: "person.crop.circle")
                    }
                case .employees:
                    if let selectedEmployee {
                        EmployeeDetailScreen(employee: selectedEmployee)
                            .modifier(DetailRootIdentity(id: selectedEmployee.persistentModelID,
                                                         visible: $visibleDetailRoot))
                    } else {
                        BrandPlaceholder(text: mbLoc("Select an Employee"), systemImage: "person.text.rectangle")
                    }
                case .subcontractors:
                    if let selectedSubcontractor {
                        SubcontractorDetailScreen(subcontractor: selectedSubcontractor)
                            .modifier(DetailRootIdentity(id: selectedSubcontractor.persistentModelID,
                                                         visible: $visibleDetailRoot))
                    } else {
                        BrandPlaceholder(text: mbLoc("Select a Subcontractor"), systemImage: "hammer")
                    }
                }
            case .contracts:
                // The month grid + availability banner live in the wide pane; picking
                // a contract in the column pushes its detail IN the column.
                CalendarScreen(showsMenuButton: false, ownsStack: false, primaryBackground: true)
            case .money:
                MoneyDetailPane(
                    selectedTransactionID: selectedTransactionSyncID,
                    selectedSubscriptionID: selectedSubscriptionSyncID,
                    segment: moneySegment
                )
                .mbMoneyHostEnvironment()
            case .assistant:
                // The conversation itself lives in the COLUMN (it owns its own navigation stack,
                // so an `open` pushes the record beside it); the wide pane names the section.
                BrandPlaceholder(text: mbLoc("Sentinel"), systemImage: "sparkles")
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
    /// The column's search (the iPhone list's, shared: ContactSearch).
    @Binding var searchText: String
    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingPaywall = false
    /// Customers waiting for their typed-name confirmation (owner ruling 2026-09-25 (7)).
    @State private var deleteQueue: [Customer] = []
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal DeletionService found that the column's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift) — a customer whose cascade
    /// contains a paid invoice cannot be deleted, here or on the server.
    @State private var showingPaidLock = false

    var body: some View {
        List(selection: $selection) {
            ContactsSegmentPicker(host: .customers).asListRow
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .customers)).asPlainListRow
            if customers.isEmpty {
                ContentUnavailableView {
                    Label("No customers", systemImage: "person.2")
                } description: {
                    Text("Tap + to add your first customer.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleCustomers) { customer in
                    row(customer)
                        .tag(customer.persistentModelID)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { requestDelete([customer]) }
                }
            }
        }
        // Each customer is confirmed by typing their name (owner ruling 2026-09-25 (7)).
        .customerDeleteConfirmation($deleteQueue) { delete([$0]) }
        .paidCustomerLockAlert(isPresented: $showingPaidLock)
        .contactSearchNoResults(searchText, foundNobody: visibleCustomers.isEmpty)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Customers"))), for: .scrollContent)   // breathing room below the script title's descenders
        .mbSystemBanners(capsContent: false)
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Customers")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { attemptAdd() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Customer")
            }
        }
        .navigationDestination(isPresented: $showingAdd) {
            CustomerFormScreen { saved in selection = saved.persistentModelID }
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    private var visibleCustomers: [Customer] {
        ContactSearch.visible(customers, query: searchText)
    }

    private func attemptAdd() {
        if AccessGate.attemptCreate(Customer.self, cap: FreeTier.customers, in: modelContext,
                                    subscription: subscription, operation: .saveCustomer,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingAdd = true
        }
    }

    private func row(_ customer: Customer) -> some View {
        PersonRowCard(name: customer.listDisplayName,
                      showsChevron: false,
                      isSelected: selection == customer.persistentModelID) {
            ProfileAvatar(imageData: customer.profileImageData, initials: customer.initials)
        }
    }

    /// The swipe only queues the customer for the typed-name confirmation (law 8; the iPhone
    /// list's 2026-09-26 crash came from staging this from `.onDelete`). A paid invoice in the
    /// cascade is a delete the server refuses (paid_locked), so it must not be staged either.
    private func requestDelete(_ swiped: [Customer]) {
        if swiped.contains(where: \.hasPaidInvoice) {
            showingPaidLock = true
        } else if ReadOnlyGate.allows(.deleteCustomer, into: $readOnlyRefusal) {
            // A lapsed app says so BEFORE anyone types a name it would then refuse.
            deleteQueue = swiped
        }
    }

    /// True when the delete went through; false ends a confirmation run (the column explains why).
    private func delete(_ items: [Customer]) -> Bool {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteCustomer, into: $readOnlyRefusal) else { return false }
        // DeletionService re-checks the paid lock, deletes and saves.
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.customer), origin: .screen, in: modelContext)
            return true
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
        return false
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
    /// The column's search (the iPhone list's, shared: ContactSearch).
    @Binding var searchText: String

    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingPaywall = false
    @State private var pendingDelete: [Employee]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal DeletionService found that the column's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        List(selection: $selection) {
            ContactsSegmentPicker(host: .employees).asListRow
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .employees)).asPlainListRow
            if employees.isEmpty {
                ContentUnavailableView {
                    Label("No employees", systemImage: "person.text.rectangle")
                } description: {
                    Text("Tap + to add your first employee.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleEmployees) { employee in
                    row(employee)
                        .tag(employee.persistentModelID)
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
        .contactSearchNoResults(searchText, foundNobody: visibleEmployees.isEmpty)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Employees"))), for: .scrollContent)   // breathing room below the script title's descenders
        .mbSystemBanners(capsContent: false)
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Employees")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { attemptAdd() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Employee")
            }
        }
        .navigationDestination(isPresented: $showingAdd) {
            EmployeeFormScreen { saved in selection = saved.persistentModelID }
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    private var visibleEmployees: [Employee] {
        ContactSearch.visible(employees, query: searchText)
    }

    private func attemptAdd() {
        if AccessGate.attemptCreate(Employee.self, cap: FreeTier.employees, in: modelContext,
                                    subscription: subscription, operation: .saveEmployee,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingAdd = true
        }
    }

    private func row(_ employee: Employee) -> some View {
        PersonRowCard(
            name: employee.listDisplayName,
            subtitle: employee.owedStatus.owedSubtitle(employee.accruedGross),
            subtitleColor: employee.owedStatus.tint(in: colorScheme),
            showsChevron: false,
            isSelected: selection == employee.persistentModelID
        ) {
            ProfileAvatar(imageData: employee.profileImageData, initials: employee.initials)
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
}

/// The subcontractors list as a split-view content column: a 1099-summary header plus selectable
/// rows (year-to-date total + a 1099 badge) that drive the detail column.
private struct SubcontractorListColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let subcontractors: [Subcontractor]
    @Binding var selection: PersistentIdentifier?
    @Binding var showingAdd: Bool
    /// The column's search (the iPhone list's, shared: ContactSearch).
    @Binding var searchText: String

    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingPaywall = false
    @State private var pendingDelete: [Subcontractor]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal DeletionService found that the column's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        List(selection: $selection) {
            ContactsSegmentPicker(host: .subcontractors).asListRow
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .subcontractors)).asPlainListRow
            if subcontractors.isEmpty {
                ContentUnavailableView {
                    Label("No subcontractors", systemImage: "hammer")
                } description: {
                    Text("Tap + to add your first subcontractor.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleSubcontractors) { sub in
                    row(sub)
                        .tag(sub.persistentModelID)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { pendingDelete = [sub] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this subcontractor?",
                                 message: "Their payment history is removed too. This can’t be undone.") {
            delete($0)
        }
        .contactSearchNoResults(searchText, foundNobody: visibleSubcontractors.isEmpty)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Subcontractors"))), for: .scrollContent)   // breathing room below the script title's descenders
        .mbSystemBanners(capsContent: false)
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .navigationTitle(GLScript.padded(mbLoc("Subcontractors")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { attemptAdd() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Subcontractor")
            }
        }
        .navigationDestination(isPresented: $showingAdd) {
            SubcontractorFormScreen { saved in selection = saved.persistentModelID }
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    private var visibleSubcontractors: [Subcontractor] {
        ContactSearch.visible(subcontractors, query: searchText)
    }

    private func attemptAdd() {
        if AccessGate.attemptCreate(Subcontractor.self, cap: FreeTier.subcontractors, in: modelContext,
                                    subscription: subscription, operation: .saveSubcontractor,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingAdd = true
        }
    }

    private func row(_ sub: Subcontractor) -> some View {
        return PersonRowCard(
            name: sub.listDisplayName,
            subtitle: sub.owedStatus.owedSubtitle(sub.outstanding),
            subtitleColor: sub.owedStatus.tint(in: colorScheme),
            showsChevron: false,
            isSelected: selection == sub.persistentModelID
        ) {
            ProfileAvatar(imageData: sub.profileImageData, initials: sub.initials)
        }
    }

    private func delete(_ items: [Subcontractor]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteSubcontractor, into: $readOnlyRefusal) else { return }
        // DeletionService clears each one's Keychain TIN before the delete, then saves.
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.subcontractor), origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
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

/// Keys an iPad detail root on its person, so picking another person builds a fresh root (no
/// state carried over from the last one), and reports whether that root is on screen or covered
/// by a pushed screen (`IPadRootSplitView.pickRebuildsDetail`).
private struct DetailRootIdentity: ViewModifier {
    let id: PersistentIdentifier
    @Binding var visible: PersistentIdentifier?

    func body(content: Content) -> some View {
        content
            .onAppear { visible = id }
            // The next person's root can appear before this one disappears: clear only our own.
            .onDisappear { if visible == id { visible = nil } }
            .id(id)
    }
}
