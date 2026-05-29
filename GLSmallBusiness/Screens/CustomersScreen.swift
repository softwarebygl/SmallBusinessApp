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
    @Query private var businessProfiles: [BusinessProfile]

    @State private var showingAddSheet = false
    @State private var showingMenu = false
    @State private var path: [Customer] = []
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    @ViewBuilder
    private var menuButtonLabel: some View {
        if let data = businessProfiles.first?.logo(for: colorScheme), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(gold.opacity(0.4), lineWidth: 1))
                .padding(-7)
        } else {
            Image(systemName: "line.3.horizontal")
        }
    }

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
                            ZStack(alignment: .leading) {
                                HStack(spacing: 8) {
                                    Spacer(minLength: 0)
                                    Text(customer.listDisplayName)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if !isEditing {
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, GLLayout.rowContentVerticalPadding)
                                .padding(.leading, 74)
                                .padding(.trailing, GLLayout.rowContentPadding)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(gold.opacity(0.15))
                                )

                                CustomerAvatar(customer: customer, size: 60)
                                    .padding(.leading, 6)
                            }
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
                ToolbarItem(placement: .topBarLeading) {
                    if isEditing {
                        Button("Done") { toggleEditing() }
                    } else {
                        Button {
                            showingMenu = true
                        } label: {
                            menuButtonLabel
                        }
                        .accessibilityLabel("Menu")
                    }
                }
                if isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Text(selection.isEmpty ? "Delete" : "Delete (\(selection.count))")
                        }
                        .tint(.red)
                        .disabled(selection.isEmpty)
                    }
                } else if customers.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Customer")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showingAddSheet = true
                            } label: {
                                Label("New Customer", systemImage: "plus")
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
            .sheet(isPresented: $showingAddSheet) {
                CustomerFormScreen()
            }
            .sheet(isPresented: $showingMenu) {
                MenuScreen()
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
