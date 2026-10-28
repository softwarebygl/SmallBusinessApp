//
//  PriceSheetItemFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 9/15/26.
//
//  Editor for Price Sheet items with 100% field parity with estimate line items:
//  name, details, unit of measure, unit price, labor vs material, taxable toggle,
//  category/group, default quantity, and default line discount.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct PriceSheetItemFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let editing: PriceSheetItem?
    var onSave: ((PriceSheetItem) -> Void)? = nil

    @State private var name: String
    @State private var category: String
    @State private var details: String
    @State private var unit: UnitOfMeasure
    @State private var unitPrice: Double
    @State private var defaultQuantity: Double
    @State private var kind: LineItemKind
    @State private var isTaxable: Bool
    @State private var discountType: AdjustmentType
    @State private var discountValue: Double
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal PriceSheetService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(editing: PriceSheetItem? = nil, onSave: ((PriceSheetItem) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _category = State(initialValue: editing?.category ?? "")
        _details = State(initialValue: editing?.details ?? "")
        _unit = State(initialValue: editing?.unit ?? .squareFoot)
        _unitPrice = State(initialValue: editing?.unitPrice ?? 0.0)
        _defaultQuantity = State(initialValue: editing?.defaultQuantity ?? 1.0)
        _kind = State(initialValue: editing?.kind ?? .labor)
        _isTaxable = State(initialValue: editing?.isTaxable ?? false)
        _discountType = State(initialValue: editing?.discountType ?? .none)
        _discountValue = State(initialValue: editing?.discountValue ?? 0.0)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The form's editable state as one value, snapshotted on appear: any difference is an
    /// unsaved edit, which the discard guard protects (law 7, audit 2026-10-03 F134).
    @State private var initialDigest: String?
    private var digest: String {
        [name, category, details, unit.rawValue, "\(unitPrice)", "\(defaultQuantity)", kind.rawValue,
         "\(isTaxable)", discountType.rawValue, "\(discountValue)"].joined(separator: "|")
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            Section("Item Details") {
                TextField("Service or item name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Category (e.g. Tile, Prep, Plumbing)", text: $category)
                    .textInputAutocapitalization(.words)
                TextField("Scope of work / description (optional)", text: $details, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Pricing & Measurement") {
                Picker("Unit of measure", selection: $unit) {
                    ForEach(UnitOfMeasure.allCases) { u in
                        Text(u.label).tag(u)
                    }
                }

                LabeledContent("Unit price") {
                    AutoClearNumberField(placeholder: "0.00", value: $unitPrice, style: .currency)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("Default quantity") {
                    AutoClearNumberField(placeholder: "1", value: $defaultQuantity, style: .number)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Tax & Classification") {
                Picker("Type", selection: $kind) {
                    ForEach(LineItemKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .onChange(of: kind) { _, newKind in
                    if editing == nil {
                        isTaxable = (newKind == .material)
                    }
                }

                Toggle("Taxable", isOn: $isTaxable)
            }

            Section("Line Discount (Optional)") {
                Picker("Discount type", selection: $discountType) {
                    ForEach(AdjustmentType.allCases) { dt in
                        Text(dt.label).tag(dt)
                    }
                }
                .onChange(of: discountType) { _, newType in
                    // An amount carried into % is held to 0–100 here, not only once the field
                    // is tapped (QA F61: 20 digits switched to % saved as 1e20%).
                    discountValue = PriceSheetService.discountValue(discountValue, for: newType)
                }

                if discountType != .none {
                    LabeledContent(discountType == .percentage ? "Discount (%)" : "Discount amount") {
                        AutoClearNumberField(
                            placeholder: "0",
                            value: $discountValue,
                            style: .number,
                            clearsAt: 0,
                            maxValue: discountType == .percentage ? 100 : nil
                        )
                        .multilineTextAlignment(.trailing)
                    }
                }
            }

            if unitPrice > 0 {
                Section("Preview Calculation") {
                    HStack {
                        Text("Line Total")
                        Spacer()
                        let line = LineMoney(quantity: defaultQuantity, unitPrice: unitPrice,
                                             discountType: discountType, discountValue: discountValue)
                        Text(DomainMoney.roundedToCents(line.floored).formatted(.money))
                            .fontWeight(.bold)
                    }
                }
            }
        }
        .glFormBackground()
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .navigationTitle(GLScript.padded(editing == nil ? mbLoc("New Catalog Item") : mbLoc("Edit Item")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editing == nil ? mbLoc("New Catalog Item") : mbLoc("Edit Item"))), for: .scrollContent)
        .toolbar {
            // Pushed like every data-entry form (law 7): Back leaves, the guard asks first
            // when there are edits, and Save commits once.
            ToolbarItem(placement: .confirmationAction) {
                SaveOnceButton(disabled: !isValid, action: save)
            }
        }
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
    }

    /// True when the item saved (the form is leaving); false re-arms Save.
    private func save() -> Bool {
        guard isValid else { return false }
        guard ReadOnlyGate.allows(.savePriceSheetItem, into: $readOnlyRefusal) else { return false }
        // PriceSheetService trims, validates and saves — the same path the assistant uses.
        let draft = PriceItemDraft(name: name, category: category, details: details, unit: unit,
                                   unitPrice: unitPrice, defaultQuantity: defaultQuantity, kind: kind,
                                   isTaxable: isTaxable, discountType: discountType,
                                   discountValue: discountValue)
        let item: PriceSheetItem
        do {
            if let editing {
                try PriceSheetService.update(editing, with: draft, origin: .screen, in: modelContext)
                item = editing
            } else {
                item = try PriceSheetService.create(draft, origin: .screen, in: modelContext)
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return false
        }
        onSave?(item)
        dismiss()
        return true
    }
}
