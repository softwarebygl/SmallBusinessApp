//
//  InvoiceFromContractSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  Dedicated "Invoice from Contract" sheet with 3 options:
//  1. Full Balance (100%)
//  2. Percentage of Contract (preset pills: 25%, 33%, 50% + slider)
//  3. Choose Specific Line Items (checkbox picker for contract items & change orders)
//  (Ruling 2).
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct InvoiceFromContractSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @Query private var customers: [Customer]

    @AppStorage("gl.invoice.defaultAutoRemindersEnabled") private var defaultAutoReminders = false
    @AppStorage("gl.invoice.defaultReminderStartTrigger") private var defaultStartTrigger = ReminderStartTrigger.oneWeekBeforeDue.rawValue
    @AppStorage("gl.invoice.defaultReminderFrequency") private var defaultFrequency = ReminderFrequency.weekly.rawValue

    let contract: Contract
    var onCreated: ((Invoice) -> Void)? = nil

    enum InvoicingOption: String, CaseIterable, Identifiable {
        case fullBalance
        case percentage
        case specificLineItems

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fullBalance: mbLoc("Full Balance (100%)")
            case .percentage: mbLoc("Percentage of Contract")
            case .specificLineItems: mbLoc("Choose Specific Items")
            }
        }
    }

    @State private var selectedOption: InvoicingOption = .fullBalance
    @State private var percentage: Double = 50.0
    @State private var selectedItemIDs: Set<PersistentIdentifier> = []
    @State private var isCreating = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?

    struct SelectableContractItem: Identifiable {
        let id: PersistentIdentifier
        let name: String
        let details: String
        let quantity: Double
        let unit: UnitOfMeasure
        let unitPrice: Double
        let total: Double
        let kind: LineItemKind
        let isTaxable: Bool
        let fromChangeOrder: Bool
        let groupTitle: String
    }

    private var availableLineItems: [SelectableContractItem] {
        var items: [SelectableContractItem] = []
        for group in contract.sortedGroups {
            for item in group.sortedLineItems {
                items.append(SelectableContractItem(
                    id: item.persistentModelID,
                    name: item.name,
                    details: item.details,
                    quantity: item.quantity,
                    unit: item.unit,
                    unitPrice: item.unitPrice,
                    total: item.total,
                    kind: item.kind,
                    isTaxable: item.isTaxable,
                    fromChangeOrder: item.fromChangeOrder,
                    groupTitle: group.name
                ))
            }
        }
        for co in contract.approvedChangeOrders {
            let coTitle = co.title.isEmpty ? co.number : "\(co.number): \(co.title)"
            for item in co.sortedLineItems {
                items.append(SelectableContractItem(
                    id: item.persistentModelID,
                    name: item.name,
                    details: item.details,
                    quantity: item.quantity,
                    unit: item.unit,
                    unitPrice: item.unitPrice,
                    total: item.lineTotal,
                    kind: .labor,
                    isTaxable: item.isTaxable,
                    fromChangeOrder: true,
                    groupTitle: coTitle
                ))
            }
        }
        return items
    }

    private var calculatedPercentageAmount: Double {
        let base = contract.remainingToInvoice > 0 ? contract.remainingToInvoice : contract.contractedValue
        return DomainMoney.roundedToCents(base * (percentage / 100.0))
    }

    private var selectedItemsTotal: Double {
        let selected = availableLineItems.filter { selectedItemIDs.contains($0.id) }
        return DomainMoney.roundedSum(selected.map(\.total))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(contract.displayTitle)
                            .font(.headline)
                        Text(contract.number)
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        HStack {
                            Text(mbLoc("Contract Value:"))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(contract.contractedValue.formatted(.appMoney))
                                .font(.subheadline.weight(.semibold))
                        }
                        HStack {
                            Text(mbLoc("Remaining to Invoice:"))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(contract.remainingToInvoice.formatted(.appMoney))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(GLTheme.statusGood)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(mbLoc("Contract Summary"))
                }

                Section {
                    Picker(mbLoc("Invoicing Method"), selection: $selectedOption) {
                        ForEach(InvoicingOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                switch selectedOption {
                case .fullBalance:
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mbLoc("Invoice the full remaining balance"))
                                .font(.subheadline.weight(.medium))
                            HStack {
                                Text(mbLoc("Amount to Bill:"))
                                    .foregroundStyle(GLTheme.textSecondary)
                                Spacer()
                                Text((contract.remainingToInvoice > 0 ? contract.remainingToInvoice : contract.contractedValue).formatted(.appMoney))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(GLTheme.statusGood)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        HStack {
                            Text(mbLoc("Full Balance"))
                            Spacer()
                            InfoButton(text: "Generates an invoice for 100% of the remaining contract balance and all approved change orders.", topic: "Full Balance Invoice")
                        }
                    }

                case .percentage:
                    Section {
                        VStack(spacing: 14) {
                            HStack(spacing: 8) {
                                ForEach([25.0, 33.0, 50.0, 100.0], id: \.self) { pct in
                                    Button {
                                        percentage = pct
                                    } label: {
                                        Text("\(Int(pct))%")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(percentage == pct ? GLTheme.accentFill : GLTheme.surfaceRaised)
                                            .foregroundStyle(percentage == pct ? .white : GLTheme.textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            HStack {
                                Text("\(Int(percentage))%")
                                    .font(.headline)
                                    .frame(width: 50, alignment: .leading)
                                Slider(value: $percentage, in: 1...100, step: 1)
                            }

                            HStack {
                                Text(mbLoc("Invoice Amount:"))
                                    .font(.subheadline)
                                    .foregroundStyle(GLTheme.textSecondary)
                                Spacer()
                                Text(calculatedPercentageAmount.formatted(.appMoney))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(GLTheme.statusGood)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        HStack {
                            Text(mbLoc("Percentage of Contract"))
                            Spacer()
                            InfoButton(text: "Invoice a progress payment or deposit as a percentage of the total contract value.", topic: "Percentage Invoicing")
                        }
                    }

                case .specificLineItems:
                    Section {
                        if availableLineItems.isEmpty {
                            Text(mbLoc("No individual line items found on this contract. Use Full Balance or Percentage instead."))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                        } else {
                            ForEach(availableLineItems) { item in
                                Button {
                                    toggleItem(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedItemIDs.contains(item.id) ? GLTheme.accentFill : GLTheme.textTertiary)
                                            .font(.title3)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(GLTheme.textPrimary)
                                            if !item.details.isEmpty {
                                                Text(item.details)
                                                    .font(.caption)
                                                    .foregroundStyle(GLTheme.textSecondary)
                                            }
                                            HStack(spacing: 4) {
                                                Text("\(item.quantity.formatted()) \(item.unit.abbreviation) × \(item.unitPrice.formatted(.appMoney))")
                                                    .font(.caption2)
                                                    .foregroundStyle(GLTheme.textTertiary)
                                                Text("• \(item.groupTitle)")
                                                    .font(.caption2)
                                                    .foregroundStyle(GLTheme.textSecondary)
                                                if item.fromChangeOrder {
                                                    Text("• \(mbLoc("Change Order"))")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(GLTheme.accentFill)
                                                }
                                            }
                                        }
                                        Spacer()
                                        Text(item.total.formatted(.appMoney))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(GLTheme.textPrimary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            HStack {
                                Text(mbLoc("Selected Total:"))
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(selectedItemsTotal.formatted(.appMoney))
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(GLTheme.statusGood)
                            }
                            .padding(.top, 4)
                        }
                    } header: {
                        HStack {
                            Text(mbLoc("Select Line Items"))
                            Spacer()
                            if !availableLineItems.isEmpty {
                                Button(selectedItemIDs.count == availableLineItems.count ? mbLoc("Deselect All") : mbLoc("Select All")) {
                                    if selectedItemIDs.count == availableLineItems.count {
                                        selectedItemIDs.removeAll()
                                    } else {
                                        selectedItemIDs = Set(availableLineItems.map(\.id))
                                    }
                                }
                                .font(.caption)
                            }
                            InfoButton(text: "Pick the exact line items you want to invoice for this billing cycle.", topic: "Line Item Invoicing")
                        }
                    }
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(mbLoc("Invoice from Contract")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Invoice from Contract"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mbLoc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mbLoc("Create Invoice")) {
                        generateInvoice()
                    }
                    .disabled(isCreateDisabled)
                }
            }
            .onAppear {
                // Pre-select all line items by default for convenience
                if selectedItemIDs.isEmpty {
                    selectedItemIDs = Set(availableLineItems.map(\.id))
                }
            }
            .alert(mbLoc("Error Creating Invoice"), isPresented: $showingError) {
                Button(mbLoc("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var isCreateDisabled: Bool {
        if isCreating { return true }
        switch selectedOption {
        case .fullBalance:
            return false
        case .percentage:
            return calculatedPercentageAmount <= 0
        case .specificLineItems:
            return availableLineItems.isEmpty || selectedItemIDs.isEmpty
        }
    }

    private func toggleItem(_ item: SelectableContractItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func generateInvoice() {
        guard !isCreating else { return }
        guard ReadOnlyGate.allows(.saveInvoice, into: $readOnlyRefusal) else { return }
        isCreating = true

        let targetCustomer: Customer
        if let live = contract.customer {
            targetCustomer = live
        } else if let match = customers.first(where: { $0.listDisplayName == contract.customerName || (!contract.customerEmail.isEmpty && $0.email == contract.customerEmail) }) {
            targetCustomer = match
            contract.customer = match
        } else {
            // Create a customer placeholder if none exists
            let newCust = Customer(firstName: contract.customerName, email: contract.customerEmail,
                                   phoneNumber: contract.customerPhone, serviceAddress: contract.serviceAddress)
            modelContext.insert(newCust)
            targetCustomer = newCust
            contract.customer = newCust
        }

        var draft = InvoiceDraft()
        draft.jobTitle = contract.displayTitle
        draft.serviceAddress = contract.serviceAddress
        draft.customerNotes = contract.notes
        draft.terms = contract.terms

        // Reminder settings pre-fill
        draft.groups = []

        switch selectedOption {
        case .fullBalance:
            if contract.allLineItems.isEmpty && contract.approvedChangeOrders.isEmpty {
                let amount = contract.remainingToInvoice > 0 ? contract.remainingToInvoice : contract.contractedValue
                var line = InvoiceLineDraft()
                line.name = contract.displayTitle
                line.quantity = 1.0
                line.unit = .job
                line.unitPrice = amount
                draft.groups = [InvoiceGroupDraft(name: mbLoc("Contract Balance"), note: contract.number, lines: [line])]
            } else {
                for group in contract.sortedGroups {
                    let lines = group.sortedLineItems.map { item -> InvoiceLineDraft in
                        var line = InvoiceLineDraft()
                        line.name = item.name
                        line.details = item.details
                        line.quantity = item.quantity
                        line.unit = item.unit
                        line.unitPrice = item.unitPrice
                        line.kind = item.kind
                        line.isTaxable = item.isTaxable
                        line.fromChangeOrder = item.fromChangeOrder
                        return line
                    }
                    draft.groups.append(InvoiceGroupDraft(name: group.name, note: group.note, lines: lines))
                }
                for co in contract.approvedChangeOrders {
                    let coTitle = co.title.isEmpty ? co.number : "\(co.number): \(co.title)"
                    let lines = co.sortedLineItems.map { item -> InvoiceLineDraft in
                        var line = InvoiceLineDraft()
                        line.name = item.name
                        line.details = item.details
                        line.quantity = item.quantity
                        line.unit = item.unit
                        line.unitPrice = item.unitPrice
                        line.kind = .labor
                        line.isTaxable = item.isTaxable
                        line.fromChangeOrder = true
                        return line
                    }
                    draft.groups.append(InvoiceGroupDraft(name: coTitle, note: mbLoc("Change Order"), lines: lines))
                }
            }

        case .percentage:
            let pct = Int(percentage)
            var line = InvoiceLineDraft()
            line.name = "\(pct)% \(mbLoc("Progress Billing")) - \(contract.displayTitle)"
            line.details = "\(mbLoc("Payment for")) \(pct)% \(mbLoc("of contract")) \(contract.number)"
            line.quantity = 1.0
            line.unit = .job
            line.unitPrice = calculatedPercentageAmount
            draft.amountDueNow = calculatedPercentageAmount
            draft.amountDueDetail = "\(pct)% \(mbLoc("Progress Payment"))"
            draft.groups = [InvoiceGroupDraft(name: mbLoc("Progress Payment"), note: "\(pct)% \(mbLoc("Billing"))", lines: [line])]

        case .specificLineItems:
            let selectedItems = availableLineItems.filter { selectedItemIDs.contains($0.id) }
            var groupsDict: [String: [InvoiceLineDraft]] = [:]
            var groupOrder: [String] = []
            for item in selectedItems {
                var line = InvoiceLineDraft()
                line.name = item.name
                line.details = item.details
                line.quantity = item.quantity
                line.unit = item.unit
                line.unitPrice = item.unitPrice
                line.kind = item.kind
                line.isTaxable = item.isTaxable
                line.fromChangeOrder = item.fromChangeOrder
                if groupsDict[item.groupTitle] == nil {
                    groupOrder.append(item.groupTitle)
                    groupsDict[item.groupTitle] = []
                }
                groupsDict[item.groupTitle]?.append(line)
            }
            for groupTitle in groupOrder {
                if let lines = groupsDict[groupTitle] {
                    draft.groups.append(InvoiceGroupDraft(name: groupTitle, lines: lines))
                }
            }
        }

        do {
            let invoice = try InvoiceService.create(
                draft,
                for: targetCustomer,
                contract: contract,
                origin: .screen,
                in: modelContext,
                subscription: subscription
            )
            // Pre-seed reminder settings from defaults
            invoice.autoRemindersEnabled = defaultAutoReminders
            invoice.reminderStartTriggerRaw = defaultStartTrigger
            invoice.reminderFrequencyRaw = defaultFrequency
            modelContext.saveChanges()

            dismiss()
            onCreated?(invoice)
        } catch {
            isCreating = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
