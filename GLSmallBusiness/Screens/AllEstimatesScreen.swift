//
//  AllEstimatesScreen.swift
//  GLSmallBusiness
//
//  A global list of every estimate across all customers (plus any with no customer), mirroring
//  AllInvoicesScreen. Estimates are normally browsed per-customer; this is the Records-section view.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct AllEstimatesScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @State private var selectedEstimate: Estimate?
    @State private var pendingDelete: [Estimate]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    @State private var searchText = ""

    private var orphanCount: Int { estimates.filter { $0.customer == nil }.count }

    private var visibleEstimates: [Estimate] {
        searchText.isEmpty ? estimates : estimates.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        List {
            if estimates.isEmpty {
                ContentUnavailableView {
                    Label("No estimates", systemImage: "doc.text")
                } description: {
                    Text("Estimates across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                if orphanCount > 0 {
                    Text(orphanCount == 1
                         ? "1 estimate has no customer — it still counts in Stats. Swipe left to delete it."
                         : "\(orphanCount) estimates have no customer — they still count in Stats. Swipe left to delete any you don’t want.")
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                        .padding(.horizontal, GLLayout.rowCardInset)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search estimates")).asPlainListRow
                ForEach(visibleEstimates) { estimate in
                    Button { selectedEstimate = estimate } label: { row(estimate) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { pendingDelete = [estimate] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this estimate?") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Estimates"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        
        .overlay {
            if !searchText.isEmpty && visibleEstimates.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(mbLoc("All Estimates")))
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
                    Text(estimate.jobTitle.isEmpty ? mbLoc("Untitled estimate") : estimate.jobTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(estimate.isOptionsMode
                     ? mbLoc("\(estimate.sortedGroups.count) options")
                     : estimate.total.formatted(.money))
                        .font(.headline)
                }
                HStack(spacing: 8) {
                    Text(estimate.number)
                    Text("·")
                    Text(estimate.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    Spacer()
                    if orphaned {
                        Label("No customer", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(GLTheme.statusAttention)
                    } else {
                        Text(estimate.customer?.listDisplayName ?? "")
                    }
                }
                .font(.caption)
                .foregroundStyle(GLTheme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GLTheme.textTertiary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func delete(_ items: [Estimate]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteEstimate, into: $readOnlyRefusal) else { return }
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.estimate),
                                       origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
