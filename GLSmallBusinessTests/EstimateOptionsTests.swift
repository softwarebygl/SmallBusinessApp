//
//  EstimateOptionsTests.swift
//  GLSmallBusinessTests
//
//  The OPTIONS estimate (Estimate.combineTotals off, 2026-09-01): each group is a
//  standalone choice, the combined tally disappears everywhere, and every downstream
//  surface — conversion, message bodies, Stats, the job's contracted value — must
//  stop treating the sum of mutually exclusive options as a real number.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct EstimateOptionsTests {

    /// The same formatter the message bodies use, so the assertion is about WHICH number appears.
    private static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    // MARK: - isOptionsMode (Estimate.swift `isOptionsMode`)

    @Test func optionsModeNeedsTheSwitchOffAndTwoGroups() {
        let two = TS.optionsEstimate(groups: [("A", [(100, false)]), ("B", [(200, false)])])
        #expect(!two.combineTotals)
        #expect(two.isOptionsMode)

        // One group is not a choice, whatever the switch says.
        let one = TS.optionsEstimate(groups: [("Only", [(100, false)])])
        #expect(!one.combineTotals)
        #expect(!one.isOptionsMode)

        // Two groups with the switch ON is the classic estimate.
        let combined = TS.optionsEstimate(groups: [("A", [(100, false)]), ("B", [(200, false)])])
        combined.combineTotals = true
        #expect(!combined.isOptionsMode)
    }

    // MARK: - Per-option money (EstimateGroup.optionTotals)

    @Test func optionTotalsIgnoreTheEstimateDiscountAndDeposit() throws {
        let est = TS.optionsEstimate(taxRatePercent: 10, groups: [
            ("Porcelain", [(100, true), (50, false)]),   // one taxable line, one not
            ("Marble", [(200, false)])
        ])
        est.discountType = .percentage
        est.discountValue = 50
        est.depositType = .fixed
        est.depositValue = 25
        // The estimate-level adjustments really exist on the record (so ignoring them is a choice).
        #expect(est.discountAmount > 0)
        #expect(est.depositAmount > 0)

        let porcelain = try #require(est.sortedGroups.first)
        let a = porcelain.optionTotals(taxRatePercent: est.taxRatePercent)
        #expect(close(a.subtotal, 150))
        #expect(close(a.discount, 0))
        #expect(close(a.tax, 10), "tax applies to the $100 taxable line only, not the $50 labor line")
        #expect(close(a.total, 160))
        #expect(close(a.deposit, 0))

        let marble = try #require(est.sortedGroups.last)
        let b = marble.optionTotals(taxRatePercent: est.taxRatePercent)
        #expect(close(b.subtotal, 200))
        #expect(close(b.tax, 0))
        #expect(close(b.total, 200))
        #expect(close(b.deposit, 0))

        // The combined math on the same record does apply the discount — the two must differ.
        #expect(!close(est.total, a.total + b.total))
    }

    // MARK: - Conversion (Invoice.make(from:number:chosenGroups:in:))

    @Test func convertingChosenGroupsBuildsOnlyThoseGroups() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        // OPTIONS estimate with a discount AND a deposit — neither may reach the invoice.
        let options = TS.optionsEstimate(number: "EST-0001", groups: [
            ("Porcelain", [(1000, false)]),
            ("Marble", [(2000, false)])
        ], in: ctx)
        options.discountType = .fixed
        options.discountValue = 100
        options.depositType = .percentage
        options.depositValue = 30
        ctx.saveChanges()
        #expect(options.isOptionsMode)
        #expect(options.depositAmount > 0, "the deposit is real on the estimate; conversion must drop it")

        let marble = try #require(options.sortedGroups.first { $0.name == "Marble" })
        let chosen = Invoice.make(from: options, number: "INV-0001", chosenGroups: [marble], in: ctx)
        ctx.saveChanges()

        #expect(chosen.sortedGroups.count == 1)
        #expect(chosen.sortedGroups.first?.name == "Marble")
        #expect(chosen.allLineItems.count == 1)
        #expect(close(chosen.total, 2000), "the invoice bills the chosen option at its own price")
        #expect(chosen.discountType == .none)
        #expect(close(chosen.discountValue, 0))
        #expect(close(chosen.amountDueNow, 0))
        #expect(chosen.amountDueDetail.isEmpty)
        #expect(chosen.sourceEstimateNumber == "EST-0001")

        // nil chosenGroups = the classic path: every group, discount and deposit carried.
        let classic = TS.optionsEstimate(number: "EST-0002", groups: [
            ("Demo", [(1000, false)]),
            ("Install", [(2000, false)])
        ], in: ctx)
        classic.combineTotals = true
        classic.discountType = .fixed
        classic.discountValue = 100
        classic.depositType = .percentage
        classic.depositValue = 30
        ctx.saveChanges()
        #expect(!classic.isOptionsMode)
        #expect(close(classic.depositAmount, 870))   // 30% of (3000 − 100)

        let full = Invoice.make(from: classic, number: "INV-0002", in: ctx)
        ctx.saveChanges()
        #expect(full.sortedGroups.count == 2)
        #expect(full.sortedGroups.map(\.name) == ["Demo", "Install"])
        #expect(full.discountType == .fixed)
        #expect(close(full.discountValue, 100))
        #expect(close(full.total, classic.total))
        #expect(close(full.amountDueNow, 870))
        #expect(full.amountDueDetail == "Deposit to start")
    }

    // MARK: - Message bodies (EstimateMessage.plainBody / htmlBody)

    @Test func messageBodiesListEachOptionInsteadOfATotal() {
        let est = TS.optionsEstimate(groups: [
            ("Porcelain", [(1000, false)]),
            ("Marble", [(2500, false)])
        ])
        let porcelain = Self.money(1000)
        let marble = Self.money(2500)
        let sum = Self.money(3500)

        // Options mode: one line per option, at its own price; no combined figure anywhere.
        let plain = EstimateMessage.plainBody(estimate: est, business: nil)
        #expect(plain.contains("Porcelain: \(porcelain)"))
        #expect(plain.contains("Marble: \(marble)"))
        #expect(!plain.contains("Total"))
        #expect(!plain.contains(sum), "the sum of mutually exclusive options must never be quoted")

        let html = EstimateMessage.htmlBody(estimate: est, business: nil)
        #expect(html.contains("Porcelain"))
        #expect(html.contains(porcelain))
        #expect(html.contains("Marble"))
        #expect(html.contains(marble))
        #expect(!html.contains("Total"))
        #expect(!html.contains(sum))

        // Combined (the switch back on): the classic single total, and no per-option lines.
        est.combineTotals = true
        let combinedPlain = EstimateMessage.plainBody(estimate: est, business: nil)
        #expect(combinedPlain.contains("Total: \(sum)"))
        #expect(!combinedPlain.contains("Porcelain: "))
        #expect(!combinedPlain.contains("Marble: "))

        // The HTML summary box renders the label as its own cell — `>Total</td>`, no colon.
        let combinedHTML = EstimateMessage.htmlBody(estimate: est, business: nil)
        #expect(combinedHTML.contains(">Total</td>"))
        #expect(combinedHTML.contains(sum))
        #expect(!combinedHTML.contains("Porcelain"))
    }

    // MARK: - Stats (StatsEngine.summary → estimatesQuoted)

    @Test func listRowsShowOptionCount() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let classic = TS.estimate(number: "EST-0001", lines: [(500, false)], in: ctx)
        let options = TS.optionsEstimate(number: "EST-0002", groups: [
            ("Porcelain", [(1000, false)]),
            ("Marble", [(2000, false)])
        ], in: ctx)
        ctx.saveChanges()
        #expect(!classic.isOptionsMode)
        #expect(close(classic.total, 500))
        #expect(options.isOptionsMode)
        #expect(close(options.total, 3000), "the combined figure exists on the model; Stats must not count it")

        let estimates = try ctx.fetch(FetchDescriptor<Estimate>())
        #expect(estimates.count == 2)
        let summary = StatsEngine.summary(period: .all, invoices: [], estimates: estimates, receipts: [])

        #expect(close(summary.estimatesQuoted, 500), "only the classic estimate is quoted")
        #expect(summary.estimatesTotal == 2, "the options estimate still counts as an estimate")
        #expect(summary.estimatesPending == 2)
        #expect(summary.winRate == nil)
    }

    // MARK: - Job contracted value (ScheduledJob.contractedValue)

    @Test func contractedValueIgnoresOptionsEstimates() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let options = TS.optionsEstimate(number: "EST-0001", groups: [
            ("Porcelain", [(1000, false)]),
            ("Marble", [(2000, false)])
        ], in: ctx)
        let job = ScheduledJob(title: "Floor", estimate: options)
        ctx.insert(job)
        let invoice = TS.invoice(number: "INV-0001", status: .sent, lines: [(750, false)], in: ctx)
        invoice.job = job
        ctx.saveChanges()

        #expect(job.billingInvoices?.count == 1)
        #expect(job.agreedPrice == nil)
        #expect(close(options.total, 3000))
        #expect(close(job.invoicedTotal, 750))
        #expect(close(job.contractedValue, 750), "options mode falls back to what was actually invoiced")
        #expect(close(job.remainingToInvoice, 0))

        // Same record with the switch back on is a classic estimate, and its total is the contract.
        options.combineTotals = true
        #expect(close(job.contractedValue, 3000))
        #expect(close(job.remainingToInvoice, 2250))
    }
}
