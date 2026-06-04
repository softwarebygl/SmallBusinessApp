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
        if sizeClass == .regular {
            IPadRootSplitView()
        } else {
            RootTabView()
        }
    }
}

/// The top-level sections, shown as the split view's sidebar.
private enum AppSection: String, CaseIterable, Identifiable {
    case customers, receipts, stats
    var id: Self { self }
    var title: String {
        switch self {
        case .customers: "Customers"
        case .receipts: "Receipts"
        case .stats: "Stats"
        }
    }
    var systemImage: String {
        switch self {
        case .customers: "person.2"
        case .receipts: "doc.viewfinder"
        case .stats: "chart.bar"
        }
    }
}

struct IPadRootSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]
    @Query private var businessProfiles: [BusinessProfile]

    @State private var section: AppSection? = .customers
    @State private var selectedCustomerID: PersistentIdentifier?
    @State private var selectedReceiptID: PersistentIdentifier?
    @State private var showingMenu = false
    @State private var showingAddCustomer = false
    @State private var statsSelection = StatsSelection()   // shared by the Stats content + detail columns

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == selectedCustomerID }
    }
    private var selectedReceipt: Receipt? {
        receipts.first { $0.persistentModelID == selectedReceiptID }
    }
    /// The configured business name for the account row, falling back to the app brand.
    private var businessName: String {
        let name = businessProfiles.first?.businessName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Gold Life" : name
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
    }

    // MARK: - Sidebar (sections)

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(AppSection.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .navigationTitle("Gold Life")
        .navigationBarTitleDisplayMode(.large)   // leading-aligned title now the top-leading button is gone
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
                HStack(spacing: 10) {
                    MenuButtonLabel()
                    Text(businessName)
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
            .accessibilityLabel("\(businessName), menu and settings")
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
        case .receipts:
            ReceiptListView(receipts: receipts, defaultCustomer: nil, showsAssignee: true,
                            enablesFilters: true, selectionID: $selectedReceiptID,
                            solidBackground: true)
        case .stats:
            // Stats laid out natively for the split: period controls + KPIs here, charts in detail.
            StatsControlsColumn(selection: statsSelection)
        case nil:
            BrandPlaceholder(text: "Select a section", systemImage: "square.grid.2x2")
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
                    BrandPlaceholder(text: "Select a Customer", systemImage: "person.crop.circle")
                }
            case .receipts:
                if let selectedReceipt {
                    ReceiptDetailScreen(receipt: selectedReceipt)
                } else {
                    BrandPlaceholder(text: "Select a Receipt", systemImage: "doc.viewfinder")
                }
            case .stats:
                StatsDashboard(selection: statsSelection)
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
    }
}

/// Brand-consistent empty state for a split column: the monogram backdrop with an optional prompt.
/// An empty `text` shows just the backdrop (used for sections with no detail, e.g. Stats).
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
