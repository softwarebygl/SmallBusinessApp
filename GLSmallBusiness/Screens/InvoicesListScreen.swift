//
//  InvoicesListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct InvoicesListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    let customer: Customer

    @State private var showingNew = false
    @State private var pendingDelete: [Invoice]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift). A paid invoice's money is
    /// settled, so the server refuses to delete it or anything inside it.
    @State private var showingPaidLock = false
    @State private var showingPaywall = false
    @State private var confirmingBulkDelete = false
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var selectedInvoice: Invoice?
    @State private var searchText = ""

    private var gold: Color { GLTheme.accentFill }

    private var invoices: [Invoice] {
        customer.liveRows(customer.invoices).sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleInvoices: [Invoice] {
        searchText.isEmpty ? invoices : invoices.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        // F24: draws "This customer was removed" once the customer is deleted while open.
        LiveRecordGate(customer, title: "Invoices") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        List {
            GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search invoices")).asPlainListRow
            if invoices.isEmpty {
                ContentUnavailableView {
                    Label("No invoices", systemImage: "banknote")
                } description: {
                    Text("Tap + to create an invoice for \(customer.listDisplayName).")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleInvoices) { invoice in
                    Button {
                        if isEditing {
                            toggleSelection(invoice)
                        } else {
                            selectedInvoice = invoice
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isEditing {
                                Image(systemName: selection.contains(invoice.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection.contains(invoice.persistentModelID) ? gold : GLTheme.textSecondary)
                            }
                            HStack(spacing: 8) {
                                rowContent(invoice)
                                if !isEditing {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(GLTheme.textTertiary)
                                }
                            }
                            .padding(.horizontal, GLLayout.rowContentPadding)
                            .padding(.vertical, GLLayout.rowContentVerticalPadding)
                            .frame(maxWidth: .infinity)
                            .glCardBackground()
                        }
                        .padding(.horizontal, GLLayout.rowCardInset)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .confirmFirstDeleteSwipe { requestDelete([invoice]) }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this invoice?") {
            delete($0)
        }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Invoices"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        
        .overlay {
            if !searchText.isEmpty && visibleInvoices.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(mbLoc("Invoices")))
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the hub)
        .navigationDestination(item: $selectedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { toggleEditing() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        // The whole batch is refused when ANY selection is paid, rather than
                        // deleting the rest quietly: a paid invoice in a multi-select is almost
                        // always a mis-tap, and "19 of your 20 went" is a worse thing to discover
                        // afterwards than nothing happening with a sentence saying why.
                        if selectedInvoices.contains(where: \.isMoneyLocked) {
                            showingPaidLock = true
                        } else if selectedInvoices.contains(where: \.hasRecordedPayments) {
                            // Payments are append-only (law 60): refuse before the alert, the
                            // same way DeletionService would after it.
                            domainError = .hasRecordedPayments(customer: false)
                        } else {
                            confirmingBulkDelete = true
                        }
                    } label: {
                        Text(selection.isEmpty ? mbLoc("Delete") : mbLoc("Delete (\(selection.count))"))
                    }
                    .tint(GLTheme.statusCritical)
                    .disabled(selection.isEmpty)
                }
            } else {
            // "+" IS PERMANENT — it used to become "…" once the list had a row,
            // moving the most-repeated action after the first success. Apple keeps
            // + as + and adds a SECOND trailing control for secondary actions.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newInvoice()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Invoice")
                }
                if !(invoices.isEmpty) {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Law 40: a one-option menu is banned — the action IS the button.
                        Button("Select") { toggleEditing() }
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showingNew) {
            InvoiceFormScreen(customer: customer)
        }
        .paywallSheet(isPresented: $showingPaywall)
        .alert(selection.count == 1 ? "Delete this invoice?" : "Delete \(selection.count) invoices?",
               isPresented: $confirmingBulkDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            // DeletionService's own words, so the alert can't drift from what the delete does.
            if let first = selectedInvoices.first {
                Text(DeletionService.Target.invoice(first).cascadeDescription)
            }
        }
    }

    /// Open the new-invoice form, or the paywall if a free user is at the invoice cap.
    private func newInvoice() {
        // One call, one outcome: at the free cap it opens the paywall, lapsed it refuses out loud.
        // The old `if canCreate { } else { paywall }` would have shown a lapsed subscriber BOTH.
        if AccessGate.attemptCreate(Invoice.self, cap: FreeTier.invoices, in: modelContext,
                                    subscription: subscription, operation: .saveInvoice,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNew = true
        }
    }

    private func rowContent(_ invoice: Invoice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.jobTitle.isEmpty ? mbLoc("Untitled invoice") : invoice.jobTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(invoice.total.formatted(.money))
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(invoice.number)
                Text("·")
                Text(invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                Spacer()
                InvoiceStatusBadge(invoice: invoice)
            }
            .font(.caption)
            .foregroundStyle(GLTheme.textSecondary)
            if invoice.amountPaid > 0 && !invoice.isPaid {
                HStack {
                    Spacer()
                    Text("Balance \(invoice.balanceDue.formatted(.money))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GLTheme.accentText)
                }
            }
        }
    }

    private func toggleSelection(_ invoice: Invoice) {
        let id = invoice.persistentModelID
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleEditing() {
        withAnimation {
            isEditing.toggle()
            if !isEditing { selection.removeAll() }
        }
    }

    /// The invoices the multi-select toolbar would act on. Resolved once so the paid-lock check
    /// and the delete itself can never disagree about the set.
    private var selectedInvoices: [Invoice] {
        invoices.filter { selection.contains($0.persistentModelID) }
    }

    private func deleteSelected() {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteInvoice, into: $readOnlyRefusal) else { return }
        withAnimation {
            deleteThroughService(invoices.filter { selection.contains($0.persistentModelID) })
            selection.removeAll()
        }
    }

    /// The swipe only stages the delete for its alert (law 8). A paid invoice is the record of
    /// money actually collected, and the server refuses to tombstone it (paid_locked). Explain
    /// rather than stage a delete that would only diverge from the server.
    private func requestDelete(_ swiped: [Invoice]) {
        if swiped.contains(where: \.isMoneyLocked) {
            showingPaidLock = true
        } else if swiped.contains(where: \.hasRecordedPayments) {
            domainError = .hasRecordedPayments(customer: false)
        } else {
            pendingDelete = swiped
        }
    }

    private func delete(_ items: [Invoice]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteInvoice, into: $readOnlyRefusal) else { return }
        deleteThroughService(items)
    }

    /// DeletionService re-checks the paid lock (all-or-nothing), deletes and saves now, so Stats and
    /// sync see it right away. Rows a sync already removed are skipped, as before.
    private func deleteThroughService(_ items: [Invoice]) {
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.invoice),
                                       origin: .screen, in: modelContext)
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
