//
//  ContractsListScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  The list of a customer's contracts. Mirrors EstimatesListScreen / InvoicesListScreen:
//  computed from customer.contracts, tap opens detail, "+" opens new contract form.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct ContractsListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription

    let customer: Customer

    @State private var showingNew = false
    @State private var pendingDelete: [Contract]?
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?
    @State private var selectedContract: Contract?

    private var contracts: [Contract] {
        customer.liveRows(customer.contracts).sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        LiveRecordGate(customer, title: "Contracts") {
            aliveBody
        }
    }

    @ViewBuilder
    private var aliveBody: some View {
        List {
            if contracts.isEmpty {
                ContentUnavailableView {
                    Label(mbLoc("No contracts"), systemImage: "doc.text.fill")
                } description: {
                    Text("\(mbLoc("Tap + to create a contract for")) \(customer.listDisplayName).")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(contracts) { contract in
                    Button {
                        selectedContract = contract
                    } label: {
                        ContractRow(contract: contract, showsCustomer: false)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Contract")
            }
        }
        .navigationDestination(isPresented: $showingNew) {
            ContractFormScreen(customer: customer)
        }
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

// MARK: - Contract Row & Badge

struct ContractRow: View {
    let contract: Contract
    var showsCustomer: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(contract.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GLTheme.textPrimary)
                if showsCustomer {
                    Text(contract.displayCustomerName)
                        .font(.caption)
                        .foregroundStyle(GLTheme.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(contract.number)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GLTheme.accentText)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(GLTheme.textTertiary)
                    Text(dateRange)
                        .font(.caption2)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(contract.contractedValue.formatted(.appMoney))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GLTheme.textPrimary)
                ContractStatusBadge(status: contract.status)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GLTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var dateRange: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)
        let end = Calendar.current.date(byAdding: .day, value: max(0, contract.durationDays - 1), to: contract.startDate) ?? contract.startDate
        return Calendar.current.isDate(contract.startDate, inSameDayAs: end)
            ? contract.startDate.formatted(style)
            : "\(contract.startDate.formatted(style)) – \(end.formatted(style))"
    }
}

struct ContractStatusBadge: View {
    let status: ContractStatus

    private var color: Color {
        switch status {
        case .draft: GLTheme.textSecondary
        case .signed: GLTheme.accentFill
        case .inProgress: GLTheme.statusAttention
        case .completed: GLTheme.statusGood
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
