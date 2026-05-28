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
    @State private var editingCustomer: Customer?

    var body: some View {
        NavigationStack {
            List {
                ForEach(customers) { customer in
                    Button {
                        editingCustomer = customer
                    } label: {
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
                                .fill(GLColor.gold.render(in: colorScheme).opacity(0.15))
                        )
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Customer")
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                CustomerFormScreen()
            }
            .sheet(item: $editingCustomer) { customer in
                CustomerFormScreen(editing: customer)
            }
        }
    }

    private func deleteCustomers(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(customers[index])
        }
    }
}

private extension Customer {
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = (businessName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return "No name"
    }
}

#Preview {
    CustomersScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
