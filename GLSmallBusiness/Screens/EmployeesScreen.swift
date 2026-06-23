//
//  EmployeesScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Employees tab (iPhone / compact). A payday-summary header sits above the list so the next
//  paycheck and what's owed are the first thing you see; each row shows pay rate and the amount
//  currently accrued. iPad drives the same list/detail through IPadRootSplitView. The toolbar's
//  Year-End Report shares the accountant handoff (wage summary + paycheck ledger CSVs).
//

import SwiftUI
import SwiftData

struct EmployeesScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Employee.lastName), SortDescriptor(\Employee.firstName)])
    private var employees: [Employee]
    @Query private var businessProfiles: [BusinessProfile]

    @State private var showingAdd = false
    @State private var showingMenu = false
    @State private var path: [Employee] = []
    @State private var exportFiles: [URL] = []

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if employees.isEmpty {
                    emptyState
                } else {
                    if let summary = PayrollSummary.nextPayday(for: employees) { paydayHeader(summary) }
                    Section("Team") {
                        ForEach(employees) { employee in
                            Button { path.append(employee) } label: { row(employee) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .contentMargins(.top, 10, for: .scrollContent)   // breathing room below the script title's descenders
            .containerBackground(for: .navigation) { PrimaryBackground() }
            .navigationTitle("Employees")
            .navigationDestination(for: Employee.self) { EmployeeDetailScreen(employee: $0) }
            .toolbar { toolbar }
            .sheet(isPresented: $showingAdd) {
                EmployeeFormScreen { saved in path.append(saved) }.glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .onAppear { regenerateExport() }
            .onChange(of: employees.map(\.persistentModelID)) { _, _ in regenerateExport() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingMenu = true } label: { MenuButtonLabel() }
                .accessibilityLabel("Menu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingAdd = true } label: { Label("New employee", systemImage: "plus") }
                if !exportFiles.isEmpty {
                    ShareLink(items: exportFiles) {
                        Label("Year-End Report", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: - Payday summary header

    private func paydayHeader(_ summary: PayrollSummary.NextPayday) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT PAYDAY")
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(summary.date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.title3.weight(.semibold))
            Text("\(summary.total.formatted(.currency(code: "USD"))) due to \(summary.count) \(summary.count == 1 ? "employee" : "employees")")
                .font(.subheadline).foregroundStyle(gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.top, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Row

    private func row(_ employee: Employee) -> some View {
        PersonRowCard(
            name: employee.listDisplayName,
            subtitle: paySummary(employee),
            trailing: employee.accruedGross > 0.005 ? employee.accruedGross.formatted(.currency(code: "USD")) : "",
            trailingTint: gold
        ) {
            MonogramAvatar(initials: employee.initials)
        }
    }

    private func paySummary(_ employee: Employee) -> String {
        let rate = employee.payType == .hourly
            ? "\(employee.hourlyRate.formatted(.currency(code: "USD")))/hr"
            : "\(employee.annualSalary.formatted(.currency(code: "USD")))/yr"
        return "\(rate) · \(employee.payFrequency.label)"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Employees", systemImage: "person.text.rectangle")
        } description: {
            Text("Tap + to add your first employee.")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(employees[index]) }
        try? modelContext.save()
    }

    private func regenerateExport() {
        exportFiles = EmployeePayExport.files(
            employees: employees,
            year: Calendar.current.component(.year, from: .now),
            business: businessProfiles.first
        )
    }
}

#Preview {
    EmployeesScreen()
        .modelContainer(for: Employee.self, inMemory: true)
}
