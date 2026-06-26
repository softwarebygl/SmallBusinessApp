//
//  ReceiptsListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData
import VisionKit

private struct ReceiptFormInput: Identifiable, Hashable {
    let id = UUID()
    let image: UIImage?

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Scope filter for the universal Receipts tab.
enum ReceiptFilter: Hashable {
    case all
    case business
    case customer(PersistentIdentifier)
    case store(String)
}

/// Reusable receipts list + scan/OCR flow, shared by the per-customer screen, the universal
/// Receipts tab, and the business (My Company) receipts screen. The parent supplies the
/// receipts to show and the default customer for new scans. Set `enablesFilters` for the
/// universal tab to add search, a customer/store filter, and a running total.
struct ReceiptListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    let receipts: [Receipt]
    let defaultCustomer: Customer?
    /// When this list is scoped to a job, new scans attach to it (in addition to `defaultCustomer`).
    var defaultJob: ScheduledJob? = nil
    var showsAssignee: Bool = false
    var enablesFilters: Bool = false
    /// Navigation title. Defaults to "Receipts" for the tab; the Records-section "All Receipts"
    /// entry overrides it so it reads consistently with the other Records lists.
    var title: LocalizedStringResource = "Receipts"
    /// When provided, the view is an iPad master-detail sidebar: a row tap drives this selection
    /// (highlighting the row) instead of pushing the detail. The parent split renders the detail.
    var selectionID: Binding<PersistentIdentifier?>? = nil
    /// The universal Receipts tab shows the app Menu button (like the other tabs); the per-customer
    /// and business receipt lists are pushed and don't.
    var showsMenuButton: Bool = false
    /// Drops the brand-monogram background in favor of a solid color. Used by the iPad split's
    /// sidebar so the GL monogram only appears once on the screen — on the detail pane.
    var solidBackground: Bool = false

    @State private var showingScanner = false
    @State private var scannedImage: UIImage?
    @State private var formInput: ReceiptFormInput?
    @State private var selectedReceipt: Receipt?
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var searchText = ""
    @State private var filter: ReceiptFilter = .all
    @State private var showingMenu = false
    @State private var showingPaywall = false
    @State private var confirmingBulkDelete = false

    @Environment(SubscriptionManager.self) private var subscription

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var scannerSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// Receipts to show after applying the (tab-only) filter and search.
    private var displayed: [Receipt] {
        guard enablesFilters else { return receipts }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return receipts.filter { matchesFilter($0) && (query.isEmpty || matchesSearch($0, query)) }
    }

    var body: some View {
        List {
            // The universal list pins search + filter + total as a sticky section header (it scrolls
            // with the content, then sticks at the top). Scoped lists have no header.
            if enablesFilters {
                Section {
                    receiptRows
                } header: {
                    stickyHeader
                }
            } else {
                receiptRows
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .containerBackground(for: .navigation) {
            if solidBackground {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            } else {
                PrimaryBackground()
            }
        }
        .navigationTitle(Text(title))
        // Force large everywhere — matches Customers and every other list screen. (.automatic would
        // inherit the inline parent when pushed from a customer hub.)
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, 16, for: .scrollContent)   // room for the title's descenders above the sticky header
        .navigationDestination(item: $selectedReceipt) { receipt in
            ReceiptDetailScreen(receipt: receipt)
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { toggleEditing() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmingBulkDelete = true
                    } label: {
                        Text(selection.isEmpty ? String(localized: "Delete") : String(localized: "Delete (\(selection.count))"))
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
            } else {
                if showsMenuButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingMenu = true
                        } label: {
                            MenuButtonLabel()
                        }
                        .accessibilityLabel("Menu")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
        }
        .fullScreenCover(isPresented: $showingScanner, onDismiss: {
            if let image = scannedImage {
                scannedImage = nil
                formInput = ReceiptFormInput(image: image)
            }
        }) {
            DocumentScannerView(
                onComplete: { images in
                    scannedImage = images.first
                    showingScanner = false
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        .navigationDestination(item: $formInput) { input in
            ReceiptFormScreen(defaultCustomer: defaultCustomer, defaultJob: defaultJob, scanImage: input.image)
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .paywallSheet(isPresented: $showingPaywall)
        .confirmationDialog(selection.count == 1 ? "Delete this receipt?" : "Delete \(selection.count) receipts?",
                            isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can’t be undone.")
        }
    }

    /// Start a scan, or show the paywall if a free user is at the receipt cap.
    private func addReceiptScan() {
        if canAddReceipt() { showingScanner = true } else { showingPaywall = true }
    }

    /// Open the manual receipt form, or show the paywall if a free user is at the receipt cap.
    private func addReceiptManual() {
        if canAddReceipt() { formInput = ReceiptFormInput(image: nil) } else { showingPaywall = true }
    }

    private func canAddReceipt() -> Bool {
        AccessGate.canCreate(Receipt.self, cap: FreeTier.receipts, in: modelContext, subscription: subscription)
    }

    // MARK: - Rows

    @ViewBuilder
    private var receiptRows: some View {
        if displayed.isEmpty {
            ContentUnavailableView {
                Label("No Receipts", systemImage: "doc.viewfinder")
            } description: {
                if enablesFilters, !searchText.isEmpty || filter != .all {
                    Text("No receipts match your search or filter.")
                } else {
                    Text(scannerSupported
                         ? "Tap + to scan a receipt."
                         : "Tap + to add a receipt. Scanning needs a device with a camera.")
                }
            }
            .listRowBackground(Color.clear)
        } else {
            ForEach(displayed) { receipt in
                Button {
                    if isEditing {
                        toggleSelection(receipt)
                    } else if let selectionID {
                        selectionID.wrappedValue = receipt.persistentModelID
                    } else {
                        selectedReceipt = receipt
                    }
                } label: {
                    HStack(spacing: 12) {
                        if isEditing {
                            Image(systemName: selection.contains(receipt.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selection.contains(receipt.persistentModelID) ? gold : Color.secondary)
                        }
                        HStack(spacing: 12) {
                            thumbnail(receipt)
                            rowContent(receipt)
                            if !isEditing, selectionID == nil {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, GLLayout.rowContentPadding)
                        .padding(.vertical, GLLayout.rowContentVerticalPadding)
                        .frame(maxWidth: .infinity)
                        .glCardBackground()
                        .glSelectionStroke(selectionID?.wrappedValue == receipt.persistentModelID)
                    }
                    .padding(.horizontal, GLLayout.rowCardInset)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .onDelete(perform: delete)
        }
    }

    /// Search + filter + running total, used as a sticky list header so it scrolls with the content
    /// and then pins at the top — rather than floating over the title in a separate layer.
    private var stickyHeader: some View {
        VStack(spacing: 8) {
            searchFilterBar
            summaryCard
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets())
        .textCase(nil)
    }

    // MARK: - Toolbar pieces

    private var addMenu: some View {
        Menu {
            if scannerSupported {
                Button {
                    addReceiptScan()
                } label: {
                    Label("Scan Receipt", systemImage: "doc.viewfinder")
                }
            }
            Button {
                addReceiptManual()
            } label: {
                Label("Add Manually", systemImage: "square.and.pencil")
            }
            if !displayed.isEmpty {
                Button {
                    toggleEditing()
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Image(systemName: displayed.isEmpty ? "plus" : "ellipsis")
        }
        .accessibilityLabel(displayed.isEmpty ? "Add Receipt" : "More")
    }

    private var filterMenu: some View {
        Menu {
            Button { setFilter(.all) } label: { menuRow(String(localized: "All Receipts"), active: filter == .all) }
            if hasBusinessReceipts || !receiptCustomers.isEmpty {
                Section("Customer") {
                    if hasBusinessReceipts {
                        Button { setFilter(.business) } label: { menuRow(String(localized: "Business"), active: filter == .business) }
                    }
                    ForEach(receiptCustomers) { customer in
                        Button {
                            setFilter(.customer(customer.persistentModelID))
                        } label: {
                            menuRow(customer.listDisplayName, active: filter == .customer(customer.persistentModelID))
                        }
                    }
                }
            }
            if !receiptStores.isEmpty {
                Section("Store") {
                    ForEach(receiptStores, id: \.self) { store in
                        Button { setFilter(.store(store)) } label: { menuRow(store, active: filter == .store(store)) }
                    }
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.title2)
                .foregroundStyle(filter == .all ? Color.secondary : gold)
                .frame(width: 46, height: 46)
                .glassEffect(in: .capsule)
        }
        .accessibilityLabel("Filter")
    }

    @ViewBuilder
    private func menuRow(_ title: String, active: Bool) -> some View {
        if active { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func setFilter(_ newValue: ReceiptFilter) {
        withAnimation(.snappy) { filter = newValue }
    }

    // MARK: - Search + filter (inline, pinned above the list)

    private var searchFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search vendor, customer, notes", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(in: .capsule)

            filterMenu
        }
        .padding(.horizontal, GLLayout.rowCardInset)
    }

    // MARK: - Summary card (pinned, Liquid Glass)

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(displayed.reduce(0) { $0 + $1.total }.formatted(.currency(code: "USD")))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(gold)
                    .contentTransition(.numericText())
                Text("\(displayed.count) receipt\(displayed.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let label = activeFilterLabel {
                Button {
                    setFilter(.all)
                } label: {
                    HStack(spacing: 5) {
                        Text(label).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").imageScale(.small)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.bottom, 6)
    }

    // MARK: - Filtering helpers

    private func matchesFilter(_ receipt: Receipt) -> Bool {
        switch filter {
        case .all: return true
        case .business: return receipt.customer == nil
        case .customer(let id): return receipt.customer?.persistentModelID == id
        case .store(let name):
            return receipt.vendor.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func matchesSearch(_ receipt: Receipt, _ query: String) -> Bool {
        [receipt.vendor, receipt.category, receipt.notes, receipt.customer?.listDisplayName ?? "Business"]
            .contains { $0.lowercased().contains(query) }
    }

    private var receiptCustomers: [Customer] {
        var seen = Set<PersistentIdentifier>()
        var result: [Customer] = []
        for receipt in receipts {
            if let customer = receipt.customer, seen.insert(customer.persistentModelID).inserted {
                result.append(customer)
            }
        }
        return result.sorted { $0.listDisplayName.localizedCaseInsensitiveCompare($1.listDisplayName) == .orderedAscending }
    }

    private var hasBusinessReceipts: Bool {
        receipts.contains { $0.customer == nil }
    }

    private var receiptStores: [String] {
        let names = receipts.map { $0.vendor.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var activeFilterLabel: String? {
        switch filter {
        case .all: return nil
        case .business: return String(localized: "Business")
        case .customer(let id): return receiptCustomers.first { $0.persistentModelID == id }?.listDisplayName
        case .store(let name): return name
        }
    }

    // MARK: - Rows

    private func thumbnail(_ receipt: Receipt) -> some View {
        // Downsamples off the main thread — full-resolution scans must never decode per row while scrolling.
        ScanThumbnail(data: receipt.scanData, size: 44)
    }

    private func rowContent(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(receipt.displayVendor)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(receipt.total.formatted(.currency(code: "USD")))
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(receipt.date.formatted(date: .abbreviated, time: .omitted))
                if showsAssignee {
                    Text("·")
                    Text(receipt.customer?.listDisplayName ?? String(localized: "Business")).lineLimit(1)
                } else if !receipt.category.isEmpty {
                    Text("·")
                    Text(receipt.category).lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func toggleSelection(_ receipt: Receipt) {
        let id = receipt.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleEditing() {
        withAnimation {
            isEditing.toggle()
            if !isEditing { selection.removeAll() }
        }
    }

    private func deleteSelected() {
        withAnimation {
            for receipt in displayed where selection.contains(receipt.persistentModelID) {
                modelContext.delete(receipt)
            }
            selection.removeAll()
        }
        modelContext.saveChanges()
    }

    private func delete(at offsets: IndexSet) {
        for receipt in offsets.map({ displayed[$0] }) {
            modelContext.delete(receipt)
        }
        modelContext.saveChanges()
    }
}

/// A single customer's receipts (pushed from the customer detail screen).
struct ReceiptsListScreen: View {
    let customer: Customer

    var body: some View {
        ReceiptListView(
            receipts: (customer.receipts ?? []).sorted { $0.date > $1.date },
            defaultCustomer: customer,
            enablesFilters: true   // search + filter, same as the all-receipts list
        )
    }
}
