//
//  EstimateFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

private struct LineItemDraft: Identifiable {
    let id = UUID()
    var name = ""
    var details = ""
    var quantity = 1.0
    var unit: UnitOfMeasure = .squareFoot
    var unitPrice = 0.0
    var kind: LineItemKind = .labor
    var isTaxable = false

    init() {}

    init(from item: EstimateLineItem) {
        name = item.name
        details = item.details
        quantity = item.quantity
        unit = item.unit
        unitPrice = item.unitPrice
        kind = item.kind
        isTaxable = item.isTaxable
    }

    var lineTotal: Double { quantity * unitPrice }
}

private struct GroupDraft: Identifiable {
    let id = UUID()
    var name = ""
    var note = ""
    var lines: [LineItemDraft]

    init() {
        lines = [LineItemDraft()]
    }

    init(from group: EstimateGroup) {
        name = group.name
        note = group.note
        lines = group.sortedLineItems.map { LineItemDraft(from: $0) }
        if lines.isEmpty { lines = [LineItemDraft()] }
    }

    var subtotal: Double { lines.reduce(0) { $0 + $1.lineTotal } }
}

struct EstimateFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var allEstimates: [Estimate]
    @Query private var allGroups: [EstimateGroup]
    @Query private var allLineItems: [EstimateLineItem]

    @FocusState private var focusedField: SuggestionField?

    private enum SuggestionField: Hashable {
        case groupName(UUID)
        case lineName(UUID)
    }

    private let editingEstimate: Estimate?
    private let customer: Customer?

    @State private var jobTitle: String
    @State private var status: EstimateStatus
    @State private var validUntil: Date
    @State private var taxRatePercent: Double
    @State private var discountType: AdjustmentType
    @State private var discountValue: Double
    @State private var depositType: AdjustmentType
    @State private var depositValue: Double
    @State private var customerNotes: String
    @State private var terms: String
    @State private var groups: [GroupDraft]

    init(customer: Customer) {
        self.customer = customer
        self.editingEstimate = nil
        _jobTitle = State(initialValue: "")
        _status = State(initialValue: .draft)
        _validUntil = State(initialValue: Date.now.addingTimeInterval(30 * 24 * 60 * 60))
        _taxRatePercent = State(initialValue: 0)
        _discountType = State(initialValue: .none)
        _discountValue = State(initialValue: 0)
        _depositType = State(initialValue: .none)
        _depositValue = State(initialValue: 0)
        _customerNotes = State(initialValue: "")
        _terms = State(initialValue: "")
        _groups = State(initialValue: [GroupDraft()])
    }

    init(editing estimate: Estimate) {
        self.customer = estimate.customer
        self.editingEstimate = estimate
        _jobTitle = State(initialValue: estimate.jobTitle)
        _status = State(initialValue: estimate.status)
        _validUntil = State(initialValue: estimate.validUntil)
        _taxRatePercent = State(initialValue: estimate.taxRatePercent)
        _discountType = State(initialValue: estimate.discountType)
        _discountValue = State(initialValue: estimate.discountValue)
        _depositType = State(initialValue: estimate.depositType)
        _depositValue = State(initialValue: estimate.depositValue)
        _customerNotes = State(initialValue: estimate.customerNotes)
        _terms = State(initialValue: estimate.terms)
        let drafts = estimate.sortedGroups.map { GroupDraft(from: $0) }
        _groups = State(initialValue: drafts.isEmpty ? [GroupDraft()] : drafts)
    }

    private var totals: EstimateTotals {
        EstimateTotals(
            lines: groups.flatMap(\.lines).map { ($0.lineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: discountType,
            discountValue: discountValue,
            depositType: depositType,
            depositValue: depositValue
        )
    }

    private var canSave: Bool {
        !jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Job title", text: $jobTitle)
                    Picker("Status", selection: $status) {
                        ForEach(EstimateStatus.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("Valid until", selection: $validUntil, displayedComponents: .date)
                }

                ForEach($groups) { $group in
                    groupSection($group)
                }

                Section {
                    Button {
                        groups.append(GroupDraft())
                    } label: {
                        Label("Add group", systemImage: "plus.square.on.square")
                    }
                }

                Section("Tax") {
                    LabeledContent("Tax rate (%)") {
                        AutoClearNumberField(placeholder: "0", value: $taxRatePercent, style: .number, clearsAt: 0)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Applied only to line items marked taxable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                adjustmentSection(title: "Discount", type: $discountType, value: $discountValue)
                adjustmentSection(title: "Deposit", type: $depositType, value: $depositValue)

                Section("Notes") {
                    TextField("Notes for the customer", text: $customerNotes, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Terms & conditions", text: $terms, axis: .vertical)
                        .lineLimit(2...6)
                }

                summarySection
            }
            .glFormBackground()
            .navigationTitle(editingEstimate == nil ? "New Estimate" : "Edit Estimate")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
    }

    private func groupSection(_ group: Binding<GroupDraft>) -> some View {
        Section {
            nameField(
                group.name,
                placeholder: "Group name (e.g. Master Shower)",
                field: .groupName(group.wrappedValue.id),
                counts: groupNameCounts
            )
            TextField("Note (e.g. 5×3×8)", text: group.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(group.lines) { $line in
                lineEditor($line)
            }
            .onDelete { group.lines.wrappedValue.remove(atOffsets: $0) }

            Button {
                group.lines.wrappedValue.append(LineItemDraft())
            } label: {
                Label("Add line item", systemImage: "plus.circle.fill")
            }

            HStack {
                Spacer()
                Text("Group subtotal: \(group.wrappedValue.subtotal.formatted(.currency(code: "USD")))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if groups.count > 1 {
                Button(role: .destructive) {
                    groups.removeAll { $0.id == group.wrappedValue.id }
                } label: {
                    Label("Remove group", systemImage: "trash")
                }
            }
        } header: {
            Text(group.wrappedValue.name.isEmpty ? "Group" : group.wrappedValue.name)
        }
    }

    private func lineEditor(_ line: Binding<LineItemDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameField(
                line.name,
                placeholder: "Item name",
                field: .lineName(line.wrappedValue.id),
                counts: lineNameCounts
            )
            TextField("Description (optional)", text: line.details)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                AutoClearNumberField(placeholder: "Qty", value: line.quantity, style: .number, clearsAt: 1)
                    .frame(maxWidth: 70)
                Picker("Unit", selection: line.unit) {
                    ForEach(UnitOfMeasure.allCases) { Text($0.abbreviation).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Text("×").foregroundStyle(.secondary)
                AutoClearNumberField(placeholder: "Price", value: line.unitPrice, style: .currency, clearsAt: 0)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }

            Picker("Type", selection: line.kind) {
                ForEach(LineItemKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: line.kind.wrappedValue) { _, newKind in
                line.isTaxable.wrappedValue = newKind.defaultTaxable
            }

            Toggle("Taxable", isOn: line.isTaxable)

            HStack {
                Spacer()
                Text("Line total: \(line.wrappedValue.lineTotal.formatted(.currency(code: "USD")))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Name fields with type-ahead suggestions

    private var groupNameCounts: [String: Int] {
        nameCounts(allGroups.map(\.name))
    }

    private var lineNameCounts: [String: Int] {
        nameCounts(allLineItems.map(\.name))
    }

    private func nameCounts(_ names: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { counts[name, default: 0] += 1 }
        }
        return counts
    }

    private func suggestions(matching text: String, counts: [String: Int]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        return counts.keys
            .filter { $0.lowercased().contains(lower) && $0.lowercased() != lower }
            .sorted { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
            }
            .prefix(4)
            .map { $0 }
    }

    @ViewBuilder
    private func nameField(_ text: Binding<String>, placeholder: String, field: SuggestionField, counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: text)
                .font(.headline)
                .focused($focusedField, equals: field)

            if focusedField == field {
                ForEach(suggestions(matching: text.wrappedValue, counts: counts), id: \.self) { name in
                    Button {
                        text.wrappedValue = name
                        focusedField = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .padding(.top, 10)
                }
            }
        }
    }

    private func adjustmentSection(title: String, type: Binding<AdjustmentType>, value: Binding<Double>) -> some View {
        Section(title) {
            Picker(title, selection: type) {
                ForEach(AdjustmentType.allCases) { Text($0.label).tag($0) }
            }
            if type.wrappedValue != .none {
                LabeledContent(type.wrappedValue == .percentage ? "\(title) (%)" : "\(title) amount") {
                    AutoClearNumberField(placeholder: "0", value: value, style: .number, clearsAt: 0)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            summaryRow("Subtotal", totals.subtotal)
            if totals.discount > 0 { summaryRow("Discount", -totals.discount) }
            if totals.tax > 0 { summaryRow("Tax", totals.tax) }
            summaryRow("Total", totals.total, bold: true)
            if totals.deposit > 0 { summaryRow("Deposit due", totals.deposit) }
        }
    }

    private func summaryRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.currency(code: "USD")))
        }
        .fontWeight(bold ? .bold : .regular)
    }

    private func save() {
        let estimate: Estimate
        if let editingEstimate {
            estimate = editingEstimate
            for group in estimate.groups ?? [] {
                modelContext.delete(group)
            }
            estimate.groups = []
        } else {
            estimate = Estimate(customer: customer)
            estimate.number = Estimate.nextNumber(after: allEstimates)
            modelContext.insert(estimate)
        }

        estimate.jobTitle = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        estimate.status = status
        estimate.validUntil = validUntil
        estimate.taxRatePercent = taxRatePercent
        estimate.discountType = discountType
        estimate.discountValue = discountValue
        estimate.depositType = depositType
        estimate.depositValue = depositValue
        estimate.customerNotes = customerNotes
        estimate.terms = terms

        var groupIndex = 0
        for groupDraft in groups {
            let keptLines = groupDraft.lines.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let trimmedName = groupDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if keptLines.isEmpty && trimmedName.isEmpty { continue }

            let group = EstimateGroup(
                name: trimmedName,
                note: groupDraft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                sortIndex: groupIndex
            )
            group.estimate = estimate
            modelContext.insert(group)
            groupIndex += 1

            for (index, draft) in keptLines.enumerated() {
                let item = EstimateLineItem(
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    details: draft.details.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: draft.quantity,
                    unit: draft.unit,
                    unitPrice: draft.unitPrice,
                    kind: draft.kind,
                    isTaxable: draft.isTaxable,
                    sortIndex: index
                )
                item.group = group
                modelContext.insert(item)
            }
        }

        dismiss()
    }
}

#Preview {
    EstimateFormScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
        .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}
