//
//  PriceSheetService.swift
//  GLSmallBusiness
//
//  Every Price Sheet write — the item form and (later) the assistant's tools; the swipe delete is
//  `DeletionService`'s — plus the catalog's search and grouping, so a tool finds items exactly as the screen
//  lists them. Price sheet items are a sync type (`price_sheet_item`, since 2026-10-03, QA finding F3):
//  backed up to the person's Gold Life account like every record, so a sign-out wipe or a second
//  device gets them back. Never capped. `saveChanges()` stamps their `syncID` and `updatedAt` like
//  any synced record, and a delete goes through `deleteSynced` (in `DeletionService`) so the server
//  gets a tombstone.
//
//  Rules kept from the form: text trimmed; the name is required; the default quantity is at least
//  0.01 (a lower or negative one is raised to it, never refused). New here: every write ends in
//  `saveChanges()`; the price and discount can't be negative or non-finite; a percentage discount
//  is held to 100 on every save (QA F61: a carried 1e20 trapped the Price Sheet row), and a tool
//  asking for more than 100 is refused instead.
//

import Foundation
import SwiftData

/// A price sheet item's editable fields.
struct PriceItemDraft: Equatable {
    var name = ""
    var category = ""
    var details = ""
    var unit: UnitOfMeasure = .squareFoot
    var unitPrice: Double = 0
    var defaultQuantity: Double = 1
    var kind: LineItemKind = .labor
    var isTaxable = false
    var discountType: AdjustmentType = .none
    var discountValue: Double = 0

    init(name: String = "", category: String = "", details: String = "",
         unit: UnitOfMeasure = .squareFoot, unitPrice: Double = 0, defaultQuantity: Double = 1,
         kind: LineItemKind = .labor, isTaxable: Bool = false,
         discountType: AdjustmentType = .none, discountValue: Double = 0) {
        self.name = name
        self.category = category
        self.details = details
        self.unit = unit
        self.unitPrice = unitPrice
        self.defaultQuantity = defaultQuantity
        self.kind = kind
        self.isTaxable = isTaxable
        self.discountType = discountType
        self.discountValue = discountValue
    }

    /// The item's current values — the starting point for a partial edit.
    init(_ item: PriceSheetItem) {
        self.init(name: item.name, category: item.category, details: item.details, unit: item.unit,
                  unitPrice: item.unitPrice, defaultQuantity: item.defaultQuantity, kind: item.kind,
                  isTaxable: item.isTaxable, discountType: item.discountType,
                  discountValue: item.discountValue)
    }
}

@MainActor
enum PriceSheetService {

    /// The group an item with no category is listed under.
    static let generalCategory = "General Services"

    /// Adds an item. No free-tier cap (the catalog has none). `now` is not read: `saveChanges()`
    /// stamps `updatedAt` on every synced record; the parameter stays for the assistant's callers.
    @discardableResult
    static func create(_ draft: PriceItemDraft, origin: WriteOrigin = .tool, in context: ModelContext,
                       now: Date = .now, subscription: SubscriptionManager? = nil) throws -> PriceSheetItem {
        try DomainGate.requireCanCreate(PriceSheetItem.self, cap: nil, operation: .savePriceSheetItem,
                                        in: context, subscription)
        try validate(draft, origin)
        let item = PriceSheetItem()
        context.insert(item)
        apply(draft, to: item)
        context.saveChanges()
        return item
    }

    /// Edits an item in place. (`now`: see `create`.)
    static func update(_ item: PriceSheetItem, with draft: PriceItemDraft, origin: WriteOrigin = .tool,
                       in context: ModelContext, now: Date = .now,
                       subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.savePriceSheetItem, subscription)
        try DomainGate.requireLive(item, .savePriceSheetItem)
        try validate(draft, origin)
        apply(draft, to: item)
        context.saveChanges()
    }

    /// The item's id for a tool, minted on first touch — and saved, unless the app is read-only.
    /// The same rule as every synced record, so it is `DomainSyncIdentity.ensure`'s.
    @discardableResult
    static func ensureID(_ item: PriceSheetItem, in context: ModelContext,
                         subscription: SubscriptionManager? = nil) throws -> UUID {
        try DomainSyncIdentity.ensure(item, in: context, subscription: subscription)
    }

    // MARK: Search and grouping (reads)

    /// The catalog's search: every word of the query is in the name, category or details
    /// (`PriceSheetItem.matchesSearch`, the app's one matcher). A blank query matches everything.
    static func search(_ items: [PriceSheetItem], query: String) -> [PriceSheetItem] {
        items.filter { $0.matchesSearch(query) }
    }

    /// Items by trimmed category, blank ones under `generalCategory`.
    static func grouped(_ items: [PriceSheetItem]) -> [String: [PriceSheetItem]] {
        Dictionary(grouping: items) { groupName($0) }
    }

    /// Category names in the catalog's order: A–Z, with `generalCategory` last.
    static func sortedCategories(_ names: some Collection<String>) -> [String] {
        names.sorted { a, b in
            if a == generalCategory { return false }
            if b == generalCategory { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    static func groupName(_ item: PriceSheetItem) -> String {
        let trimmed = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? generalCategory : trimmed
    }

    // MARK: - Discount display and range

    /// The row's discount badge ("12.5% off", "$40.00 off"); nil when the item has no discount.
    /// The percentage is shown as the value it takes off (0…100, the same clamp the line math
    /// applies), with its decimals — never through `Int(_:)`, which truncated 12.5 to 12 and
    /// trapped on a stored value past Int.max (QA F61).
    static func discountBadge(_ type: AdjustmentType, _ value: Double,
                              locale: Locale = MBLocalization.currentLocale) -> String? {
        let amount: String
        switch type {
        case .none:
            return nil
        case .percentage:
            amount = (discountValue(value, for: .percentage) / 100)
                .formatted(.percent.precision(.fractionLength(0...2)).locale(locale))
        case .fixed:
            amount = DomainMoney.clampedNonNegative(value).formatted(.money)
        }
        return mbLoc("\(amount) off")
    }

    /// The discount value a type can hold: a percentage is held to 0…100 (negative or non-finite
    /// becomes 0); an amount is left as it is (`validate` refuses a negative or non-finite one).
    /// The form applies it when the type changes and every save applies it, whatever the origin.
    nonisolated static func discountValue(_ value: Double, for type: AdjustmentType) -> Double {
        guard type == .percentage else { return value }
        return min(DomainMoney.clampedNonNegative(value), 100)
    }

    // MARK: - Rules

    /// The default quantity is not checked: the write raises it to 0.01, as the form always did.
    private static func validate(_ draft: PriceItemDraft, _ origin: WriteOrigin) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainGate.refusal(.itemNameRequired, .savePriceSheetItem)
        }
        try DomainGate.requireNonNegative(draft.unitPrice, draft.discountValue, for: .savePriceSheetItem)
        if origin == .tool, draft.discountType == .percentage {
            try DomainGate.requirePercent(draft.discountValue, for: .savePriceSheetItem)
        }
    }

    private static func apply(_ draft: PriceItemDraft, to item: PriceSheetItem) {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        setIfChanged(item, \.name, trim(draft.name))
        setIfChanged(item, \.category, trim(draft.category))
        setIfChanged(item, \.details, trim(draft.details))
        setIfChanged(item, \.unitRaw, draft.unit.rawValue)
        setIfChanged(item, \.unitPrice, draft.unitPrice)
        setIfChanged(item, \.defaultQuantity, max(0.01, draft.defaultQuantity))
        setIfChanged(item, \.kindRaw, draft.kind.rawValue)
        setIfChanged(item, \.isTaxable, draft.isTaxable)
        setIfChanged(item, \.discountTypeRaw, draft.discountType.rawValue)
        setIfChanged(item, \.discountValue, discountValue(draft.discountValue, for: draft.discountType))
    }
}
