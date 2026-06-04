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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    @State private var showingAddSheet = false
    @State private var showingMenu = false
    @State private var path: [Customer] = []                  // iPhone push navigation
    @State private var selectedCustomerID: PersistentIdentifier?  // iPad detail selection
    @State private var isEditing = false                          // iPhone multi-select
    @State private var selection = Set<PersistentIdentifier>()

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var selectedCustomer: Customer? {
        customers.first { $0.persistentModelID == selectedCustomerID }
    }

    var body: some View {
        // NavigationSplitView's compact collapse misbehaves inside a TabView, so iPhone keeps the
        // proven NavigationStack push flow and iPad uses the split — same rows/chrome either way.
        if sizeClass == .regular {
            splitView
        } else {
            stackView
        }
    }

    // MARK: - iPhone (stack)

    private var stackView: some View {
        NavigationStack(path: $path) {
            List {
                if customers.isEmpty {
                    emptyState
                } else {
                    ForEach(customers) { customer in
                        Button {
                            if isEditing { toggleSelection(customer) } else { path.append(customer) }
                        } label: {
                            customerRow(customer, isSelected: false, showsChevron: !isEditing,
                                        selectionMark: isEditing ? selection.contains(customer.persistentModelID) : nil)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                    .onDelete(perform: deleteCustomers)
                }
            }
            .modifier(CustomerListChrome())
            .navigationDestination(for: Customer.self) { customer in
                CustomerDetailScreen(customer: customer)
            }
            .toolbar { customerStackToolbar }
            .sheet(isPresented: $showingAddSheet) { CustomerFormScreen().glAppearance(colorScheme) }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        }
    }

    // MARK: - iPad (split)

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selectedCustomerID) {
                if customers.isEmpty {
                    emptyState
                } else {
                    ForEach(customers) { customer in
                        customerRow(customer, isSelected: selectedCustomerID == customer.persistentModelID, showsChevron: false)
                            .tag(customer.persistentModelID)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                    .onDelete(perform: deleteCustomers)
                }
            }
            .modifier(CustomerListChrome(showsMonogram: false))
            .toolbar { customerToolbar }
            .sheet(isPresented: $showingAddSheet) { CustomerFormScreen().glAppearance(colorScheme) }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        } detail: {
            NavigationStack {
                if let selectedCustomer {
                    CustomerDetailScreen(customer: selectedCustomer)
                } else {
                    ContentUnavailableView("Select a Customer", systemImage: "person.crop.circle")
                        .containerBackground(for: .navigation) { PrimaryBackground() }
                }
            }
        }
        .onAppear { selectFirstOnIPad() }
        .onChange(of: customers.map(\.persistentModelID)) { _, _ in selectFirstOnIPad() }
    }

    // MARK: - Shared pieces

    @ToolbarContentBuilder
    private var customerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingMenu = true
            } label: {
                MenuButtonLabel()
            }
            .accessibilityLabel("Menu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Customer")
        }
    }

    /// iPhone toolbar: adds the multi-select Edit mode (Done / Delete) the iPad split omits.
    @ToolbarContentBuilder
    private var customerStackToolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { toggleEditing() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Text(selection.isEmpty ? "Delete" : "Delete (\(selection.count))")
                }
                .tint(.red)
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingMenu = true
                } label: {
                    MenuButtonLabel()
                }
                .accessibilityLabel("Menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if customers.isEmpty {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Customer")
                } else {
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
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Customers", systemImage: "person.2")
        } description: {
            Text("Tap + to add your first customer.")
        }
        .listRowBackground(Color.clear)
    }

    /// `selectionMark` is nil outside multi-select; in it, true/false draws a filled/empty checkmark.
    private func customerRow(_ customer: Customer, isSelected: Bool, showsChevron: Bool,
                             selectionMark: Bool? = nil) -> some View {
        HStack(spacing: 12) {
            if let selectionMark {
                Image(systemName: selectionMark ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionMark ? gold : Color.secondary)
            }
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(customer.listDisplayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, GLLayout.rowContentVerticalPadding)
                .padding(.leading, 74)
                .padding(.trailing, GLLayout.rowContentPadding)
                .frame(maxWidth: .infinity)
                .glCardBackground()
                .glSelectionStroke(isSelected)

                CustomerAvatar(customer: customer, size: 60)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }

    private func selectFirstOnIPad() {
        guard sizeClass == .regular, selectedCustomer == nil else { return }
        selectedCustomerID = customers.first?.persistentModelID
    }

    private func deleteCustomers(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(customers[index])
        }
    }

    private func toggleSelection(_ customer: Customer) {
        let id = customer.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
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

/// Shared list styling for both the iPhone stack and the iPad sidebar.
/// `showsMonogram` keeps the brand-monogram backdrop for the iPhone push view; the iPad split
/// sidebar opts out (passes `false`) so the GL monogram only appears once on screen — on the
/// right-hand detail pane.
private struct CustomerListChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var showsMonogram: Bool = true

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .containerBackground(for: .navigation) {
                if showsMonogram {
                    PrimaryBackground()
                } else {
                    GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
                }
            }
            .navigationTitle("Customers")
    }
}

#Preview {
    CustomersScreen()
        .modelContainer(for: Customer.self, inMemory: true)
}
