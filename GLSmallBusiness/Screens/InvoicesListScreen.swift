//
//  InvoicesListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

struct InvoicesListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let customer: Customer

    @State private var showingNew = false
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var selectedInvoice: Invoice?
    @State private var searchText = ""

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var invoices: [Invoice] {
        (customer.invoices ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleInvoices: [Invoice] {
        searchText.isEmpty ? invoices : invoices.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        List {
            if invoices.isEmpty {
                ContentUnavailableView {
                    Label("No Invoices", systemImage: "banknote")
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
                                    .foregroundStyle(selection.contains(invoice.persistentModelID) ? gold : Color.secondary)
                            }
                            HStack(spacing: 8) {
                                rowContent(invoice)
                                if !isEditing {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
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
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, 10, for: .scrollContent)   // breathing room below the large title's descenders
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        .searchable(text: $searchText, prompt: "Search invoices")
        .overlay {
            if !searchText.isEmpty && visibleInvoices.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle("Invoices")
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
                        deleteSelected()
                    } label: {
                        Text(selection.isEmpty ? String(localized: "Delete") : String(localized: "Delete (\(selection.count))"))
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
            } else if invoices.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Invoice")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNew = true
                        } label: {
                            Label("New Invoice", systemImage: "plus")
                        }
                        Button {
                            toggleEditing()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .navigationDestination(isPresented: $showingNew) {
            InvoiceFormScreen(customer: customer)
        }
    }

    private func rowContent(_ invoice: Invoice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.jobTitle.isEmpty ? String(localized: "Untitled invoice") : invoice.jobTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(invoice.total.formatted(.currency(code: "USD")))
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(invoice.number)
                Text("·")
                Text(invoice.createdAt.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                InvoiceStatusBadge(invoice: invoice)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if invoice.amountPaid > 0 && !invoice.isPaid {
                HStack {
                    Spacer()
                    Text("Balance \(invoice.balanceDue.formatted(.currency(code: "USD")))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(gold)
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

    private func deleteSelected() {
        withAnimation {
            for invoice in invoices where selection.contains(invoice.persistentModelID) {
                modelContext.delete(invoice)
            }
            selection.removeAll()
        }
        // Commit immediately so the deletion reflects in Stats and syncs to CloudKit right away,
        // rather than waiting on deferred autosave.
        modelContext.saveChanges()
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { visibleInvoices[$0] }
        for invoice in toDelete {
            modelContext.delete(invoice)
        }
        modelContext.saveChanges()
    }
}
