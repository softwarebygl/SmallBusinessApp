//
//  EstimateServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The one estimate save path: the Estimate form, the detail screen's status menu and Convert to
//  Invoice, and the assistant.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct EstimateServiceTests {

    private func draft(title: String = " Master bath ", lines: [(String, Double)] = [("Tile", 1000)]) -> EstimateDraft {
        var draft = EstimateDraft()
        draft.jobTitle = title
        draft.taxRatePercent = 8
        draft.serviceAddress = Address(street1: " 12 Oak St ", city: " Miami", state: "FL", postalCode: "32301")
        draft.groups = [EstimateGroupDraft(name: " Shower ", note: " 5x3 ", lines: lines.map { name, price in
            var line = EstimateLineDraft()
            line.name = name
            line.unitPrice = price
            line.isTaxable = true
            return line
        })]
        return draft
    }

    // MARK: Create

    @Test func createNumbersSnapshotsTrimsAndSaves() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let profile = BusinessProfile()
        profile.lastEstimateNumber = 7
        context.insert(profile)
        context.saveChanges()

        let estimate = try DomainState.subscribed.run {
            try EstimateService.create(draft(), for: customer, in: context)
        }
        #expect(estimate.number == "EST-0008", "numbered past the profile's counter")
        #expect(profile.lastEstimateNumber == 8, "the counter was bumped")
        #expect(estimate.jobTitle == "Master bath")
        #expect(estimate.customer === customer && estimate.customerFirstName == "Marcus", "snapshot taken")
        #expect(estimate.serviceAddress.street1 == "12 Oak St" && estimate.serviceAddress.city == "Miami")
        let group = try #require(estimate.sortedGroups.first)
        #expect(group.name == "Shower" && group.note == "5x3")
        #expect(group.sortedLineItems.map(\.name) == ["Tile"])
        #expect(estimate.total == 1080)
        #expect(estimate.syncID != nil && group.syncID != nil, "saveChanges stamped every new row")
        #expect(!context.hasChanges)
    }

    @Test func theKeepFilterDropsBlankLinesAndGroups() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        var input = draft(lines: [("Tile", 500), ("", 0), ("  ", 0)])
        input.groups.append(EstimateGroupDraft(name: "  ", lines: [EstimateLineDraft()]))
        var detailsOnly = EstimateLineDraft()
        detailsOnly.details = "Haul-away"
        input.groups.append(EstimateGroupDraft(lines: [detailsOnly]))
        let estimate = try DomainState.subscribed.run { try EstimateService.create(input, for: customer, in: context) }
        #expect(estimate.sortedGroups.count == 2, "the empty group is dropped, the details-only one kept")
        #expect(estimate.sortedGroups[0].sortedLineItems.count == 1)
        #expect(estimate.sortedGroups.map(\.sortIndex) == [0, 1])
    }

    @Test func createRefusalsWriteNothing() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        for i in 0..<FreeTier.estimates { context.insert(Estimate(number: "EST-\(i)")) }
        context.saveChanges()

        #expect(DomainState.neverSubscribed.run { domainError { try EstimateService.create(draft(), for: customer, in: context) } }
                == .freeLimitReached(operation: "saveEstimate"))
        #expect(DomainState.lapsed.run { domainError { try EstimateService.create(draft(), for: customer, in: context) } }
                == .readOnly(operation: "saveEstimate", lapsed: true))
        #expect(DomainState.offline.run { domainError { try EstimateService.create(draft(), for: customer, in: context) } }
                == .readOnly(operation: "saveEstimate", lapsed: false))
        #expect(DomainState.subscribed.run { domainError { try EstimateService.create(draft(title: "  "), for: customer, in: context) } }
                == .titleRequired)

        var negative = draft()
        negative.groups[0].lines[0].unitPrice = -5
        #expect(DomainState.subscribed.run { domainError { try EstimateService.create(negative, for: customer, in: context) } }
                == .negativeValue)
        var overPercent = draft()
        overPercent.discountType = .percentage
        overPercent.discountValue = 150
        #expect(DomainState.subscribed.run { domainError { try EstimateService.create(overPercent, for: customer, in: context) } }
                == .percentOutOfRange)
        var overFixed = draft()
        overFixed.discountType = .fixed
        overFixed.discountValue = 150    // dollars have no ceiling
        try DomainState.subscribed.run { _ = try EstimateService.create(overFixed, for: customer, in: context) }
        var overTax = draft()
        overTax.taxRatePercent = 101
        #expect(DomainState.subscribed.run { domainError { try EstimateService.create(overTax, for: customer, in: context) } }
                == .percentOutOfRange)
        #expect(try context.fetchCount(FetchDescriptor<Estimate>()) == FreeTier.estimates + 1)
    }

    /// The form never capped a stored or carried percentage: "$ off 150" switched to "% off", or an
    /// estimate saved by an older build, still saves from the screen (the totals clamp it).
    @Test func theScreenKeepsPercentagesOver100() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        var input = draft()
        input.discountType = .percentage
        input.discountValue = 150
        input.depositType = .percentage
        input.depositValue = 120
        input.groups[0].lines[0].discountType = .percentage
        input.groups[0].lines[0].discountValue = 150
        let estimate = try DomainState.subscribed.run {
            try EstimateService.create(input, for: customer, origin: .screen, in: context)
        }
        #expect(estimate.discountValue == 150 && estimate.depositValue == 120)
        var edit = EstimateDraft(estimate)
        edit.jobTitle = "Renamed"
        try DomainState.subscribed.run { try EstimateService.update(estimate, with: edit, origin: .screen, in: context) }
        #expect(estimate.jobTitle == "Renamed" && !context.hasChanges)
        #expect(DomainState.subscribed.run { domainError { try EstimateService.update(estimate, with: edit, in: context) } }
                == .percentOutOfRange)
    }

    /// Tax is the exception: the totals never clamp it (150% would bill 150%), so a screen is
    /// refused past 100 too (owner fix 2026-09-22; the form caps the field). Exactly 100 saves.
    @Test func taxOver100IsRefusedFromTheScreenToo() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        var input = draft()
        input.taxRatePercent = 101
        #expect(DomainState.subscribed.run {
            domainError { try EstimateService.create(input, for: customer, origin: .screen, in: context) }
        } == .percentOutOfRange)
        #expect(try context.fetchCount(FetchDescriptor<Estimate>()) == 0)
        input.taxRatePercent = 100
        let estimate = try DomainState.subscribed.run {
            try EstimateService.create(input, for: customer, origin: .screen, in: context)
        }
        #expect(estimate.taxRatePercent == 100)

        let stored = TS.estimate(number: "EST-0099", taxRatePercent: 150, in: context)
        stored.customer = customer
        context.saveChanges()
        var edit = EstimateDraft(stored)
        edit.jobTitle = "Renamed"
        #expect(DomainState.subscribed.run {
            domainError { try EstimateService.update(stored, with: edit, origin: .screen, in: context) }
        } == .percentOutOfRange)
        #expect(stored.jobTitle == "Job" && stored.taxRatePercent == 150, "nothing was written")
    }

    @Test func aDeletedCustomerIsRefused() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        context.delete(customer)
        context.saveChanges()
        #expect(DomainState.subscribed.run { domainError { try EstimateService.create(draft(), for: customer, in: context) } }
                == .recordNotFound)
    }

    // MARK: Update

    @Test func updateReconcilesInPlaceAndQueuesNothingWhenUntouched() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let estimate = try DomainState.subscribed.run {
            try EstimateService.create(draft(lines: [("Tile", 100), ("Grout", 50)]), for: customer, in: context)
        }
        let rows = estimate.sortedGroups[0].sortedLineItems
        let tileID = try #require(rows[0].syncID)

        // Untouched: nothing is written.
        try DomainState.subscribed.run { try EstimateService.update(estimate, with: EstimateDraft(estimate), in: context) }
        #expect(!context.hasChanges)

        // Drop Grout, reprice Tile, add Sealer: Tile keeps its identity.
        var edit = EstimateDraft(estimate)
        edit.groups[0].lines.removeAll { $0.name == "Grout" }
        edit.groups[0].lines[0].unitPrice = 120
        var sealer = EstimateLineDraft()
        sealer.name = "Sealer"
        sealer.unitPrice = 30
        edit.groups[0].lines.append(sealer)
        edit.status = .sent
        try DomainState.subscribed.run { try EstimateService.update(estimate, with: edit, in: context) }
        let after = estimate.sortedGroups[0].sortedLineItems
        #expect(after.map(\.name) == ["Tile", "Sealer"])
        #expect(after[0].syncID == tileID && after[0].unitPrice == 120)
        #expect(estimate.status == .sent)
        #expect(try context.fetchCount(FetchDescriptor<EstimateLineItem>()) == 2, "Grout was deleted")
        #expect(!context.hasChanges)
    }

    @Test func updateRefusals() throws {
        let context = try DomainFixtures.context()
        let estimate = TS.estimate(in: context)
        context.saveChanges()
        #expect(DomainState.lapsed.run { domainError { try EstimateService.update(estimate, with: EstimateDraft(estimate), in: context) } }
                == .readOnly(operation: "saveEstimate", lapsed: true))
        context.delete(estimate)
        context.saveChanges()
        #expect(DomainState.subscribed.run { domainError { try EstimateService.update(estimate, with: draft(), in: context) } }
                == .recordNotFound)
    }

    // MARK: Status / validity

    @Test func statusAndValidUntil() throws {
        let context = try DomainFixtures.context()
        let estimate = TS.estimate(in: context)
        context.saveChanges()
        let day = TS.day(2026, 12, 31)
        try DomainState.subscribed.run {
            try EstimateService.setStatus(estimate, .accepted, in: context)
            try EstimateService.setValidUntil(estimate, day, in: context)
        }
        #expect(estimate.status == .accepted && estimate.validUntil == day)
        #expect(estimate.syncID != nil && !context.hasChanges)
        #expect(DomainState.offline.run { domainError { try EstimateService.setStatus(estimate, .declined, in: context) } }
                == .readOnly(operation: "saveEstimate", lapsed: false))
        #expect(estimate.status == .accepted)
    }

    // MARK: Convert

    @Test func convertMakesTheInvoiceAndThenReportsItInsteadOfDuplicating() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(number: "EST-0003", taxRatePercent: 5, lines: [(1000, true)], in: context)
        estimate.customer = customer
        estimate.depositType = .percentage
        estimate.depositValue = 10
        context.saveChanges()

        let first = try DomainState.subscribed.run { try EstimateService.convertToInvoice(estimate, in: context) }
        guard case .created(let invoice) = first else { Issue.record("expected a new invoice"); return }
        #expect(invoice.number == "INV-0001" && invoice.sourceEstimateNumber == "EST-0003")
        #expect(invoice.total == 1050 && invoice.amountDueNow == 105, "the deposit became the amount due now")
        #expect(invoice.syncID != nil && !context.hasChanges)

        let again = try DomainState.subscribed.run { try EstimateService.convertToInvoice(estimate, in: context) }
        guard case .alreadyConverted(let existing) = again else { Issue.record("expected the existing invoice"); return }
        #expect(existing === invoice)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 1)

        let forced = try DomainState.subscribed.run { try EstimateService.convertToInvoice(estimate, force: true, in: context) }
        guard case .created(let second) = forced else { Issue.record("force makes another"); return }
        #expect(second.number == "INV-0002")
    }

    @Test func anOptionsEstimateConvertsOnlyTheChosenOptions() throws {
        let context = try DomainFixtures.context()
        let estimate = TS.optionsEstimate(groups: [("Silver", [(1000, false)]), ("Gold", [(3000, false)])], in: context)
        estimate.discountType = .fixed
        estimate.discountValue = 200
        context.saveChanges()

        #expect(DomainState.subscribed.run { domainError { _ = try EstimateService.convertToInvoice(estimate, in: context) } }
                == .optionsRequired)
        #expect(DomainState.subscribed.run {
            domainError { _ = try EstimateService.convertToInvoice(estimate, chosenGroupIDs: [], in: context) }
        } == .optionsRequired)

        let gold = try #require(estimate.sortedGroups.last)
        let result = try DomainState.subscribed.run {
            try EstimateService.convertToInvoice(estimate, chosenGroupIDs: [gold.persistentModelID], in: context)
        }
        guard case .created(let invoice) = result else { Issue.record("expected a new invoice"); return }
        #expect(invoice.sortedGroups.map(\.name) == ["Gold"])
        #expect(invoice.total == 3000, "no estimate-level discount on an options conversion")
    }

    @Test func convertRefusals() throws {
        let context = try DomainFixtures.context()
        let estimate = TS.estimate(in: context)
        for i in 0..<FreeTier.invoices { context.insert(Invoice(number: "INV-X\(i)")) }
        context.saveChanges()
        #expect(DomainState.neverSubscribed.run { domainError { _ = try EstimateService.convertToInvoice(estimate, in: context) } }
                == .freeLimitReached(operation: "convertEstimateToInvoice"))
        #expect(DomainState.lapsed.run { domainError { _ = try EstimateService.convertToInvoice(estimate, in: context) } }
                == .readOnly(operation: "convertEstimateToInvoice", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == FreeTier.invoices)
    }

    /// At the free cap, asking to convert an already-converted estimate hands back the existing
    /// invoice (nothing would be created) instead of a paywall refusal.
    @Test func alreadyConvertedAnswersBeforeTheFreeCap() throws {
        let context = try DomainFixtures.context()
        let estimate = TS.estimate(number: "EST-0007", in: context)
        context.saveChanges()
        let first = try DomainState.subscribed.run { try EstimateService.convertToInvoice(estimate, in: context) }
        guard case .created(let invoice) = first else { Issue.record("expected a new invoice"); return }
        for i in 0..<FreeTier.invoices { context.insert(Invoice(number: "INV-X\(i)")) }
        context.saveChanges()
        let again = try DomainState.neverSubscribed.run { try EstimateService.convertToInvoice(estimate, in: context) }
        guard case .alreadyConverted(let existing) = again else { Issue.record("expected the existing invoice"); return }
        #expect(existing === invoice)
        #expect(DomainState.neverSubscribed.run {
            domainError { _ = try EstimateService.convertToInvoice(estimate, force: true, in: context) }
        } == .freeLimitReached(operation: "convertEstimateToInvoice"), "making ANOTHER is still capped")
    }
}
