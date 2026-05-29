//
//  InvoiceFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import SwiftData

private struct InvoiceLineItemDraft: Identifiable {
    let id = UUID()
    var name = ""
    var details = ""
    var quantity = 1.0
    var unit: UnitOfMeasure = .squareFoot
    var unitPrice = 0.0
    var kind: LineItemKind = .labor
    var isTaxable = false

    init() {}

    init(from item: InvoiceLineItem) {
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

private struct InvoiceGroupDraft: Identifiable {
    let id = UUID()
    var name = ""
    var note = ""
    var lines: [InvoiceLineItemDraft]

    init() {
        lines = [InvoiceLineItemDraft()]
    }

    init(from group: InvoiceGroup) {
        name = group.name
        note = group.note
        lines = group.sortedLineItems.map { InvoiceLineItemDraft(from: $0) }
        if lines.isEmpty { lines = [InvoiceLineItemDraft()] }
    }

    var subtotal: Double { lines.reduce(0) { $0 + $1.lineTotal } }
}

struct InvoiceFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var allInvoices: [Invoice]
    @Query private var allInvoiceGroups: [InvoiceGroup]
    @Query private var allInvoiceLineItems: [InvoiceLineItem]
    @Query private var allEstimateGroups: [EstimateGroup]
    @Query private var allEstimateLineItems: [EstimateLineItem]

    @FocusState private var focusedField: SuggestionField?

    private enum SuggestionField: Hashable {
        case groupName(UUID)
        case lineName(UUID)
    }

    private let editingInvoice: Invoice?
    private let customer: Customer?
    private let createdAt: Date

    @State private var jobTitle: String
    @State private var status: InvoiceStatus
    @State private var paymentTerms: PaymentTerms
    @State private var dueDate: Date
    @State private var taxRatePercent: Double
    @State private var discountType: AdjustmentType
    @State private var discountValue: Double
    @State private var customerNotes: String
    @State private var terms: String
    @State private var amountDueNow: Double
    @State private var amountDueDetail: String
    @State private var groups: [InvoiceGroupDraft]

    init(customer: Customer) {
        self.customer = customer
        self.editingInvoice = nil
        let now = Date.now
        self.createdAt = now
        _jobTitle = State(initialValue: "")
        _status = State(initialValue: .draft)
        _paymentTerms = State(initialValue: .net30)
        _dueDate = State(initialValue: PaymentTerms.net30.dueDate(from: now) ?? now)
        _taxRatePercent = State(initialValue: 0)
        _discountType = State(initialValue: .none)
        _discountValue = State(initialValue: 0)
        _customerNotes = State(initialValue: "")
        _terms = State(initialValue: "")
        _amountDueNow = State(initialValue: 0)
        _amountDueDetail = State(initialValue: "")
        _groups = State(initialValue: [InvoiceGroupDraft()])
    }

    init(editing invoice: Invoice) {
        self.customer = invoice.customer
        self.editingInvoice = invoice
        self.createdAt = invoice.createdAt
        _jobTitle = State(initialValue: invoice.jobTitle)
        _status = State(initialValue: invoice.status)
        _paymentTerms = State(initialValue: invoice.paymentTerms)
        _dueDate = State(initialValue: invoice.dueDate)
        _taxRatePercent = State(initialValue: invoice.taxRatePercent)
        _discountType = State(initialValue: invoice.discountType)
        _discountValue = State(initialValue: invoice.discountValue)
        _customerNotes = State(initialValue: invoice.customerNotes)
        _terms = State(initialValue: invoice.terms)
        _amountDueNow = State(initialValue: invoice.amountDueNow)
        _amountDueDetail = State(initialValue: invoice.amountDueDetail)
        let drafts = invoice.sortedGroups.map { InvoiceGroupDraft(from: $0) }
        _groups = State(initialValue: drafts.isEmpty ? [InvoiceGroupDraft()] : drafts)
    }

    private var totals: EstimateTotals {
        EstimateTotals(
            lines: groups.flatMap(\.lines).map { ($0.lineTotal, $0.isTaxable) },
            taxRatePercent: taxRatePercent,
            discountType: discountType,
            discountValue: discountValue,
            depositType: .none,
            depositValue: 0
        )
    }

    private var canSave: Bool {
        !jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invoice") {
                    TextField("Job title", text: $jobTitle)
                    Picker("Status", selection: $status) {
                        ForEach(InvoiceStatus.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Terms", selection: $paymentTerms) {
                        ForEach(PaymentTerms.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: paymentTerms) { _, newTerms in
                        if let computed = newTerms.dueDate(from: createdAt) {
                            dueDate = computed
                        }
                    }
                    if paymentTerms == .custom {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    } else {
                        LabeledContent("Due date", value: dueDate.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                ForEach($groups) { $group in
                    groupSection($group)
                }

                Section {
                    Button {
                        groups.append(InvoiceGroupDraft())
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

                Section {
                    LabeledContent("Amount due now") {
                        AutoClearNumberField(placeholder: "0", value: $amountDueNow, style: .currency, clearsAt: 0)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("What it's for (e.g. Deposit to start)", text: $amountDueDetail)
                } header: {
                    Text("Amount due now")
                } footer: {
                    Text("Bill a deposit or milestone now. Leave at $0 to request the full balance.")
                        .textCase(nil)
                }

                Section("Notes") {
                    TextField("Notes for the customer", text: $customerNotes, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Terms & conditions", text: $terms, axis: .vertical)
                        .lineLimit(2...6)
                }

                summarySection
            }
            .glFormBackground()
            .navigationTitle(editingInvoice == nil ? "New Invoice" : "Edit Invoice")
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

    private func groupSection(_ group: Binding<InvoiceGroupDraft>) -> some View {
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
                group.lines.wrappedValue.append(InvoiceLineItemDraft())
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

    private func lineEditor(_ line: Binding<InvoiceLineItemDraft>) -> some View {
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
        nameCounts(allInvoiceGroups.map(\.name) + allEstimateGroups.map(\.name))
    }

    private var lineNameCounts: [String: Int] {
        nameCounts(allInvoiceLineItems.map(\.name) + allEstimateLineItems.map(\.name))
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
        let invoice: Invoice
        if let editingInvoice {
            invoice = editingInvoice
            for group in invoice.groups ?? [] {
                modelContext.delete(group)
            }
            invoice.groups = []
        } else {
            invoice = Invoice(customer: customer)
            invoice.number = Invoice.nextNumber(after: allInvoices)
            modelContext.insert(invoice)
        }

        invoice.jobTitle = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        invoice.status = status
        invoice.paymentTerms = paymentTerms
        invoice.dueDate = (paymentTerms == .custom) ? dueDate : (paymentTerms.dueDate(from: invoice.createdAt) ?? dueDate)
        invoice.taxRatePercent = taxRatePercent
        invoice.discountType = discountType
        invoice.discountValue = discountValue
        invoice.customerNotes = customerNotes
        invoice.terms = terms
        invoice.amountDueNow = amountDueNow
        invoice.amountDueDetail = amountDueDetail.trimmingCharacters(in: .whitespacesAndNewlines)

        var groupIndex = 0
        for groupDraft in groups {
            let keptLines = groupDraft.lines.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let trimmedName = groupDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if keptLines.isEmpty && trimmedName.isEmpty { continue }

            let group = InvoiceGroup(
                name: trimmedName,
                note: groupDraft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                sortIndex: groupIndex
            )
            group.invoice = invoice
            modelContext.insert(group)
            groupIndex += 1

            for (index, draft) in keptLines.enumerated() {
                let item = InvoiceLineItem(
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
    InvoiceFormScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
        .modelContainer(for: [Customer.self, Invoice.self], inMemory: true)
}
