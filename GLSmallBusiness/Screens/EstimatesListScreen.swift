//
//  EstimatesListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct EstimatesListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    let customer: Customer

    @State private var showingNew = false
    @State private var pendingDelete: [Estimate]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    @State private var showingPaywall = false
    @State private var confirmingBulkDelete = false
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var selectedEstimate: Estimate?
    @State private var searchText = ""

    private var gold: Color { GLTheme.accentFill }

    private var estimates: [Estimate] {
        customer.liveRows(customer.estimates).sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleEstimates: [Estimate] {
        searchText.isEmpty ? estimates : estimates.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        // F24: draws "This customer was removed" once the customer is deleted while open.
        LiveRecordGate(customer, title: "Estimates") { aliveBody }
    }

    @ViewBuilder private var aliveBody: some View {
        List {
            GLInListSearchHeader(text: $searchText, prompt: "Search estimates").asPlainListRow
            if estimates.isEmpty {
                ContentUnavailableView {
                    Label("No estimates", systemImage: "doc.text")
                } description: {
                    Text("Tap + to create an estimate for \(customer.listDisplayName).")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleEstimates) { estimate in
                    Button {
                        if isEditing {
                            toggleSelection(estimate)
                        } else {
                            selectedEstimate = estimate
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isEditing {
                                Image(systemName: selection.contains(estimate.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection.contains(estimate.persistentModelID) ? gold : GLTheme.textSecondary)
                            }
                            HStack(spacing: 8) {
                                rowContent(estimate)
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
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Estimates"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) {
            PrimaryBackground()
        }
        
        .overlay {
            if !searchText.isEmpty && visibleEstimates.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(mbLoc("Estimates")))
        .toolbarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedEstimate) { estimate in
            EstimateDetailScreen(estimate: estimate)
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
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
            } else {
            // "+" IS PERMANENT — it used to become "…" once the list had a row,
            // moving the most-repeated action after the first success. Apple keeps
            // + as + and adds a SECOND trailing control for secondary actions.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newEstimate()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Estimate")
                }
                if !(estimates.isEmpty) {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Law 40: a one-option menu is banned — the action IS the button.
                        Button("Select") { toggleEditing() }
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showingNew) {
            EstimateFormScreen(customer: customer)
        }
        .paywallSheet(isPresented: $showingPaywall)
        .alert(selection.count == 1 ? "Delete this estimate?" : "Delete \(selection.count) estimates?",
               isPresented: $confirmingBulkDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Their line items are removed too. This can’t be undone.")
        }
    }

    /// Open the new-estimate form, or the paywall if a free user is at the estimate cap.
    private func newEstimate() {
        if AccessGate.attemptCreate(Estimate.self, cap: FreeTier.estimates, in: modelContext,
                                    subscription: subscription, operation: .saveEstimate,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNew = true
        }
    }

    private func rowContent(_ estimate: Estimate) -> some View {
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
                EstimateStatusBadge(estimate: estimate)
            }
            .font(.caption)
            .foregroundStyle(GLTheme.textSecondary)
        }
    }

    private func toggleSelection(_ estimate: Estimate) {
        let id = estimate.persistentModelID
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
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteEstimate, into: $readOnlyRefusal) else { return }
        withAnimation {
            deleteThroughService(estimates.filter { selection.contains($0.persistentModelID) })
            selection.removeAll()
        }
    }

    private func delete(_ items: [Estimate]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteEstimate, into: $readOnlyRefusal) else { return }
        deleteThroughService(items)
    }

    /// DeletionService deletes and saves. Rows a sync already removed are skipped, as before.
    private func deleteThroughService(_ items: [Estimate]) {
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.estimate),
                                       origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}

#Preview {
    NavigationStack {
        EstimatesListScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
    }
    .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}
