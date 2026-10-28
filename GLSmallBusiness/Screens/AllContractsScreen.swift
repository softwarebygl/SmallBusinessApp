//
//  AllContractsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  A global list of every contract across all customers. Replaces AllJobsScreen
//  as the Contracts tab root (with the Calendar one tap away in the toolbar)
//  and the iPad split's content column.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct AllContractsScreen: View {
    var isTabRoot: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: \Contract.startDate, order: .reverse) private var contracts: [Contract]

    @State private var selectedContract: Contract?
    @State private var pendingDelete: [Contract]?
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?
    @State private var searchText = ""
    @State private var isSearchPresented = false

    // Tab-root chrome state
    @State private var showingMenu = false
    @State private var showingCalendar = false
    @State private var showingNewContract = false
    @State private var showingNewEstimate = false
    @State private var showingNewInvoice = false
    @State private var showingScanReceipt = false
    @State private var showingPaywall = false
    #if DEBUG
    @State private var didDemoPush = false
    #endif

    private var visibleContracts: [Contract] {
        guard !searchText.isEmpty else { return contracts }
        return contracts.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        if isTabRoot {
            NavigationStack { content.glMinimalBackButtons() }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if contracts.isEmpty {
                ContentUnavailableView {
                    Label(mbLoc("No contracts"), systemImage: "doc.text.fill")
                } description: {
                    Text(mbLoc("Contracts across all your customers will appear here."))
                }
                .listRowBackground(Color.clear)
            } else {
                if !isTabRoot {
                    GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search contracts")).asPlainListRow
                }
                ForEach(visibleContracts) { contract in
                    Button {
                        selectedContract = contract
                    } label: {
                        ContractRow(contract: contract, showsCustomer: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .confirmFirstDeleteSwipe { pendingDelete = [contract] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this contract?") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .dismissesKeyboardOnInteraction()
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(mbLoc("Contracts")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Contracts"))), for: .scrollContent)
        .navigationDestination(item: $selectedContract) { contract in
            ContractDetailScreen(contract: contract)
        }
        .modifier(ContractsTabRootChrome(
            isTabRoot: isTabRoot,
            showingMenu: $showingMenu,
            showingCalendar: $showingCalendar,
            searchText: $searchText,
            isSearchPresented: $isSearchPresented,
            showingNewContract: $showingNewContract,
            showingNewEstimate: $showingNewEstimate,
            showingNewInvoice: $showingNewInvoice,
            showingScanReceipt: $showingScanReceipt,
            showingPaywall: $showingPaywall,
            newContract: { showingNewContract = true },
            newEstimate: { showingNewEstimate = true },
            newInvoice: { showingNewInvoice = true },
            colorScheme: colorScheme
        ))
        #if DEBUG
        .onAppear {
            if isTabRoot, DemoMode.isActive, (DemoMode.screen == "calendar_pushed" || DemoMode.screen == "calendar"), DemoMode.screen != "contracts", !didDemoPush {
                didDemoPush = true
                showingCalendar = true
            }
        }
        #endif
    }

    private func delete(_ items: [Contract]) {
        guard ReadOnlyGate.allows(.deleteJob, into: $readOnlyRefusal) else { return }
        for contract in items {
            if let job = contract.scheduledJob {
                _ = try? DeletionService.delete([.job(job)], origin: .screen, in: modelContext)
            }
            modelContext.delete(contract) // GLSYNC-LINT-OK: local model until manifest v2
        }
        modelContext.saveChanges()
    }
}

// MARK: - Contracts Tab Root Chrome

private struct ContractsTabRootChrome: ViewModifier {
    let isTabRoot: Bool
    @Binding var showingMenu: Bool
    @Binding var showingCalendar: Bool
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    @Binding var showingNewContract: Bool
    @Binding var showingNewEstimate: Bool
    @Binding var showingNewInvoice: Bool
    @Binding var showingScanReceipt: Bool
    @Binding var showingPaywall: Bool
    let newContract: () -> Void
    let newEstimate: () -> Void
    let newInvoice: () -> Void
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if isTabRoot {
            content
                .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: mbLoc("Search contracts"))
                .onChange(of: isSearchPresented) { _, presented in
                    if !presented {
                        searchText = ""
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingMenu = true } label: { MenuButtonLabel() }
                            .accessibilityLabel("Menu")
                    }

                    if !isSearchPresented {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isSearchPresented = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(GLTheme.accent)
                            }
                            .accessibilityLabel("Search contracts")
                            .accessibilityIdentifier("magnifyingglass")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingCalendar = true } label: {
                            Image(systemName: "calendar")
                        }
                        .accessibilityLabel("Calendar")
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { newContract() } label: {
                                Label(mbLoc("New contract"), systemImage: "doc.text.fill")
                            }
                            Divider()
                            Button { newEstimate() } label: {
                                Label(mbLoc("New estimate"), systemImage: "doc.text.magnifyingglass")
                            }
                            Button { newInvoice() } label: {
                                Label(mbLoc("New invoice"), systemImage: "banknote")
                            }
                            Divider()
                            Button { showingScanReceipt = true } label: {
                                Label(mbLoc("Scan receipt"), systemImage: "doc.viewfinder")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add")
                    }
                }
                .navigationDestination(isPresented: $showingCalendar) {
                    CalendarScreen(showsMenuButton: false, ownsStack: false, primaryBackground: true)
                }
                .navigationDestination(isPresented: $showingNewContract) {
                    ContractFormScreen()
                }
                .navigationDestination(isPresented: $showingNewEstimate) {
                    PickCustomerThenScreen(title: "New estimate") { EstimateFormScreen(customer: $0) }
                }
                .navigationDestination(isPresented: $showingNewInvoice) {
                    PickCustomerThenScreen(title: "New invoice") { InvoiceFormScreen(customer: $0) }
                }
                .navigationDestination(isPresented: $showingScanReceipt) {
                    AllReceiptsScreen(autoScan: true)
                }
                .sheet(isPresented: $showingMenu) {
                    MenuScreen().glAppearance(colorScheme)
                }
                .paywallSheet(isPresented: $showingPaywall)
        } else {
            content
        }
    }
}
