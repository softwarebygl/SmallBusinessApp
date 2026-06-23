//
//  AllEstimatesScreen.swift
//  GLSmallBusiness
//
//  A global list of every estimate across all customers (plus any with no customer), mirroring
//  AllInvoicesScreen. Estimates are normally browsed per-customer; this is the Records-section view.
//

import SwiftUI
import SwiftData

struct AllEstimatesScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @State private var selectedEstimate: Estimate?

    private var orphanCount: Int { estimates.filter { $0.customer == nil }.count }

    var body: some View {
        List {
            if estimates.isEmpty {
                ContentUnavailableView {
                    Label("No Estimates", systemImage: "doc.text")
                } description: {
                    Text("Estimates across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                if orphanCount > 0 {
                    Text(orphanCount == 1
                         ? "1 estimate has no customer — it still counts in Stats. Swipe left to delete it."
                         : "\(orphanCount) estimates have no customer — they still count in Stats. Swipe left to delete any you don't want.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(estimates) { estimate in
                    Button { selectedEstimate = estimate } label: { row(estimate) }
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
        .navigationTitle("All Estimates")
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the Menu)
        .navigationDestination(item: $selectedEstimate) { estimate in
            EstimateDetailScreen(estimate: estimate)
        }
    }

    private func row(_ estimate: Estimate) -> some View {
        let orphaned = estimate.customer == nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(estimate.jobTitle.isEmpty ? String(localized: "Untitled estimate") : estimate.jobTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(estimate.total.formatted(.currency(code: "USD")))
                        .font(.headline)
                }
                HStack(spacing: 8) {
                    Text(estimate.number)
                    Text("·")
                    Text(estimate.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    if orphaned {
                        Label("No customer", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    } else {
                        Text(estimate.customer?.listDisplayName ?? "")
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
        for estimate in offsets.map({ estimates[$0] }) {
            modelContext.delete(estimate)
        }
        modelContext.saveChanges()
    }
}
