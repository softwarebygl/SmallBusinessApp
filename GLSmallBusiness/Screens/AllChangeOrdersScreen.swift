//
//  AllChangeOrdersScreen.swift
//  GLSmallBusiness
//
//  A global list of every change order across all invoices, for the Records section. Change orders
//  are normally reached through their invoice's ••• menu; this surfaces them all in one place.
//

import SwiftUI
import SwiftData

struct AllChangeOrdersScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \ChangeOrder.createdAt, order: .reverse) private var changeOrders: [ChangeOrder]
    @State private var selectedChangeOrder: ChangeOrder?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        List {
            if changeOrders.isEmpty {
                ContentUnavailableView {
                    Label("No Change Orders", systemImage: "pencil.and.list.clipboard")
                } description: {
                    Text("Change orders you add to an invoice will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(changeOrders) { changeOrder in
                    Button { selectedChangeOrder = changeOrder } label: { row(changeOrder) }
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
        .navigationTitle("All Change Orders")
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the Menu)
        .sheet(item: $selectedChangeOrder) { changeOrder in
            ChangeOrderDetailSheet(changeOrder: changeOrder).glAppearance(colorScheme)
        }
    }

    private func row(_ changeOrder: ChangeOrder) -> some View {
        let signedTotal = (changeOrder.total >= 0 ? "+" : "") + changeOrder.total.formatted(.currency(code: "USD"))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(changeOrder.title.isEmpty ? changeOrder.number : changeOrder.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(signedTotal).font(.headline)
                }
                HStack(spacing: 8) {
                    Text(changeOrder.number)
                    Text("·")
                    Text(changeOrder.status.label)
                    if changeOrder.appliedToInvoice { Text("· added") }
                    Spacer()
                    if let invoiceNumber = changeOrder.invoice?.number, !invoiceNumber.isEmpty {
                        Text(invoiceNumber)
                    } else {
                        Label("No invoice", systemImage: "doc.badge.ellipsis")
                            .foregroundStyle(.orange)
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
        for changeOrder in offsets.map({ changeOrders[$0] }) {
            modelContext.delete(changeOrder)
        }
        try? modelContext.save()
    }
}
