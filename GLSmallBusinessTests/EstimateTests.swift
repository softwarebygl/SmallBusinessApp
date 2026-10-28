//
//  EstimateTests.swift
//  GLSmallBusinessTests
//
//  Estimate money math, numbering, and the default validity window. (Expiry, the customer
//  display-name fallback, and recipient pre-fill live in CalendarJobsEstimatesCoverageTests.)
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import MessageUI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct EstimateTests {
    @Test func totalsAndDeposit() {
        let est = TS.estimate(lines: [(1000, false)])
        est.depositType = .percentage
        est.depositValue = 50
        #expect(close(est.subtotal, 1000))
        #expect(close(est.total, 1000))
        #expect(close(est.depositAmount, 500))
    }

    @Test func taxAndDiscount() {
        let est = TS.estimate(taxRatePercent: 10, lines: [(100, true)])
        #expect(close(est.taxAmount, 10))
        #expect(close(est.total, 110))
    }

    @Test func nextNumberIncrements() {
        #expect(Estimate.nextNumber(after: []) == "EST-0001")
        let a = Estimate(number: "EST-0012")
        #expect(Estimate.nextNumber(after: [a]) == "EST-0013")
    }

    @Test func defaultValidUntilIsThirtyDaysOut() {
        let created = TS.day(2026, 1, 1)
        let est = Estimate(number: "EST-1", createdAt: created)
        let days = Calendar.current.dateComponents([.day], from: created, to: est.validUntil).day ?? 0
        #expect(days == 30)
    }

    // MARK: - EstimateDetailScreen coverage

    @Test func estimateDetailScreenStatusSubtitlesAndAddress() {
        let est = TS.estimate(lines: [(500, false)])
        est.status = .draft
        let screenDraft = EstimateDetailScreen(estimate: est)
        #expect(screenDraft.statusSubtitle == mbLoc("Draft · Not yet sent"))

        est.status = .sent
        let screenSent = EstimateDetailScreen(estimate: est)
        #expect(screenSent.statusSubtitle == mbLoc("Sent · Awaiting response"))

        est.status = .accepted
        let screenAccepted = EstimateDetailScreen(estimate: est)
        #expect(screenAccepted.statusSubtitle == mbLoc("Approved manually by you"))

        est.status = .declined
        let screenDeclined = EstimateDetailScreen(estimate: est)
        #expect(screenDeclined.statusSubtitle == mbLoc("Declined by customer"))

        #expect(EstimateDetailScreen.SendAction.email.id == 0)
        #expect(EstimateDetailScreen.SendAction.text.id == 1)

        screenDraft.noteSend(.failed)
        screenDraft.noteSend(.sent)

        #expect(screenDraft.formattedAddress.isEmpty)
        est.customerAddress = Address(street1: "123 Main St", street2: "Suite 100", city: "Tampa", state: "FL", postalCode: "33601")
        #expect(!screenDraft.formattedAddress.isEmpty)
        #expect(screenDraft.formattedAddress.contains("123 Main St"))
    }

    @Test func rendersEstimateDetailScreenStates() throws {
        let world = try TestStore.demoWorld()
        let est = try #require(world.estimates.first)

        est.status = .accepted
        GLTestHost.renderBothSchemes(EstimateDetailScreen(estimate: est), container: world.container)

        est.status = .sent
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: world.container)

        est.status = .declined
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: world.container)

        est.status = .draft
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: world.container)

        // Options mode
        est.combineTotals = false
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: world.container)

        // With service address, customer notes and terms
        est.serviceAddress = Address(street1: "456 Oak Lane", city: "Orlando", state: "FL", postalCode: "32801")
        est.customerNotes = "Gate code is 1234."
        est.terms = "Due upon receipt of invoice."
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: world.container)

        // Option picker sheet
        let screen = EstimateDetailScreen(estimate: est)
        GLTestHost.render(screen.optionPickerSheet, container: world.container)

        // Send sheets
        if MFMailComposeViewController.canSendMail() {
            GLTestHost.render(screen.sendSheet(for: .email), container: world.container)
        }
        if MFMessageComposeViewController.canSendText() {
            GLTestHost.render(screen.sendSheet(for: .text), container: world.container)
        }
    }

    @Test func rendersEstimateDetailScreenWithIncompleteProfile() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let customer = Customer(firstName: "Alice", lastName: "Smith")
        let est = Estimate(jobTitle: "Patio Pavers", customer: customer)
        ctx.insert(customer)
        ctx.insert(est)
        try ctx.save()

        // Empty business profile -> profileIsComplete is false -> "Set up business profile to send" button
        GLTestHost.render(EstimateDetailScreen(estimate: est), container: container)
    }
}

