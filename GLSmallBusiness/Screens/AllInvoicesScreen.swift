//
//  AllInvoicesScreen.swift
//  GLSmallBusiness
//
//  A global list of every invoice in the store — across all customers, plus any that have no
//  customer. Normally invoices are browsed per-customer, so a stray "no customer" invoice (left by
//  a past sync hiccup) is invisible there yet still counts in Stats. This screen surfaces them so
//  they can be opened and deleted.
//

import SwiftUI
import SwiftData

struct AllInvoicesScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @State private var selectedInvoice: Invoice?
    @State private var searchText = ""

    private var orphanCount: Int { invoices.filter { $0.customer == nil }.count }

    private var visibleInvoices: [Invoice] {
        searchText.isEmpty ? invoices : invoices.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        List {
            if invoices.isEmpty {
                ContentUnavailableView {
                    Label("No Invoices", systemImage: "banknote")
                } description: {
                    Text("Invoices across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                if orphanCount > 0 {
                    Text(orphanCount == 1
                         ? "1 invoice has no customer — it still counts in Stats. Swipe left to delete it."
                         : "\(orphanCount) invoices have no customer — they still count in Stats. Swipe left to delete any you don't want.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(visibleInvoices) { invoice in
                    Button { selectedInvoice = invoice } label: { row(invoice) }
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
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .searchable(text: $searchText, prompt: "Search invoices")
        .overlay {
            if !searchText.isEmpty && visibleInvoices.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle("All Invoices")
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the Menu)
        .navigationDestination(item: $selectedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
    }

    private func row(_ invoice: Invoice) -> some View {
        let orphaned = invoice.customer == nil
        return HStack(spacing: 10) {
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
                    if orphaned {
                        Label("No customer", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    } else {
                        Text(invoice.customer?.listDisplayName ?? "")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func delete(at offsets: IndexSet) {
        for invoice in offsets.map({ visibleInvoices[$0] }) {
            modelContext.delete(invoice)
        }
        modelContext.saveChanges()
    }
}
