//
//  PriceSheetServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The Price Sheet save path and the catalog's search and grouping.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct PriceSheetServiceTests {

    @Test func createTrimsClampsAndMintsAnID() throws {
        let context = try DomainFixtures.context()
        let now = TS.day(2026, 9, 1)
        let draft = PriceItemDraft(name: " Tile install ", category: " Tile ", details: " per sq ft ",
                                   unit: .squareFoot, unitPrice: 12, defaultQuantity: 0, kind: .labor,
                                   discountType: .percentage, discountValue: 10)
        let item = try DomainState.neverSubscribed.run { try PriceSheetService.create(draft, in: context, now: now) }
        #expect(item.name == "Tile install" && item.category == "Tile" && item.details == "per sq ft")
        #expect(item.defaultQuantity == 0.01, "the form's minimum quantity")
        #expect(item.unitPrice == 12 && item.discountType == .percentage && item.discountValue == 10)
        // A sync type since 2026-10-03 (QA F3): `saveChanges()` stamps the id and the edit time,
        // as it does for every synced record, so `now` no longer sets `updatedAt`.
        #expect(item.syncID != nil, "every item gets the id it syncs under, which a tool can also name")
        #expect(item.updatedAt != nil && !context.hasChanges)
    }

    @Test func refusals() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            #expect(domainError { _ = try PriceSheetService.create(PriceItemDraft(name: " "), in: context) }
                    == .itemNameRequired)
            #expect(domainError { _ = try PriceSheetService.create(PriceItemDraft(name: "A", unitPrice: -1), in: context) }
                    == .negativeValue)
            // A negative default quantity is raised to the minimum, as the form always did — never refused.
            let clamped = try PriceSheetService.create(PriceItemDraft(name: "Q", defaultQuantity: -2), in: context)
            #expect(clamped.defaultQuantity == 0.01)
            #expect(domainError { _ = try PriceSheetService.create(PriceItemDraft(name: "A", discountType: .percentage, discountValue: 120), in: context) }
                    == .percentOutOfRange)
            // A fixed discount is money, not a percentage — no 100 cap.
            _ = try PriceSheetService.create(PriceItemDraft(name: "A", discountType: .fixed, discountValue: 120), in: context)
        }
        #expect(DomainState.lapsed.run { domainError { _ = try PriceSheetService.create(PriceItemDraft(name: "B"), in: context) } }
                == .readOnly(operation: "savePriceSheetItem", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<PriceSheetItem>()) == 2)
    }

    /// A percentage over 100 is held to 100 on every save (QA F61): "$ off 150" switched to "% off",
    /// or an old item, used to keep 150 — and 20 typed digits kept 1e20, which trapped the
    /// Price Sheet row on every open. A tool asking for one is still refused.
    @Test func theScreenHoldsAPercentageTo100() throws {
        let context = try DomainFixtures.context()
        let draft = PriceItemDraft(name: "Old", discountType: .percentage, discountValue: 150)
        let item = try DomainState.subscribed.run { try PriceSheetService.create(draft, origin: .screen, in: context) }
        #expect(item.discountValue == 100 && !context.hasChanges)
        var huge = draft
        huge.discountValue = 1e20
        try DomainState.subscribed.run { try PriceSheetService.update(item, with: huge, origin: .screen, in: context) }
        #expect(item.discountValue == 100)
        #expect(DomainState.subscribed.run { domainError { try PriceSheetService.update(item, with: draft, in: context) } }
                == .percentOutOfRange)
        // An amount is money, not a percentage: kept as typed.
        var amount = draft
        amount.discountType = .fixed
        amount.discountValue = 1e20
        try DomainState.subscribed.run { try PriceSheetService.update(item, with: amount, origin: .screen, in: context) }
        #expect(item.discountValue == 1e20)
    }

    /// The form's type picker: switching to % holds the carried value to 0…100.
    @Test func switchingToPercentHoldsTheValueInRange() {
        #expect(PriceSheetService.discountValue(1e20, for: .percentage) == 100)
        #expect(PriceSheetService.discountValue(150, for: .percentage) == 100)
        #expect(PriceSheetService.discountValue(-5, for: .percentage) == 0)
        #expect(PriceSheetService.discountValue(.nan, for: .percentage) == 0)
        #expect(PriceSheetService.discountValue(12.5, for: .percentage) == 12.5)
        #expect(PriceSheetService.discountValue(1e20, for: .fixed) == 1e20)
    }

    /// The row badge shows the exact percentage (12.5, not 12) and never traps on a stored value
    /// too big for an Int (QA F61).
    @Test func theRowBadgeShowsTheExactPercentAndNeverTraps() {
        let en = Locale(identifier: "en_US")
        #expect(PriceSheetService.discountBadge(.percentage, 12.5, locale: en)?.contains("12.5%") == true)
        #expect(PriceSheetService.discountBadge(.percentage, 10, locale: en)?.contains("10%") == true)
        #expect(PriceSheetService.discountBadge(.percentage, 1e20, locale: en)?.contains("100%") == true,
                "an old stored value shows what it takes off: all of it")
        #expect(PriceSheetService.discountBadge(.fixed, 1e20, locale: en) != nil)
        #expect(PriceSheetService.discountBadge(.none, 5, locale: en) == nil)
    }

    @Test func updateEnsureIDAndDelete() throws {
        let context = try DomainFixtures.context()
        let legacy = PriceSheetItem(name: "Old")
        context.insert(legacy)
        try context.save()
        #expect(legacy.syncID == nil)
        let id = try DomainState.subscribed.run { try PriceSheetService.ensureID(legacy, in: context) }
        #expect(legacy.syncID == id && !context.hasChanges)

        try DomainState.subscribed.run {
            var draft = PriceItemDraft(legacy)
            draft.unitPrice = 50
            try PriceSheetService.update(legacy, with: draft, in: context)
            #expect(legacy.unitPrice == 50 && legacy.syncID == id, "an existing id is never replaced")
        }
        #expect(DomainState.offline.run { domainError { try DeletionService.delete([.priceItem(legacy)], in: context) } }
                == .readOnly(operation: "deletePriceSheetItem", lapsed: false))
        _ = try DomainState.subscribed.run { try DeletionService.delete([.priceItem(legacy)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<PriceSheetItem>()) == 0)
    }

    @Test func searchAndGroupingMatchTheCatalog() {
        let a = PriceSheetItem(name: "Grout", details: "sanded", category: "Tile")
        let b = PriceSheetItem(name: "Haul away", category: "  ")
        let c = PriceSheetItem(name: "Shower pan", category: "Plumbing")
        let all = [a, b, c]
        #expect(PriceSheetService.search(all, query: "  ").count == 3)
        #expect(PriceSheetService.search(all, query: "SAND").map(\.name) == ["Grout"])
        #expect(PriceSheetService.search(all, query: "plumb").map(\.name) == ["Shower pan"])
        let groups = PriceSheetService.grouped(all)
        #expect(groups[PriceSheetService.generalCategory]?.map(\.name) == ["Haul away"])
        #expect(PriceSheetService.sortedCategories(groups.keys)
                == ["Plumbing", "Tile", PriceSheetService.generalCategory])
    }

    // MARK: Item math (moved from the old AIAssistantTests — not an assistant test)

    @Test func priceSheetItemMathAndProperties() throws {
        let ctx = try DomainFixtures.context()
        let item = PriceSheetItem(
            name: "Ceramic Tile Installation",
            details: "Standard floor prep, thin-set mortar, 12x24 porcelain tile.",
            defaultQuantity: 250,
            unit: .squareFoot,
            unitPrice: 14.50,
            kind: .labor,
            isTaxable: false,
            category: "Tile Work",
            discountType: .percentage,
            discountValue: 10
        )
        ctx.insert(item)
        ctx.saveChanges()

        #expect(item.name == "Ceramic Tile Installation")
        #expect(item.unit == .squareFoot)
        #expect(item.kind == .labor)
        #expect(!item.isTaxable)
        #expect(item.grossTotal == 250 * 14.50) // 3625
        #expect(item.lineDiscount == 362.50)
        #expect(item.netTotal == 3262.50)
    }
}
