//
//  EstimateFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI
import SwiftData

// The line and group drafts are EstimateLineDraft / EstimateGroupDraft (Services/Domain/
// DocumentDrafts.swift), shared with EstimateService and the assistant's tools.
private typealias LineItemDraft = EstimateLineDraft
private typealias GroupDraft = EstimateGroupDraft

/// Snapshot of everything the form edits, for unsaved-changes detection. Equatable so the form can
/// compare the current state against the snapshot taken when it appeared.
private struct EstimateSnapshot: Equatable {
    var jobTitle: String
    var status: EstimateStatus
    var validUntil: Date
    var taxRatePercent: Double
    var combineTotals: Bool
    var discountType: AdjustmentType
    var discountValue: Double
    var depositType: AdjustmentType
    var depositValue: Double
    var customerNotes: String
    var terms: String
    var serviceStreet: String
    var serviceStreet2: String
    var serviceCity: String
    var serviceState: String
    var servicePostal: String
    var groups: [GroupDraft]
}

struct EstimateFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PriceSheetItem.name) private var priceSheetItems: [PriceSheetItem]

    // Type-ahead suggestion counts, fetched and counted once when the form opens (only the names,
    // never a live query over every group and line item; QA F153). History doesn't change while
    // editing.
    @State private var groupNameCountsCache: [String: Int] = [:]
    @State private var lineNameCountsCache: [String: Int] = [:]

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
    @State private var combineTotals: Bool
    @State private var discountType: AdjustmentType
    @State private var discountValue: Double
    @State private var depositType: AdjustmentType
    @State private var depositValue: Double
    @State private var customerNotes: String
    @State private var terms: String
    @State private var serviceStreet: String
    @State private var serviceStreet2: String
    @State private var serviceCity: String
    @State private var serviceState: String
    @State private var servicePostal: String
    @State private var groups: [GroupDraft]
    @State private var initialSnapshot: EstimateSnapshot?
    /// The pre-save confirmation for a discount that has wiped this estimate out
    /// (ZeroingDiscountGuard.swift) — the same question the invoice form asks, minus the lock.
    @State private var showingZeroingDiscount = false
    /// Resettable double-tap guard, in place of `SaveOnceButton`. Cancel in the zeroing-discount
    /// alert keeps this form open on purpose, so Save has to stay tappable afterwards — a button
    /// that latches dead would leave the person staring at the typo they were just asked about.
    @State private var isSaving = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal EstimateService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(customer: Customer) {
        self.customer = customer
        self.editingEstimate = nil
        _jobTitle = State(initialValue: "")
        _status = State(initialValue: .draft)
        _validUntil = State(initialValue: Date.now.addingTimeInterval(30 * 24 * 60 * 60))
        _taxRatePercent = State(initialValue: 0)
        _combineTotals = State(initialValue: true)
        _discountType = State(initialValue: .none)
        _discountValue = State(initialValue: 0)
        _depositType = State(initialValue: .none)
        _depositValue = State(initialValue: 0)
        _customerNotes = State(initialValue: "")
        _terms = State(initialValue: "")
        let sAddr = customer.serviceAddress
        _serviceStreet = State(initialValue: sAddr.street1)
        _serviceStreet2 = State(initialValue: sAddr.street2 ?? "")
        _serviceCity = State(initialValue: sAddr.city)
        _serviceState = State(initialValue: sAddr.state)
        _servicePostal = State(initialValue: sAddr.postalCode)
        _groups = State(initialValue: [GroupDraft()])
    }

    init(editing estimate: Estimate) {
        self.customer = estimate.customer
        self.editingEstimate = estimate
        _jobTitle = State(initialValue: estimate.jobTitle)
        _status = State(initialValue: estimate.status)
        _validUntil = State(initialValue: estimate.validUntil)
        _taxRatePercent = State(initialValue: estimate.taxRatePercent)
        _combineTotals = State(initialValue: estimate.combineTotals)
        _discountType = State(initialValue: estimate.discountType)
        _discountValue = State(initialValue: estimate.discountValue)
        _depositType = State(initialValue: estimate.depositType)
        _depositValue = State(initialValue: estimate.depositValue)
        _customerNotes = State(initialValue: estimate.customerNotes)
        _terms = State(initialValue: estimate.terms)
        _serviceStreet = State(initialValue: estimate.serviceAddress.street1)
        _serviceStreet2 = State(initialValue: estimate.serviceAddress.street2 ?? "")
        _serviceCity = State(initialValue: estimate.serviceAddress.city)
        _serviceState = State(initialValue: estimate.serviceAddress.state)
        _servicePostal = State(initialValue: estimate.serviceAddress.postalCode)
        let drafts = estimate.sortedGroups.map { GroupDraft(from: $0) }
        _groups = State(initialValue: drafts.isEmpty ? [GroupDraft()] : drafts)
    }

    /// The form-draft twin of `Estimate.isOptionsMode`.
    private var isOptionsDraft: Bool { !combineTotals }

    private var totals: EstimateTotals {
        EstimateTotals(
            lines: groups.flatMap(\.lines).map { ($0.exactLineTotal, $0.isTaxable) },
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

    /// The estimate we're editing was deleted out from under us (e.g. its customer was deleted on
    /// another device). `save()` bails on it, so `attemptSave()` must not ask about it first.
    private var editingEstimateVanished: Bool {
        guard let editingEstimate else { return false }
        return !modelContext.stillStores(editingEstimate)
    }

    private var currentSnapshot: EstimateSnapshot {
        EstimateSnapshot(jobTitle: jobTitle, status: status, validUntil: validUntil,
                         taxRatePercent: taxRatePercent, combineTotals: combineTotals,
                         discountType: discountType, discountValue: discountValue,
                         depositType: depositType, depositValue: depositValue, customerNotes: customerNotes,
                         terms: terms, serviceStreet: serviceStreet, serviceStreet2: serviceStreet2,
                         serviceCity: serviceCity, serviceState: serviceState, servicePostal: servicePostal,
                         groups: groups)
    }
    private var isDirty: Bool { initialSnapshot.map { $0 != currentSnapshot } ?? false }

    var body: some View {
        Form {
            Section("Job") {
                TextField("Job title", text: $jobTitle)
                Picker("Status", selection: $status) {
                    ForEach(EstimateStatus.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Valid until", selection: $validUntil, displayedComponents: .date)
            }

            Section {
                GLAddressField("Street", street: $serviceStreet, city: $serviceCity, state: $serviceState, zip: $servicePostal)
                    .textContentType(.streetAddressLine1)
                TextField("Apt / Suite (optional)", text: $serviceStreet2)
                    .textContentType(.streetAddressLine2)
                TextField("City", text: $serviceCity)
                    .textContentType(.addressCity)
                TextField("State", text: $serviceState)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("ZIP", text: $servicePostal)
                    .textContentType(.postalCode)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            } header: {
                InfoLabel("Service Address", info: "The specific job site or lot this estimate is for. Optional — leave blank if it's at the customer's own address.", topic: "Service Address")
            }

            ForEach($groups) { $group in
                groupSection($group)
            }

            Section {
                Button {
                    groups.append(GroupDraft())
                } label: {
                    Label(combineTotals ? "Add group" : "Add option", systemImage: "plus.square.on.square")
                }
            }

            Section {
                Toggle("Combine into one total", isOn: $combineTotals)
                if !combineTotals {
                    Text("Off, each group is a standalone option with its own total — send choices in one PDF.")
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            } header: {
                InfoLabel("Totals", info: "On: everything adds into one total. Off: each group is its own priced option the customer can choose from.", topic: "Totals")
            }

            Section("Tax") {
                LabeledContent("Tax rate (%)") {
                    AutoClearNumberField(placeholder: "0", value: $taxRatePercent, style: .number, clearsAt: 0,
                                         maxValue: 100)   // a tax rate over 100% is a typo; the service refuses it
                        .multilineTextAlignment(.trailing)
                }
                Text("Applied only to line items marked taxable.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
            }

            // Options mode IGNORES the estimate-level discount and deposit on every
            // surface, so offering the editors was a silently-ignored input — and the
            // feeder for wrong-money conversions (QA 2026-09-01). They return the
            // moment totals combine again; the stored values are untouched.
            if !isOptionsDraft {
                adjustmentSection(title: mbLoc("Discount"), type: $discountType, value: $discountValue)
                adjustmentSection(title: mbLoc("Deposit"), type: $depositType, value: $depositValue, fixedIsAmount: true)
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
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .task { loadNameSuggestions() }
        .navigationTitle(GLScript.padded(editingEstimate == nil ? mbLoc("New Estimate") : mbLoc("Edit Estimate")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editingEstimate == nil ? mbLoc("New Estimate") : mbLoc("Edit Estimate"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { attemptSave() }.disabled(!canSave || isSaving)
            }
        }
        .onAppear { if initialSnapshot == nil { initialSnapshot = currentSnapshot } }
        .zeroingDiscountEstimateAlert(isPresented: $showingZeroingDiscount, onSave: save)
        .discardChangesGuard(isDirty: isDirty)
    }

    private func groupSection(_ group: Binding<GroupDraft>) -> some View {
        Section {
            nameField(
                group.name,
                placeholder: combineTotals ? "Group name (e.g. Master Shower)" : "Option name (e.g. Gold Package)",
                field: .groupName(group.wrappedValue.id),
                counts: groupNameCountsCache
            )
            TextField("Note (e.g. 5×3×8)", text: group.note)
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)

            ForEach(group.lines) { $line in
                lineEditor($line) {
                    group.lines.wrappedValue.removeAll { $0.id == line.id }
                }
            }
            .onDelete { group.lines.wrappedValue.remove(atOffsets: $0) }

            HStack {
                Button {
                    group.lines.wrappedValue.append(LineItemDraft())
                } label: {
                    Label("Add line item", systemImage: "plus.circle.fill")
                }

                if !priceSheetItems.isEmpty {
                    Spacer()
                    Menu {
                        ForEach(priceSheetItems) { item in
                            Button(item.name) {
                                group.lines.wrappedValue.append(LineItemDraft(priceSheetItem: item))
                            }
                        }
                    } label: {
                        Label("From Price Sheet", systemImage: "tag")
                    }
                }
            }

            HStack {
                Spacer()
                let subtotal = group.wrappedValue.subtotal.formatted(.money)
                Text(combineTotals ? mbLoc("Group subtotal: \(subtotal)") : mbLoc("Option total: \(subtotal)"))
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
            }

            if groups.count > 1 {
                Button(role: .destructive) {
                    groups.removeAll { $0.id == group.wrappedValue.id }
                } label: {
                    Label(combineTotals ? "Remove group" : "Remove option", systemImage: "trash")
                }
            }
        } header: {
            Text(group.wrappedValue.name.isEmpty ? (combineTotals ? mbLoc("Group") : mbLoc("Option")) : group.wrappedValue.name)
        }
    }

    private func lineEditor(_ line: Binding<LineItemDraft>, onRemove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameField(
                line.name,
                placeholder: "Item name",
                field: .lineName(line.wrappedValue.id),
                counts: lineNameCountsCache
            )
            TextField("Description (optional)", text: line.details)
                .font(.subheadline)
                .foregroundStyle(GLTheme.textSecondary)

            HStack {
                AutoClearNumberField(placeholder: "Qty", value: line.quantity, style: .number, clearsAt: 1)
                    .frame(maxWidth: 70)
                Picker("Unit", selection: line.unit) {
                    ForEach(UnitOfMeasure.allCases) { Text($0.abbreviation).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Text("×").foregroundStyle(GLTheme.textSecondary)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("Discount", selection: line.discountType) {
                        Text("No discount").tag(AdjustmentType.none)
                        Text("% off").tag(AdjustmentType.percentage)
                        Text("$ off").tag(AdjustmentType.fixed)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("lineDiscountPicker")
                    Spacer()
                    if line.discountType.wrappedValue != .none {
                        // A PERCENT off caps at 100 — 100% already takes the line to zero, so
                        // 150 buys nothing but a wrong-looking number on a document the customer
                        // reads. A DOLLAR amount has no ceiling: $150 off is an ordinary figure.
                        AutoClearNumberField(placeholder: "0", value: line.discountValue, style: .number, clearsAt: 0,
                                             maxValue: line.discountType.wrappedValue == .percentage ? 100 : nil)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                    }
                }
                if line.discountType.wrappedValue == .percentage {
                    Text("Percentages stop at 100% — that’s the whole amount.")
                        .font(.caption)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            }

            HStack {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                Spacer()
                if line.wrappedValue.lineDiscount > 0 {
                    Text("−\(line.wrappedValue.lineDiscount.formatted(.money))")
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                }
                Text("Line total: \(line.wrappedValue.lineTotal.formatted(.money))")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Name fields with type-ahead suggestions

    /// The names this business has used on estimates, fetched once.
    private func loadNameSuggestions() {
        groupNameCountsCache = LineItemNameSuggestions.counts(
            LineItemNameSuggestions.storedNames(\EstimateGroup.name, in: modelContext))
        lineNameCountsCache = LineItemNameSuggestions.counts(
            LineItemNameSuggestions.storedNames(\EstimateLineItem.name, in: modelContext))
    }

    @ViewBuilder
    private func nameField(_ text: Binding<String>, placeholder: LocalizedStringKey, field: SuggestionField, counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: text)
                .font(.headline)
                .focused($focusedField, equals: field)

            if focusedField == field {
                ForEach(LineItemNameSuggestions.matching(text.wrappedValue, counts: counts), id: \.self) { name in
                    Button {
                        text.wrappedValue = name
                        focusedField = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(GLTheme.accentFill)
                            Text(name)
                                .foregroundStyle(GLTheme.textPrimary)
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

    /// One document-level adjustment (Discount here and on the invoice; Deposit on estimates).
    ///
    /// A PERCENT caps at 100 at the keyboard. `EstimateTotals` already clamps a 150% discount to
    /// the whole subtotal, so 150 and 100 bill the identical total — but someone who meant 15%
    /// and typed 150 never learned that, and the number they read back was wrong. The cap makes
    /// the clamp visible while it can still be fixed; the money math is untouched (it agrees
    /// bit-for-bit with the server's money.ts and is pinned by shared conformance vectors).
    /// The Deposit field is capped by the same line, deliberately: a deposit is already clamped
    /// to 0...total, so >100% asks for more than the whole job and bills exactly the whole job.
    /// A FIXED amount is never capped — it is dollars, and $150 off is an ordinary figure.
    /// `fixedIsAmount`: a deposit in dollars is money the customer pays, entered in whole cents
    /// (law 60); a discount in dollars is a price adjustment and keeps what was typed.
    private func adjustmentSection(title: String, type: Binding<AdjustmentType>, value: Binding<Double>,
                                   fixedIsAmount: Bool = false) -> some View {
        Section {
            Picker(title, selection: type) {
                ForEach(AdjustmentType.allCases) { Text($0.label).tag($0) }
            }
            if type.wrappedValue != .none {
                LabeledContent(type.wrappedValue == .percentage ? "\(title) (%)" : "\(title) amount") {
                    AutoClearNumberField(placeholder: "0", value: value, style: .number, clearsAt: 0,
                                         maxValue: type.wrappedValue == .percentage ? 100 : nil,
                                         wholeCents: fixedIsAmount && type.wrappedValue == .fixed)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            // `title` arrives already localized (mbLoc at the call site), so Text(String) — which
            // does not re-localize — is the correct initializer, same as the old Section(title).
            Text(title)
        } footer: {
            if type.wrappedValue == .percentage {
                Text("Percentages stop at 100% — that’s the whole amount.")
            }
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            if isOptionsDraft {
                // No grand total in options mode — mirror the detail screen and
                // PDF: each group is its own priced option (QA 2026-09-01).
                ForEach(groups) { group in
                    summaryRow(group.name.isEmpty ? mbLoc("Option") : group.name,
                               EstimateTotals(lines: group.lines.map { ($0.exactLineTotal, $0.isTaxable) },
                                              taxRatePercent: taxRatePercent,
                                              discountType: .none, discountValue: 0,
                                              depositType: .none, depositValue: 0).total)
                }
                Text("Each option stands on its own — there is no combined total.")
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
            } else {
                summaryRow(mbLoc("Subtotal"), totals.subtotal)
                if totals.discount > 0 { summaryRow(mbLoc("Discount"), -totals.discount) }
                if totals.tax > 0 { summaryRow(mbLoc("Tax"), totals.tax) }
                summaryRow(mbLoc("Total"), totals.total, bold: true)
                if totals.deposit > 0 { summaryRow(mbLoc("Required Deposit"), totals.deposit) }
            }
        }
    }

    private func summaryRow(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted(.money))
        }
        .fontWeight(bold ? .bold : .regular)
    }

    /// Save, unless the totals show a discount has wiped the estimate out — then ask first.
    ///
    /// Skipped on a vanished estimate: `save()` dismisses that one without writing, and asking to
    /// confirm a save that silently isn't happening is worse than not asking.
    private func attemptSave() {
        if !editingEstimateVanished, ZeroingDiscountGuard.fires(totals: totals, discountType: discountType) {
            showingZeroingDiscount = true
            return
        }
        save()
    }

    private func save() {
        // If the estimate we're editing was deleted out from under us (e.g. its customer was deleted on
        // another device), don't write rows onto a tombstoned object — that silently orphans the
        // edits. Bail instead.
        if editingEstimateVanished {
            dismiss()
            return
        }
        // A fast double-tap (toolbar Save, or Save in the zeroing-discount alert) can fire again
        // during the dismiss animation and insert a second estimate. Latched here rather than in
        // `SaveOnceButton` so the bail above stays retryable — same shape as ScheduleJobSheet.save().
        guard !isSaving else { return }
        // Lapsed = 100% read-only. Refused BEFORE the latch and before any property is touched:
        // SwiftData autosaves, so a half-applied save would persist even though the form said no,
        // and a latched Save would stay dead behind the alert that invites a retry.
        guard ReadOnlyGate.allows(.saveEstimate, into: $readOnlyRefusal) else { return }
        isSaving = true
        // EstimateService validates, numbers, reconciles the rows in place and saves — the same
        // path the assistant uses (DocumentDrafts.swift has the draft shape).
        var draft = EstimateDraft()
        draft.jobTitle = jobTitle
        draft.status = status
        draft.validUntil = validUntil
        draft.taxRatePercent = taxRatePercent
        draft.combineTotals = combineTotals
        draft.discountType = discountType
        draft.discountValue = discountValue
        draft.depositType = depositType
        draft.depositValue = depositValue
        draft.customerNotes = customerNotes
        draft.terms = terms
        draft.serviceAddress = Address(street1: serviceStreet,
                                       street2: serviceStreet2.isEmpty ? nil : serviceStreet2,
                                       city: serviceCity,
                                       state: serviceState, postalCode: servicePostal)
        draft.groups = groups
        do {
            if let editingEstimate {
                try EstimateService.update(editingEstimate, with: draft, origin: .screen, in: modelContext)
            } else if let customer {
                try EstimateService.create(draft, for: customer, origin: .screen, in: modelContext)
            } else {
                throw DomainError.recordNotFound
            }
        } catch {
            isSaving = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }
}

#Preview {
    EstimateFormScreen(customer: Customer(firstName: "Jane", lastName: "Doe"))
        .modelContainer(for: [Customer.self, Estimate.self], inMemory: true)
}

// MARK: - Fetches shared by the Estimate and Invoice forms (QA F153)

extension ModelContext {
    /// True while `record` is neither deleted nor missing from the store: a fetch of that one
    /// record, never a whole table. Reads only identity and context first, so it is safe on a
    /// deleted record (Models/LiveRows.swift). A fetch that fails counts as gone, as an empty
    /// @Query did before.
    func stillStores<T: PersistentModel>(_ record: T) -> Bool {
        if record.isSavedDelete || record.isDeleted { return false }
        let id = record.persistentModelID
        var descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return ((try? fetchCount(descriptor)) ?? 0) > 0
    }
}

extension LineItemNameSuggestions {
    /// Every stored `name` of one record type, for the type-ahead: fetched once, that column
    /// only. A failed fetch offers no suggestions rather than stopping the form.
    @MainActor
    static func storedNames<T: PersistentModel>(_ name: KeyPath<T, String>, in context: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<T>()
        descriptor.propertiesToFetch = [name]
        return ((try? context.fetch(descriptor)) ?? []).map { $0[keyPath: name] }
    }
}
