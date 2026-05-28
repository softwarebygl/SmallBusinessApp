//
//  CustomersScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI
import SwiftData

struct CustomersScreen: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    @State private var showingAddSheet = false
    @State private var path: [Customer] = []
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(customers) { customer in
                    Button {
                        if isEditing {
                            toggleSelection(customer)
                        } else {
                            path.append(customer)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isEditing {
                                Image(systemName: selection.contains(customer.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection.contains(customer.persistentModelID) ? gold : Color.secondary)
                            }
                            HStack(spacing: 0) {
                                Text(customer.listDisplayName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                Spacer(minLength: 0)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(gold.opacity(0.15))
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
                .onDelete(perform: deleteCustomers)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .containerBackground(for: .navigation) {
                PrimaryBackground()
            }
            .navigationTitle("Customers")
            .navigationDestination(for: Customer.self) { customer in
                CustomerDetailScreen(customer: customer)
            }
            .toolbar {
                if isEditing || !customers.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isEditing ? "Done" : "Edit") {
                            toggleEditing()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Text(selection.isEmpty ? "Delete" : "Delete (\(selection.count))")
                        }
                        .tint(.red)
                        .disabled(selection.isEmpty)
                    } else {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Customer")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                CustomerFormScreen()
            }
        }
    }

    private func deleteCustomers(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(customers[index])
        }
    }

    private func toggleSelection(_ customer: Customer) {
        let id = customer.persistentModelID
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
            for customer in customers where selection.contains(customer.persistentModelID) {
                modelContext.delete(customer)
            }
            selection.removeAll()
        }
    }
}

#Preview {
    CustomersScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
