//
//  ReceiptsListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData
import VisionKit

private struct ReceiptFormInput: Identifiable, Hashable {
    let id = UUID()
    /// A finished scan, already stitched and encoded off the main thread; nil for a manual receipt.
    let scan: ReceiptScanImage?

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The scanner's pages, waiting to be stitched and encoded once the scanner has closed.
private struct ScanBatch {
    let id = UUID()
    let pages: [UIImage]
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
    /// Opens the document scanner as soon as the screen appears. Used by the "Scan
    /// receipt" entry on the Jobs tab, so capturing a materials slip at a supply-house
    /// counter is two taps with one hand free instead of four down Contacts.
    var autoScan: Bool = false
    var showsAssignee: Bool = false
    var enablesFilters: Bool = false
    /// Navigation title. Defaults to "Receipts" for the tab; the Records-section "All Receipts"
    /// entry overrides it so it reads consistently with the other Records lists.
    /// `String.LocalizationValue` so the bar gets a RESOLVED string via `mbLoc` — a
    /// `LocalizedStringResource` title leaves UIKit's cached bar text stale after an
    /// in-app language switch (the resolved-string rule every other title follows).
    var title: String.LocalizationValue = "Expenses"
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
    @State private var pendingDelete: [Receipt]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ReceiptService threw that the list did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    /// The scanner's pages (already shrunk, law 62) until the scanner finishes closing.
    @State private var scannedPages: [UIImage] = []
    /// Pages being stitched and encoded off the main thread (the `.task` below).
    @State private var scanToPrepare: ScanBatch?
    @State private var scanFailed = false
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

    private var gold: Color { GLTheme.accentFill }
    private var scannerSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// Receipts to show after applying the (tab-only) filter and search.
    private var displayed: [Receipt] {
        guard enablesFilters else { return receipts }
        // An untagged receipt has always matched the word "Business" here (the row's label).
        return receipts.filter { matchesFilter($0) && $0.matchesSearch(searchText, untaggedLabel: "Business") }
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
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this receipt?") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The sticky-header search is GoldLifeUI's in-list field (not a native .searchable), so it needs the app's
        // standard scroll- and tap-to-dismiss wired explicitly — the same helper the forms use.
        .dismissesKeyboardOnInteraction()
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) {
            if solidBackground {
                GLTheme.background.ignoresSafeArea()
            } else {
                PrimaryBackground()
            }
        }
        .navigationTitle(GLScript.padded(mbLoc(title)))
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc(title))), for: .scrollContent)   // per-string descender clearance
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
                        Text(selection.isEmpty ? mbLoc("Delete") : mbLoc("Delete (\(selection.count))"))
                    }
                    .tint(GLTheme.statusCritical)
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
                ToolbarItem(placement: .topBarTrailing) {
                    selectMenu
                }
            }
        }
        // Camera up on arrival when opened from the "Scan receipt" entry. Guarded by
        // scannerSupported so a simulator or a device without a camera lands on the
        // list instead of a dead sheet.
        .task {
            guard autoScan, scannerSupported else { return }
            addReceiptScan()
        }
        .fullScreenCover(isPresented: $showingScanner, onDismiss: {
            guard !scannedPages.isEmpty else { return }
            scanToPrepare = ScanBatch(pages: scannedPages)
            scannedPages = []
        }) {
            DocumentScannerView(
                onComplete: { pages in
                    // The scanner lets the user batch pages ("Save (3)") but a Receipt stores a
                    // single scan — every page is stitched into one tall image (below) so nothing
                    // is dropped.
                    scannedPages = pages
                    showingScanner = false
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        // Stitch and encode once, off the main thread, then open the form with the result.
        .task(id: scanToPrepare?.id) {
            guard let batch = scanToPrepare else { return }
            let scan = await ReceiptScanPages.prepared(batch.pages)
            guard !Task.isCancelled else { return }
            scanToPrepare = nil
            if let scan { formInput = ReceiptFormInput(scan: scan) } else { scanFailed = true }
        }
        .alert("Couldn’t read that scan", isPresented: $scanFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try scanning the receipt again.")
        }
        .navigationDestination(item: $formInput) { input in
            ReceiptFormScreen(defaultCustomer: defaultCustomer, defaultJob: defaultJob, scanImage: input.scan)
        }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .paywallSheet(isPresented: $showingPaywall)
        .alert(selection.count == 1 ? "Delete this receipt?" : "Delete \(selection.count) receipts?",
               isPresented: $confirmingBulkDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can’t be undone.")
        }
    }

    /// Start a scan, or explain why not: the paywall at the free cap, the read-only refusal when
    /// the subscription has lapsed. `attemptCreate` picks, so the two can never both appear.
    private func addReceiptScan() {
        if attemptAddReceipt() { showingScanner = true }
    }

    /// Open the manual receipt form, with the same one-outcome gate as the scan.
    private func addReceiptManual() {
        if attemptAddReceipt() { formInput = ReceiptFormInput(scan: nil) }
    }

    private func attemptAddReceipt() -> Bool {
        AccessGate.attemptCreate(Receipt.self, cap: FreeTier.receipts, in: modelContext,
                                 subscription: subscription, operation: .saveReceipt,
                                 paywall: $showingPaywall, refusal: $readOnlyRefusal)
    }


    // MARK: - Rows

    @ViewBuilder
    private var receiptRows: some View {
        if displayed.isEmpty {
            ContentUnavailableView {
                Label("No receipts", systemImage: "doc.viewfinder")
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
                            // Drawn here; spoken through the Selected trait on the row below.
                            Image(systemName: selection.contains(receipt.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selection.contains(receipt.persistentModelID) ? gold : GLTheme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        HStack(spacing: 12) {
                            thumbnail(receipt)
                            rowContent(receipt)
                            if !isEditing, selectionID == nil {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(GLTheme.textTertiary)
                                    .accessibilityHidden(true)
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
                // A ticked receipt in multi-select, or the iPad's open one, reads "Selected".
                .accessibilityAddTraits(
                    (isEditing && selection.contains(receipt.persistentModelID))
                        || (!isEditing && selectionID?.wrappedValue == receipt.persistentModelID)
                        ? .isSelected : [])
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .confirmFirstDeleteSwipe { pendingDelete = [receipt] }
            }
        }
    }

    /// Search + filter + running total, used as a sticky list header so it scrolls with the content
    /// and then pins at the top — rather than floating over the title in a separate layer.
    private var stickyHeader: some View {
        VStack(spacing: 8) {
            summaryCard
            searchFilterBar
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
        } label: {
            // ALWAYS "+". This glyph used to be driven by `displayed.isEmpty` —
            // which is the FILTERED list — so the button silently mutated from +
            // to … while the person was typing in the search field. The create
            // affordance may never depend on what a filter happens to be showing.
            // Select moved to its own trailing control below.
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add Receipt")
    }

    /// Secondary actions, in their own control so "+" never changes meaning.
    @ViewBuilder
    private var selectMenu: some View {
        if !displayed.isEmpty {
            // Law 40: a one-option menu is banned — the action IS the button
            // (missed in the first sweep; the regression suite caught it).
            Button("Select") { toggleEditing() }
        }
    }

    /// The fleet filter symbol (GoldLifeUI `GLFilterButton`, REQUIREMENTS 47a): every scope
    /// option lives in its menu, and it fills gold while one is in use.
    private var filterButton: GLFilterButton<some View> {
        GLFilterButton(activeCount: filter == .all ? 0 : 1, menu: { filterMenuContent })
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Button { setFilter(.all) } label: { menuRow(mbLoc("All Expenses"), active: filter == .all) }
        if hasBusinessReceipts || !receiptCustomers.isEmpty {
            Section("Customer") {
                if hasBusinessReceipts {
                    Button { setFilter(.business) } label: { menuRow(mbLoc("Business"), active: filter == .business) }
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
        GLSearchFilterBar(text: $searchText, prompt: "Search vendor, customer, notes", filter: filterButton)
            .padding(.horizontal, GLLayout.rowCardInset)
    }

    // MARK: - Summary card (pinned, Liquid Glass)

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(GLTheme.textSecondary)
                Text(DomainMoney.roundedSum(displayed.map(\.total)).formatted(.money))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(GLTheme.accentText)
                    .contentTransition(.numericText())
                Text("\(displayed.count) receipt\(displayed.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(GLTheme.textSecondary)
            }
            Spacer(minLength: 8)
            if let label = activeFilterLabel {
                Button {
                    setFilter(.all)
                } label: {
                    HStack(spacing: 5) {
                        Text(label).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GLTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(in: .capsule)
                    .frame(minHeight: 44)   // law 16: the capsule stays drawn; the tap is 44 pt
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Clears the filter"))
            }
        }
        .padding(GLLayout.rowContentPadding)
        .glassEffect(in: .rect(cornerRadius: 20, style: .continuous))
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
        case .business: return mbLoc("Business")
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
                Text(receipt.total.formatted(.money))
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(receipt.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                if showsAssignee {
                    Text("·")
                    Text(receipt.customer?.listDisplayName ?? mbLoc("Business")).lineLimit(1)
                } else if !receipt.category.isEmpty {
                    Text("·")
                    Text(receipt.category).lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(GLTheme.textSecondary)
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
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteReceipt, into: $readOnlyRefusal) else { return }
        // Delete the whole selection, not selection ∩ displayed — the alert promised
        // `selection.count`, and changing the search/filter after selecting must not
        // silently skip the now-hidden rows.
        let chosen = receipts.filter { selection.contains($0.persistentModelID) }
        withAnimation {
            deleteThroughService(chosen)
            selection.removeAll()
        }
    }

    private func delete(_ items: [Receipt]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteReceipt, into: $readOnlyRefusal) else { return }
        deleteThroughService(items)
    }

    /// DeletionService deletes and saves. Rows a sync already removed are skipped, as before.
    private func deleteThroughService(_ items: [Receipt]) {
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.receipt),
                                       origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}

/// A single customer's receipts (pushed from the customer detail screen).
struct ReceiptsListScreen: View {
    let customer: Customer

    var body: some View {
        // F24: draws "This customer was removed" once the customer is deleted while open.
        LiveRecordGate(customer, title: "Expenses") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        ReceiptListView(
            receipts: customer.liveRows(customer.receipts).sorted { $0.date > $1.date },
            defaultCustomer: customer,
            enablesFilters: true   // search + filter, same as the all-receipts list
        )
    }
}
