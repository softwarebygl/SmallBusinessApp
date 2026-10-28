//
//  CustomersScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

/// The customer row's two-value subrow: what they still owe you (red when outstanding) and how much
/// they've paid you to date (gold).
struct CustomerFinancialsSubrow: View {
    let customer: Customer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Text("Owed \(customer.outstanding.formatted(.money))")
                .foregroundStyle(customer.outstanding > 0.005 ? GLTheme.statusCritical : GLTheme.textSecondary)
            Text(verbatim: "·").foregroundStyle(GLTheme.textSecondary)
            Text("Paid \(customer.totalPaidToUs.formatted(.money))")
                .foregroundStyle(GLTheme.accentText)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

// MARK: - People search (one search for every people list)

/// A person the Contacts lists search (each one's fields live in RecordSearch.swift).
protocol ContactSearchable {
    func matchesSearch(_ query: String) -> Bool
}
extension Customer: ContactSearchable {}
extension Employee: ContactSearchable {}
extension Subcontractor: ContactSearchable {}

/// The people lists' search, ONE copy for all of them: the iPhone tab roots, the pushed hosts
/// and the iPad Contacts columns (QA 2026-10-03 F52: the iPad columns had none). Each list puts
/// `GLInListSearchHeader(text:prompt: ContactSearch.prompt(for:)).asPlainListRow` under its
/// Contacts picker, as the last control above the rows (laws 47a, 56), filters through
/// `visible`, and wears `contactSearchNoResults`. The row stays literal at each list so the
/// law 55 gutter scan (SearchGutterTests) still checks it against that list's style.
enum ContactSearch {
    static func prompt(for kind: ContactsKind) -> String {
        switch kind {
        case .customers: mbLoc("Search customers")
        case .employees: mbLoc("Search employees")
        case .subcontractors: mbLoc("Search subcontractors")
        }
    }

    /// The people `query` finds, in their list order. A blank field shows everyone.
    static func visible<Person: ContactSearchable>(_ people: [Person], query: String) -> [Person] {
        query.isEmpty ? people : people.filter { $0.matchesSearch(query) }
    }
}

extension View {
    /// The people lists' "No results" screen: shown only when a typed search found nobody.
    func contactSearchNoResults(_ query: String, foundNobody: Bool) -> some View {
        overlay {
            if !query.isEmpty && foundNobody { ContentUnavailableView.search(text: query) }
        }
    }
}

struct CustomersScreen: View {
    /// True for the Contacts tab pane (the default): it owns its NavigationStack (iPhone) or the
    /// split (iPad) and wears the tab-root chrome. False when pushed onto someone else's stack —
    /// the assistant's "Show my customers" (`open` with no id) — so the list renders inside the
    /// PARENT's stack, because a NavigationStack inside a pushed destination breaks the bar and
    /// its routes. Same contract as EmployeesScreen / SubcontractorsScreen.isTabRoot.
    var isTabRoot: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    @State private var showingAddSheet = false               // iPad split only — the sidebar has no path binding
    @State private var showingPaywall = false
    /// Customers waiting for their typed-name confirmation, asked one at a time (owner ruling
    /// 2026-09-25 (7)). Objects, captured when the person asked — never offsets.
    @State private var deleteQueue: [Customer] = []
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift). Deleting a customer cascades to
    /// their invoices, and the server refuses that cascade when one of them is paid.
    @State private var showingPaidLock = false
    /// A refusal DeletionService found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    @State private var showingMenu = false
    @State private var path: [Route] = []                     // iPhone push navigation
    /// The pushed host's single driver, since it has no path of its own.
    @State private var pushedRoute: Route?

    /// A single navigation driver for the iPhone stack. Mixing a `path` binding with
    /// `navigationDestination(isPresented:)` corrupts the stack — appending to the path while the
    /// presented add-form dismisses pushes a blank screen — so the add form, the detail, and the
    /// screenshot-demo push all ride the same path here.
    private enum Route: Hashable {
        case add
        case detail(Customer)
        #if DEBUG
        case demoPush
        #endif
    }
    @State private var selectedCustomerID: PersistentIdentifier?  // iPad detail selection
    @State private var isEditing = false                          // iPhone multi-select
    @State private var selection = Set<PersistentIdentifier>()
    @State private var searchText = ""
    #if DEBUG
    @State private var didDemoPush = false   // screenshot demo: auto-push a document into this tab
    #endif

    private var gold: Color { GLTheme.accentFill }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == selectedCustomerID }
    }

    /// The customers shown after applying the search field (delete + rows both use this).
    private var visibleCustomers: [Customer] {
        ContactSearch.visible(customers, query: searchText)
    }

    var body: some View {
        // NavigationSplitView's compact collapse misbehaves inside a TabView, so iPhone keeps the
        // proven NavigationStack push flow and iPad uses the split — same rows/chrome either way.
        Group {
            if !isTabRoot {
                pushedView
            } else if sizeClass == .regular {
                splitView
            } else {
                stackView
            }
        }
        // Deleting a customer cascades to their estimates, invoices and receipts and can't be
        // undone: each one is confirmed by typing the client's name (owner ruling 2026-09-25 (7)),
        // on the swipe and the multi-select paths alike.
        .customerDeleteConfirmation($deleteQueue) { customer in
            deleteConfirmed(customer)
        }
        .paidCustomerLockAlert(isPresented: $showingPaidLock)
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
    }

    // MARK: - iPhone (stack)

    private var stackView: some View {
        NavigationStack(path: $path) {
            List {
                ContactsSegmentPicker(host: .customers).asListRow
                GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .customers)).asPlainListRow
                if customers.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleCustomers) { customer in
                        Button {
                            if isEditing { toggleSelection(customer) } else { path.append(.detail(customer)) }
                        } label: {
                            customerRow(customer, isSelected: false, showsChevron: !isEditing,
                                         selectionMark: isEditing ? selection.contains(customer.persistentModelID) : nil)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipeButton(customer) }
                    }
                }
            }
            .modifier(CustomerListChrome())
            .contactSearchNoResults(searchText, foundNobody: visibleCustomers.isEmpty)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .add:
                    // On save, replace the add route with the detail so Back returns to the list, not
                    // the now-stale form. One path mutation, one driver — no blank push.
                    CustomerFormScreen { saved in path = [.detail(saved)] }
                case .detail(let customer):
                    CustomerDetailScreen(customer: customer)
                #if DEBUG
                case .demoPush:
                    DemoPushedScreen()
                #endif
                }
            }
            .toolbar { customerStackToolbar }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .paywallSheet(isPresented: $showingPaywall)
            .glMinimalBackButtons()
            #if DEBUG
            .onAppear {
                if DemoMode.pushableDocument != nil && !didDemoPush {
                    didDemoPush = true
                    path.append(.demoPush)
                }
            }
            #endif
        }
    }

    // MARK: - Pushed (inside another screen's stack)

    /// The same rows and delete rules, rendered inside the parent's stack: no Menu button and no
    /// Contacts segmented control (both belong to the tab root), one `navigationDestination(item:)`
    /// driver for the add form and the detail.
    private var pushedView: some View {
        List {
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .customers)).asPlainListRow
            if customers.isEmpty {
                emptyState
            } else {
                ForEach(visibleCustomers) { customer in
                    Button { pushedRoute = .detail(customer) } label: {
                        customerRow(customer, isSelected: false, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipeButton(customer) }
                }
            }
        }
        .modifier(CustomerListChrome())
        .contactSearchNoResults(searchText, foundNobody: visibleCustomers.isEmpty)
        .navigationDestination(item: $pushedRoute) { route in
            switch route {
            case .add:
                // Swapping the single driver's value replaces the form with the new detail in
                // place, so Back returns to the list.
                CustomerFormScreen { saved in pushedRoute = .detail(saved) }
            case .detail(let customer):
                CustomerDetailScreen(customer: customer)
            #if DEBUG
            case .demoPush:
                DemoPushedScreen()
            #endif
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addCustomer() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Customer")
            }
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    // MARK: - iPad (split)

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selectedCustomerID) {
                ContactsSegmentPicker(host: .customers).asListRow
                GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .customers)).asPlainListRow
                if customers.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleCustomers) { customer in
                        customerRow(customer, isSelected: selectedCustomerID == customer.persistentModelID, showsChevron: false)
                            .tag(customer.persistentModelID)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipeButton(customer) }
                    }
                }
            }
            .modifier(CustomerListChrome(showsMonogram: false))
            .contactSearchNoResults(searchText, foundNobody: visibleCustomers.isEmpty)
            .toolbar { customerToolbar }
            .navigationDestination(isPresented: $showingAddSheet) { CustomerFormScreen() }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .paywallSheet(isPresented: $showingPaywall)
            .glMinimalBackButtons()
        } detail: {
            NavigationStack {
                Group {
                    #if DEBUG
                    if DemoMode.pushableDocument != nil {
                        DemoPushedScreen()
                    } else if let selectedCustomer {
                        CustomerDetailScreen(customer: selectedCustomer)
                    } else {
                        ContentUnavailableView("Select a customer", systemImage: "person.crop.circle")
                            .containerBackground(for: .navigation) { PrimaryBackground() }
                    }
                    #else
                    if let selectedCustomer {
                        CustomerDetailScreen(customer: selectedCustomer)
                    } else {
                        ContentUnavailableView("Select a customer", systemImage: "person.crop.circle")
                            .containerBackground(for: .navigation) { PrimaryBackground() }
                    }
                    #endif
                }
                .glMinimalBackButtons()
            }
        }
        .onAppear { selectFirstOnIPad() }
        .onChange(of: customers.map(\.persistentModelID)) { _, _ in selectFirstOnIPad() }
    }

    // MARK: - Shared pieces

    @ToolbarContentBuilder
    private var customerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingMenu = true
            } label: {
                MenuButtonLabel()
            }
            .accessibilityLabel("Menu")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addCustomer()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Customer")
        }
    }

    /// iPhone toolbar: adds the multi-select Edit mode (Done / Delete) the iPad split omits.
    @ToolbarContentBuilder
    private var customerStackToolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { toggleEditing() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    // The whole batch is refused when ANY selected customer has a paid invoice,
                    // rather than deleting the rest quietly — the same call the invoice list makes:
                    // "19 of your 20 went" is a worse thing to discover afterwards than nothing
                    // happening with a sentence saying why.
                    if selectedCustomers.contains(where: \.hasPaidInvoice) {
                        showingPaidLock = true
                    } else if ReadOnlyGate.allows(.deleteCustomer, into: $readOnlyRefusal) {
                        // A lapsed app says so BEFORE anyone types a name it would then refuse.
                        deleteQueue = selectedCustomers
                    }
                } label: {
                    Text(selection.isEmpty ? mbLoc("Delete") : mbLoc("Delete (\(selection.count))"))
                }
                .tint(.red)
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingMenu = true
                } label: {
                    MenuButtonLabel()
                }
                .accessibilityLabel("Menu")
            }

            // "+" IS PERMANENT. It used to become "…" the moment the list had a
            // row, which moved the app's most-repeated action after the very
            // first success and made creating things harder the more you used
            // the app. Apple keeps + as + and adds a SECOND trailing control for
            // the secondary actions; that is what this is.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addCustomer()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Customer")
            }
            if !customers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    // Law 40: a one-option menu is banned — the action IS the button.
                    Button("Select") { toggleEditing() }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No customers", systemImage: "person.2")
        } description: {
            Text("Tap + to add your first customer.")
        }
        .listRowBackground(Color.clear)
    }

    /// `selectionMark` is nil outside multi-select; in it, true/false draws a filled/empty checkmark.
    private func customerRow(_ customer: Customer, isSelected: Bool, showsChevron: Bool,
                             selectionMark: Bool? = nil) -> some View {
        PersonRowCard(name: customer.listDisplayName,
                      showsChevron: showsChevron,
                      isSelected: isSelected,
                      selectionMark: selectionMark) {
            ProfileAvatar(imageData: customer.profileImageData, initials: customer.initials)
        }
    }

    /// Open the new-customer form, or the paywall if a free user is at the customer cap.
    /// iPhone rides the path (the stack's single driver); the iPad split sidebar has no path
    /// binding, so its push stays `isPresented`-driven.
    private func addCustomer() {
        if AccessGate.attemptCreate(Customer.self, cap: FreeTier.customers, in: modelContext,
                                    subscription: subscription, operation: .saveCustomer,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            if !isTabRoot {
                pushedRoute = .add
            } else if sizeClass == .regular {
                showingAddSheet = true
            } else {
                path.append(.add)
            }
        }
    }

    private func selectFirstOnIPad() {
        guard isTabRoot, sizeClass == .regular, selectedCustomer == nil else { return }
        selectedCustomerID = customers.first?.persistentModelID
    }

    /// The row's swipe Delete. Not `.onDelete` and not `role: .destructive`: both remove the row
    /// from the list the moment they're tapped, while this delete waits for the typed name — the
    /// list then counted a row the data still had and crashed when the real delete landed.
    private func deleteSwipeButton(_ customer: Customer) -> some View {
        Button {
            requestDelete([customer])
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(.red)
    }

    /// Swipe-to-delete only queues the target(s); each delete waits for its typed-name confirmation.
    private func requestDelete(_ swiped: [Customer]) {
        // A paid invoice inside the cascade makes this delete one the server refuses (paid_locked).
        // Explain instead of staging a delete that would leave the customer gone here and alive
        // everywhere else.
        if swiped.contains(where: \.hasPaidInvoice) {
            showingPaidLock = true
        } else if ReadOnlyGate.allows(.deleteCustomer, into: $readOnlyRefusal) {
            // A lapsed app says so BEFORE anyone types a name it would then refuse.
            deleteQueue = swiped
        }
    }

    /// One confirmed customer. False when the delete was refused (the screen explains why), which
    /// ends a multi-select run.
    private func deleteConfirmed(_ customer: Customer) -> Bool {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteCustomer, into: $readOnlyRefusal) else { return false }
        let id = customer.persistentModelID
        // DeletionService re-checks the paid lock, deletes (cascading to the customer's
        // invoices/estimates/receipts) and saves now, so Stats and sync see it immediately.
        guard deleteThroughService([customer]) else { return false }
        selection.remove(id)
        return true
    }

    private func toggleSelection(_ customer: Customer) {
        let id = customer.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleEditing() {
        withAnimation {
            isEditing.toggle()
            if !isEditing { selection.removeAll() }
        }
    }

    /// The customers the multi-select toolbar would act on. Resolved once so the paid-invoice
    /// check and the delete itself can never disagree about the set.
    private var selectedCustomers: [Customer] {
        customers.filter { selection.contains($0.persistentModelID) }
    }

    /// Through DeletionService. Rows a sync already removed are skipped, as before. True when the
    /// delete went through.
    @discardableResult
    private func deleteThroughService(_ items: [Customer]) -> Bool {
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.customer),
                                       origin: .screen, in: modelContext)
            return true
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
        return false
    }
}

/// Shared list styling for both the iPhone stack and the iPad sidebar.
/// `showsMonogram` keeps the brand-monogram backdrop for the iPhone push view; the iPad split
/// sidebar opts out (passes `false`) so the GL monogram only appears once on screen — on the
/// right-hand detail pane.
private struct CustomerListChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var showsMonogram: Bool = true

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
            .dismissesKeyboardOnInteraction()
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Customers"))), for: .scrollContent)   // breathing room below the script title's descenders
            .mbSystemBanners()
            .containerBackground(for: .navigation) {
                if showsMonogram {
                    PrimaryBackground()
                } else {
                    GLTheme.background.ignoresSafeArea()
                }
            }
            .navigationTitle(GLScript.padded(mbLoc("Customers")))
    }
}

#Preview {
    CustomersScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
