//
//  PriceSheetScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 9/15/26.
//
//  The Price Sheet catalog hub: list, organize, search, and manage standard services
//  and materials. The AI Assistant and document creators use this catalog to resolve
//  prices, units, and details automatically.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct PriceSheetScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PriceSheetItem.name) private var allItems: [PriceSheetItem]

    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var editingItem: PriceSheetItem?
    /// The item a swipe staged for the delete alert. Catalog items are local-only, so a delete
    /// can't be recovered: the swipe only asks (law 8).
    @State private var pendingDelete: [PriceSheetItem]?
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    // Search and grouping are PriceSheetService's, so the assistant finds items as listed here.
    private var filteredItems: [PriceSheetItem] { PriceSheetService.search(allItems, query: searchText) }

    private var categorizedItems: [String: [PriceSheetItem]] { PriceSheetService.grouped(filteredItems) }

    private var sortedCategories: [String] { PriceSheetService.sortedCategories(categorizedItems.keys) }

    var body: some View {
        // A search with no matches keeps the list, which holds the only search field, and lays
        // "No Results" over it, so the person can still edit or clear the search (QA 2026-10-03
        // F51: swapping the list out took the field with it). Same as the Customers list.
        Group {
            if allItems.isEmpty {
                emptyView
            } else {
                listView
                    .overlay {
                        if !searchText.isEmpty && filteredItems.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
            }
        }
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Price Sheet"))), for: .scrollContent)
        .navigationTitle(GLScript.padded(mbLoc("Price Sheet")))
        .toolbarTitleDisplayMode(.large)   // law 57: large even when pushed from an inline parent
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Catalog Item")
            }
        }
        // Data-entry forms PUSH (law 7), so the form gets Back with the discard guard instead
        // of a sheet a stray swipe dismissed with the entry in it (audit 2026-10-03 F134).
        .navigationDestination(isPresented: $showingAdd) {
            PriceSheetItemFormScreen()
        }
        .navigationDestination(item: $editingItem) { item in
            PriceSheetItemFormScreen(editing: item)
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
    }

    private var listView: some View {
        List {
            GLInListSearchHeader(text: $searchText, prompt: "Search services & materials").asListRow
            ForEach(sortedCategories, id: \.self) { category in
                Section(category) {
                    ForEach(categorizedItems[category] ?? []) { item in
                        Button {
                            editingItem = item
                        } label: {
                            itemRow(item)
                        }
                        .buttonStyle(.plain)
                        .confirmFirstDeleteSwipe { pendingDelete = [item] }
                    }
                }
            }
        }
        .glFormBackground()
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this item?") { items in
            items.forEach(delete)
        }
    }

    private func itemRow(_ item: PriceSheetItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GLTheme.textPrimary)

                Spacer()

                Text("\(item.unitPrice.formatted(.money)) / \(item.unit.abbreviation)")
                    .font(.subheadline.bold())
                    .foregroundStyle(gold)
            }

            if !item.details.isEmpty {
                Text(item.details)
                    .font(.caption)
                    .foregroundStyle(GLTheme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                badge(item.kind.label, color: item.kind == .labor ? GLTheme.accentText : GLTheme.textSecondary)
                if item.isTaxable {
                    badge(mbLoc("Taxable"), color: GLTheme.statusAttention)
                }
                if let discount = PriceSheetService.discountBadge(item.discountType, item.discountValue) {
                    badge(discount, color: GLTheme.statusGood)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tag.fill")
                .font(.system(size: 48))
                .foregroundStyle(gold)
                .padding(.bottom, 8)

            Text("No Catalog Items")
                .font(.title3.bold())

            Group {
                if MBFeatureFlags.assistantEnabled {
                    Text("Add standard services, labor rates, and materials so the Assistant and your estimates can price jobs automatically.")
                } else {
                    Text("Add standard services, labor rates, and materials so your estimates can price jobs automatically.")
                }
            }
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingAdd = true
            } label: {
                Label("Add First Item", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(gold)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .glFormBackground()
    }

    private func delete(_ item: PriceSheetItem) {
        guard ReadOnlyGate.allows(.deletePriceSheetItem, into: $readOnlyRefusal) else { return }
        // A local delete (the catalog never syncs); DeletionService refuses a row already gone.
        do {
            try DeletionService.delete([.priceItem(item)], origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
