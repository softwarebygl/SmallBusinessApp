//
//  EstimatesListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

struct EstimatesListScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let customer: Customer

    @State private var showingNew = false
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var selectedEstimate: Estimate?

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var estimates: [Estimate] {
        (customer.estimates ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if estimates.isEmpty {
                ContentUnavailableView {
                    Label("No Estimates", systemImage: "doc.text")
                } description: {
                    Text("Tap + to create an estimate for \(customer.listDisplayName).")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(estimates) { estimate in
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
                                    .foregroundStyle(selection.contains(estimate.persistentModelID) ? gold : Color.secondary)
                            }
                            HStack(spacing: 8) {
                                rowContent(estimate)
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
        .navigationTitle("Estimates")
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
                        deleteSelected()
                    } label: {
                        Text(selection.isEmpty ? String(localized: "Delete") : String(localized: "Delete (\(selection.count))"))
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
            } else if estimates.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Estimate")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNew = true
                        } label: {
                            Label("New Estimate", systemImage: "plus")
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
        .sheet(isPresented: $showingNew) {
            EstimateFormScreen(customer: customer).glAppearance(colorScheme)
        }
    }

    private func rowContent(_ estimate: Estimate) -> some View {
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
                EstimateStatusBadge(estimate: estimate)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        withAnimation {
            for estimate in estimates where selection.contains(estimate.persistentModelID) {
                modelContext.delete(estimate)
            }
            selection.removeAll()
        }
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { estimates[$0] }
        for estimate in toDelete {
            modelContext.delete(estimate)
        }
        try? modelContext.save()
    }
}

#Preview {
    NavigationStack {
        EstimatesListScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
    }
    .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}
