//
//  InvoiceLifecycleCoverageTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for the invoice surfaces: InvoiceDetailScreen, InvoiceFormScreen and
//  InvoicesListScreen. Every real lifecycle branch of each screen is hosted in a window (via
//  GLTestHost) and laid out so SwiftUI evaluates `body`: draft / sent / partially paid / paid /
//  overdue, deposit (amount-due-now) vs none, per-line discounts, change orders in each status,
//  converted-from-estimate, Stripe fields set vs unset, sibling job payments, a deleted record,
//  and the same content at accessibility type sizes in both colour schemes. Plain rendering
//  (ViewRenderingTests) only ever reaches ONE of these branches — the demo invoice's.
//
//  The money math those screens print is NOT tested here: EstimateTotals arithmetic lives in
//  MoneyMathTests and the invoice-level logic on top of it (payments, balance, status, change-order
//  rollups, conversion) in InvoiceMoneyTests — both run in parallel because they never render.
//
//  Invoice numbers here are namespaced "INV-LC-*" because InvoicePDF.render writes
//  Invoice-<number>.pdf into the shared temp directory — a generic number could collide with a
//  concurrently-running suite's file.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import GLSmallBusiness

/// One container per suite, for speed: ninety-odd tests share a single store instead of each
/// building one. Tests stay isolated by creating their own Customer and uniquely-numbered invoices.
/// (Observer safety across containers is handled by TestStore + GLTestHost, not by sharing.)
@MainActor
private final class InvoiceLifecycleStore {
    static let shared = InvoiceLifecycleStore()
    private var made: ModelContainer?

    func container() throws -> ModelContainer {
        if let made { return made }
        let container = try TestStore.makeContainer()
        let profile = BusinessProfile()
        profile.businessName = "Gold Standard Tile"
        profile.phone = "(850) 555-0100"
        profile.email = "office@example.com"
        profile.address = Address(street1: "1280 Commerce Blvd", city: "Miami",
                                  state: "FL", postalCode: "32301")
        container.mainContext.insert(profile)
        container.mainContext.saveChanges()
        made = container
        return container
    }
}

// `.serialized` is load-bearing, not tidiness. `RunLoop.run(until:)` drains the main queue, so
// parallel @MainActor tests interleave inside `GLTestHost.render` — and a still-live hosted
// `@Query` view from one test traps (SIGTRAP, killing the whole process) when another test's
// ModelContainer posts a save notification. Running this suite one test at a time, plus the window
// teardown GLTestHost does after every render, keeps every container's SwiftUI observers scoped to
// the test that created them.
@MainActor
@Suite(.serialized)
struct InvoiceLifecycleCoverageTests {

    // MARK: - Fixtures

    /// A store with a business profile and one customer — the realistic minimum for the invoice
    /// screens, and much faster than seeding the whole demo dataset per test.
    private struct Bench {
        let container: ModelContainer
        let ctx: ModelContext
        let customer: Customer
        let profile: BusinessProfile
    }

    /// The shared store, the single business profile (reset to this test's Stripe state), and a
    /// FRESH customer — so per-customer assertions stay isolated even though the store is shared.
    private func bench(stripeConnected: Bool = false, chargesEnabled: Bool = true) throws -> Bench {
        let container = try InvoiceLifecycleStore.shared.container()
        let ctx = container.mainContext
        let profile = try #require(try ctx.fetch(FetchDescriptor<BusinessProfile>()).first)
        profile.stripeConnectedAccountId = stripeConnected ? "acct_lifecycle_test" : ""
        profile.stripeChargesEnabled = stripeConnected && chargesEnabled
        profile.payLinkDefaultOn = true

        let customer = Customer(firstName: "Marcus", lastName: "Reed",
                                email: "marcus@example.com", phoneNumber: "(850) 555-0193",
                                businessName: "Reed General Contracting",
                                address: Address(street1: "1180 Capital Cir NE", city: "Miami",
                                                 state: "FL", postalCode: "32308"))
        ctx.insert(customer)
        ctx.saveChanges()
        return Bench(container: container, ctx: ctx, customer: customer, profile: profile)
    }

    /// Builds an invoice with the customer snapshot filled in and inserts it, so the detail screen's
    /// `stillExists` @Query finds it (an invoice missing from the store renders the deleted overlay).
    @discardableResult
    private func seedInvoice(_ b: Bench,
                             number: String,
                             status: InvoiceStatus = .draft,
                             taxRatePercent: Double = 0,
                             discountType: AdjustmentType = .none,
                             discountValue: Double = 0,
                             lines: [(Double, Bool)] = [(1000, false)]) -> Invoice {
        let invoice = TS.invoice(number: number, status: status, taxRatePercent: taxRatePercent,
                                 discountType: discountType, discountValue: discountValue, lines: lines)
        invoice.customer = b.customer
        invoice.customerFirstName = b.customer.firstName
        invoice.customerLastName = b.customer.lastName
        invoice.customerBusinessName = b.customer.businessName
        invoice.customerEmail = b.customer.email
        invoice.customerPhone = b.customer.phoneNumber
        invoice.customerAddress = b.customer.address
        b.ctx.insert(invoice)
        b.ctx.saveChanges()
        return invoice
    }

    // =====================================================================================
    // MARK: - 1. Detail screen: lifecycle states
    // =====================================================================================

    @Test func rendersDraftInvoiceWithNothingElseSet() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-01")
        #expect(invoice.displayStatus == "Draft")
        #expect(!invoice.isPaid)
        #expect(!invoice.isOverdue)
        #expect(!invoice.isPartiallyPaid)
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersSentUnpaidInvoice() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-02", status: .sent, taxRatePercent: 7.5,
                                  lines: [(1200, true), (450, false)])
        invoice.dueDate = .now.addingTimeInterval(15 * 86_400)
        #expect(invoice.displayStatus == "Sent")
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersPartiallyPaidInvoiceWithPaymentList() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-03", status: .sent, lines: [(2000, false)])
        let first = TS.pay(invoice, 500, date: .now.addingTimeInterval(-5 * 86_400), method: .check)
        first.note = "Deposit to start"
        TS.pay(invoice, 250, date: .now.addingTimeInterval(-2 * 86_400), method: .zelle)
        b.ctx.saveChanges()
        #expect(invoice.isPartiallyPaid)
        #expect(close(invoice.balanceDue, 1250))
        #expect(invoice.displayStatus == "Partially Paid")
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersPaidInFullInvoice() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-04", status: .sent, lines: [(1000, false)])
        TS.pay(invoice, 1000, method: .card)
        b.ctx.saveChanges()
        #expect(invoice.isPaid)
        #expect(close(invoice.balanceDue, 0))
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersOverdueInvoice() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-05", status: .sent, lines: [(1000, false)])
        invoice.dueDate = TS.day(2020, 1, 1)
        b.ctx.saveChanges()
        #expect(invoice.isOverdue)
        #expect(invoice.displayStatus == "Overdue")
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersOverdueAndPartiallyPaidInvoice() throws {
        // Overdue wins over Partially Paid in displayStatus — both branches are live at once.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-06", status: .sent, lines: [(1000, false)])
        invoice.dueDate = TS.day(2020, 1, 1)
        TS.pay(invoice, 400)
        b.ctx.saveChanges()
        #expect(invoice.isOverdue)
        #expect(invoice.isPartiallyPaid)
        #expect(invoice.displayStatus == "Overdue")
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersOverpaidInvoice() throws {
        // More collected than billed: balance floors at 0 and the screen reads Paid.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-07", status: .sent, lines: [(1000, false)])
        TS.pay(invoice, 1250)
        b.ctx.saveChanges()
        #expect(close(invoice.amountPaid, 1250))
        #expect(close(invoice.balanceDue, 0))
        #expect(invoice.isPaid)
        #expect(!invoice.isPartiallyPaid)
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersZeroValueCompedInvoice() throws {
        // A $0 invoice that has been SENT reads Paid (the comped-job branch of `isPaid`); the same
        // invoice left as a draft does not.
        let b = try bench()
        let sent = seedInvoice(b, number: "INV-LC-08", status: .sent, lines: [(0, false)])
        #expect(close(sent.total, 0))
        #expect(sent.isPaid)
        #expect(sent.displayStatus == "Paid")

        let draft = seedInvoice(b, number: "INV-LC-09", status: .draft, lines: [(0, false)])
        #expect(!draft.isPaid)
        #expect(draft.displayStatus == "Draft")

        GLTestHost.render(InvoiceDetailScreen(invoice: sent), container: b.container)
        GLTestHost.render(InvoiceDetailScreen(invoice: draft), container: b.container)
    }

    @Test func rendersInvoiceWithNoLineItemsAtAll() throws {
        // groups == nil is the on-disk state of a brand-new invoice; the screen must survive it.
        let b = try bench()
        let invoice = Invoice(number: "INV-LC-10", jobTitle: "Empty", customer: b.customer)
        b.ctx.insert(invoice)
        b.ctx.saveChanges()
        #expect(invoice.allLineItems.isEmpty)
        #expect(close(invoice.total, 0))
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithEmptyNumberAndEmptyTitle() throws {
        // Falls back to "Invoice" for the nav title and "Untitled invoice" in the header card.
        let b = try bench()
        let invoice = Invoice(number: "", jobTitle: "", customer: b.customer)
        b.ctx.insert(invoice)
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Deposit / milestone (amount due now)

    @Test func rendersInvoiceWithDepositRequestAndDetail() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-11", status: .sent, lines: [(4000, false)])
        invoice.amountDueNow = 1200
        invoice.amountDueDetail = "30% deposit to start"
        b.ctx.saveChanges()
        #expect(invoice.hasAmountDueRequest)
        #expect(close(invoice.currentAmountDue, 1200))
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithDepositRequestButNoDetailText() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-12", status: .sent, lines: [(4000, false)])
        invoice.amountDueNow = 900
        invoice.amountDueDetail = ""
        b.ctx.saveChanges()
        #expect(invoice.hasAmountDueRequest)
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func depositRequestIsCappedAtTheRemainingBalance() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-13", status: .sent, lines: [(1000, false)])
        invoice.amountDueNow = 5000                 // asked for more than the invoice is worth
        TS.pay(invoice, 400)
        b.ctx.saveChanges()
        #expect(close(invoice.balanceDue, 600))
        #expect(close(invoice.currentAmountDue, 600))   // capped, never the raw request
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func amountDueRequestOnAFullyPaidInvoiceShowsZero() throws {
        // Documents current behaviour: a stale milestone request survives full payment, so the
        // totals card still shows the "Amount due now" row — reading $0.00.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-14", status: .sent, lines: [(1000, false)])
        invoice.amountDueNow = 300
        TS.pay(invoice, 1000)
        b.ctx.saveChanges()
        #expect(invoice.isPaid)
        #expect(invoice.hasAmountDueRequest)             // still flagged…
        #expect(close(invoice.currentAmountDue, 0))      // …but nothing is actually due
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Discounts

    @Test func rendersInvoiceWithWholeInvoicePercentageDiscount() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-15", status: .sent, taxRatePercent: 7.5,
                                  discountType: .percentage, discountValue: 20,
                                  lines: [(2000, true), (500, false)])
        #expect(close(invoice.discountAmount, 500))
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithWholeInvoiceFixedDiscount() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-16", status: .sent,
                                  discountType: .fixed, discountValue: 250,
                                  lines: [(1000, false)])
        #expect(close(invoice.discountAmount, 250))
        #expect(close(invoice.total, 750))
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithPerLineDiscounts() throws {
        // Both per-line discount types at once — the "· −$X off" caption branch on each row.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-17", status: .sent, taxRatePercent: 7.5,
                                  lines: [(1000, true), (400, false), (200, false)])
        let items = invoice.allLineItems
        items[0].discountType = .percentage; items[0].discountValue = 10
        items[1].discountType = .fixed;      items[1].discountValue = 50
        b.ctx.saveChanges()
        #expect(close(items[0].lineDiscount, 100))
        #expect(close(items[1].lineDiscount, 50))
        #expect(close(items[2].lineDiscount, 0))
        #expect(close(invoice.subtotal, 900 + 350 + 200))
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithOneHundredPercentLineDiscount() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-18", status: .sent, lines: [(1000, false)])
        let item = try #require(invoice.allLineItems.first)
        item.discountType = .percentage
        item.discountValue = 100
        b.ctx.saveChanges()
        #expect(close(item.lineTotal, 0))
        #expect(close(invoice.total, 0))
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Change orders

    @Test func rendersInvoiceWithChangeOrderInEveryStatus() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-19", status: .sent, lines: [(1000, false)])
        TS.changeOrder(invoice, number: "CO-LC-1", status: .pending, lines: [(150, false)])
        TS.changeOrder(invoice, number: "CO-LC-2", status: .approved, applied: false, lines: [(300, false)])
        TS.changeOrder(invoice, number: "CO-LC-3", status: .approved, applied: true, lines: [(200, false)])
        TS.changeOrder(invoice, number: "CO-LC-4", status: .declined, lines: [(999, false)])
        b.ctx.saveChanges()
        #expect(invoice.sortedChangeOrders.count == 4)
        #expect(close(invoice.approvedChangeOrderTotal, 300))   // only approved-and-unapplied
        #expect(close(invoice.revisedTotal, 1300))
        #expect(close(invoice.balanceDue, 1000))                // an unapplied CO is not billed
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithCreditChangeOrderLines() throws {
        // A credit pushed onto the invoice keeps its sign on screen; a floored total would read $0.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-20", status: .sent,
                                  lines: [(2000, false), (-350, false)])
        let group = try #require(invoice.sortedGroups.first)
        let credit = try #require(group.sortedLineItems.last)
        credit.name = "Credit — omitted backsplash"
        credit.fromChangeOrder = true
        b.ctx.saveChanges()

        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(credit.lineTotal, 0))
        #expect(close(screen.displayLineTotal(credit), -350))
        #expect(close(screen.groupSubtotal(group), 1650))
        #expect(close(invoice.total, 1650))
        GLTestHost.renderBothSchemes(screen, container: b.container)
    }

    @Test func rendersInvoiceWhereChangeOrderCreditExceedsTheWork() throws {
        // Net-negative invoice: the subtotal goes negative but the billed total floors at $0.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-21", status: .sent,
                                  lines: [(500, false), (-900, false)])
        let group = try #require(invoice.sortedGroups.first)
        let credit = try #require(group.sortedLineItems.last)
        credit.fromChangeOrder = true
        b.ctx.saveChanges()

        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(invoice.subtotal, -400))
        #expect(close(invoice.total, 0))
        #expect(close(invoice.balanceDue, 0))
        #expect(close(screen.groupSubtotal(group), -400))
        GLTestHost.render(screen, container: b.container)
    }

    @Test func changeOrderLinesAreExemptFromTheWholeInvoiceDiscount() throws {
        // Original work is discounted; change-order work is billed at full price and full tax.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-22", status: .sent, taxRatePercent: 10,
                                  discountType: .percentage, discountValue: 50,
                                  lines: [(1000, true), (400, true)])
        let items = invoice.allLineItems
        items[1].fromChangeOrder = true
        b.ctx.saveChanges()

        // Base (original only): sub 1000, discount 500, tax 1000 * (500/1000) * 10% = 50, total 550.
        // CO: subtotal +400, tax +40 (full rate, un-discounted).
        #expect(close(invoice.subtotal, 1400))
        #expect(close(invoice.discountAmount, 500))
        #expect(close(invoice.taxAmount, 90))
        #expect(close(invoice.total, 990))
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Converted from an estimate

    @Test func rendersInvoiceConvertedFromEstimateWithDeposit() throws {
        let b = try bench()
        let estimate = TS.estimate(number: "EST-LC-1", taxRatePercent: 7.5,
                                   lines: [(1800, true), (600, false)])
        estimate.customer = b.customer
        estimate.customerFirstName = b.customer.firstName
        estimate.customerLastName = b.customer.lastName
        estimate.customerEmail = b.customer.email
        estimate.depositType = .percentage
        estimate.depositValue = 30
        b.ctx.insert(estimate)
        b.ctx.saveChanges()

        let invoice = Invoice.make(from: estimate, number: "INV-LC-23", in: b.ctx)
        invoice.status = .sent
        b.ctx.saveChanges()

        #expect(invoice.sourceEstimateNumber == "EST-LC-1")
        #expect(close(invoice.total, estimate.total))
        #expect(invoice.hasAmountDueRequest)
        #expect(invoice.amountDueDetail == "Deposit to start")
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithEmptySourceEstimateNumber() throws {
        // "" (not nil) must NOT print an empty "From " line — the `!source.isEmpty` guard.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-24")
        invoice.sourceEstimateNumber = ""
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Stripe fields set vs unset

    @Test func rendersInvoiceWithStripePayLinkFieldsSet() throws {
        // stripeAppInvoiceId is deliberately left empty: `pollPayStatus` bails on it, so the render
        // exercises the pay-link display state without making a network call.
        let b = try bench(stripeConnected: true)
        let invoice = seedInvoice(b, number: "INV-LC-25", status: .sent, lines: [(1000, false)])
        invoice.includePayLink = true
        invoice.stripePaymentLinkId = "plink_lifecycle"
        invoice.stripePaymentLinkURL = "https://buy.stripe.com/test_lifecycle"
        invoice.stripePaymentLinkAmountCents = 100_000
        invoice.stripePaymentLinkMintedAt = .now.addingTimeInterval(-3600)
        invoice.stripePayLinkStatus = .open
        b.ctx.saveChanges()

        #expect(invoice.shouldIncludePayLink(b.profile))
        #expect(invoice.stripePayLinkStatus == .open)
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithStripeFieldsUnsetOnAConnectedBusiness() throws {
        let b = try bench(stripeConnected: true)
        let invoice = seedInvoice(b, number: "INV-LC-26", status: .sent, lines: [(1000, false)])
        invoice.includePayLink = false
        b.ctx.saveChanges()
        #expect(!invoice.shouldIncludePayLink(b.profile))
        #expect(invoice.stripePayLinkStatus == .none)
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersPaidStripeLinkInvoice() throws {
        let b = try bench(stripeConnected: true)
        let invoice = seedInvoice(b, number: "INV-LC-27", status: .sent, lines: [(1000, false)])
        invoice.includePayLink = true
        invoice.stripePaymentLinkId = "plink_paid"
        invoice.stripePaymentLinkAmountCents = 100_000
        invoice.stripePayLinkStatus = .paid
        let payment = TS.pay(invoice, 1000, method: .stripe)
        payment.stripePaymentLinkId = "plink_paid"
        b.ctx.saveChanges()
        #expect(invoice.isPaid)
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Content branches — service address, notes, terms, groups

    @Test func rendersInvoiceWithServiceAddressAndNotesAndTerms() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-28", status: .sent, lines: [(1000, false)])
        invoice.serviceAddress = Address(street1: "88 Lakeshore Dr", street2: "Unit 4",
                                         city: "Miami", state: "FL", postalCode: "32312")
        invoice.customerNotes = "Please leave the gate unlocked."
        invoice.terms = "Balance due on completion. 1.5% monthly on past-due amounts."
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithNotesOnlyAndTermsOnly() throws {
        let b = try bench()
        let notesOnly = seedInvoice(b, number: "INV-LC-29", lines: [(100, false)])
        notesOnly.customerNotes = "Notes only."
        let termsOnly = seedInvoice(b, number: "INV-LC-30", lines: [(100, false)])
        termsOnly.terms = "Terms only."
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceDetailScreen(invoice: notesOnly), container: b.container)
        GLTestHost.render(InvoiceDetailScreen(invoice: termsOnly), container: b.container)
    }

    @Test func rendersInvoiceWithMultipleNamedGroupsAndGroupNotes() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-31", status: .sent, taxRatePercent: 7.5,
                                  lines: [(800, true)])
        let second = InvoiceGroup(name: "Prep & Demo", note: "5×3×8", sortIndex: 1)
        second.invoice = invoice
        b.ctx.insert(second)
        let demo = InvoiceLineItem(name: "Demo & haul-away", details: "Includes dumpster",
                                   quantity: 1, unit: .job, unitPrice: 450, sortIndex: 0)
        demo.group = second
        b.ctx.insert(demo)
        b.ctx.saveChanges()

        #expect(invoice.sortedGroups.count == 2)
        #expect(close(invoice.subtotal, 1250))
        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(screen.groupSubtotal(second), 450))
        GLTestHost.renderBothSchemes(screen, container: b.container)
    }

    @Test func rendersInvoiceWithAnEmptyGroup() throws {
        // A group whose lineItems are nil — the ForEach over an empty collection, and a $0 subtotal.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-32", lines: [(500, false)])
        let empty = InvoiceGroup(name: "Nothing here", sortIndex: 9)
        empty.invoice = invoice
        b.ctx.insert(empty)
        b.ctx.saveChanges()

        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(screen.groupSubtotal(empty), 0))
        GLTestHost.render(screen, container: b.container)
    }

    @Test func rendersInvoiceWithUnicodeAndVeryLongText() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-33", status: .sent, lines: [(1000, false)])
        invoice.jobTitle = "Baño principal — porcelánico 12×24 ✅ 🧱"
        invoice.customerNotes = String(repeating: "Very long customer note. ", count: 40)
        invoice.terms = String(repeating: "Terms. ", count: 60)
        let item = try #require(invoice.allLineItems.first)
        item.name = "Instalación — «rectificado» 24″"
        item.details = String(repeating: "detail ", count: 30)
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    @Test func rendersInvoiceWithNoCustomerNameFallsBackToBusinessThenPlaceholder() throws {
        let b = try bench()
        let businessOnly = seedInvoice(b, number: "INV-LC-34", lines: [(100, false)])
        businessOnly.customerFirstName = ""
        businessOnly.customerLastName = ""
        businessOnly.customerBusinessName = "Reed General Contracting"
        #expect(businessOnly.customerDisplayName == "Reed General Contracting")

        let nameless = seedInvoice(b, number: "INV-LC-35", lines: [(100, false)])
        nameless.customer = nil
        nameless.customerFirstName = "   "
        nameless.customerLastName = ""
        nameless.customerBusinessName = nil
        nameless.customerEmail = ""
        nameless.customerPhone = ""
        nameless.customerAddress = Address()
        b.ctx.saveChanges()
        #expect(nameless.customerDisplayName == "Customer")

        GLTestHost.render(InvoiceDetailScreen(invoice: businessOnly), container: b.container)
        GLTestHost.render(InvoiceDetailScreen(invoice: nameless), container: b.container)
    }

    // MARK: Sibling job payments ("Earlier on this job")

    @Test func rendersProgressBillingInvoiceWithEarlierJobPayments() throws {
        let b = try bench()
        let job = ScheduledJob(title: "Kitchen remodel", customer: b.customer, agreedPrice: 9000)
        b.ctx.insert(job)

        let first = seedInvoice(b, number: "INV-LC-36", status: .sent, lines: [(3000, false)])
        first.job = job
        TS.pay(first, 3000, date: .now.addingTimeInterval(-20 * 86_400), method: .check)

        let second = seedInvoice(b, number: "INV-LC-37", status: .sent, lines: [(4000, false)])
        second.job = job
        TS.pay(second, 1000, date: .now.addingTimeInterval(-2 * 86_400), method: .transfer)
        b.ctx.saveChanges()

        #expect(job.billingInvoices?.count == 2)
        #expect(close(job.amountPaid, 4000))
        // The second invoice's screen must show its own payment AND the earlier sibling's.
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: second), container: b.container)
        GLTestHost.render(InvoiceDetailScreen(invoice: first), container: b.container)
    }

    @Test func rendersJobBilledInvoiceWithNoSiblingPayments() throws {
        // Linked to a job, but the only billing invoice — the "Earlier on this job" block stays off.
        let b = try bench()
        let job = ScheduledJob(title: "Solo job", customer: b.customer, agreedPrice: 1000)
        b.ctx.insert(job)
        let invoice = seedInvoice(b, number: "INV-LC-38", status: .sent, lines: [(1000, false)])
        invoice.job = job
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // MARK: Deleted record + accessibility sizes

    @Test func rendersDeletedRecordOverlayForAnInvoiceMissingFromTheStore() throws {
        // The invoice was cascade-deleted from another device: `stillExists` is false and the
        // screen covers itself with DeletedRecordView instead of showing stale data.
        let b = try bench()
        let orphan = TS.invoice(number: "INV-LC-39", lines: [(500, false)])
        let stored = try b.ctx.fetch(FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.number)]))
        #expect(!stored.contains { $0.number == "INV-LC-39" })   // never inserted → stillExists is false
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: orphan), container: b.container)
    }

    @Test func rendersAtAccessibilityTypeSizesInBothSchemes() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-40", status: .sent, taxRatePercent: 7.5,
                                  discountType: .percentage, discountValue: 10,
                                  lines: [(1200, true), (450, false)])
        invoice.amountDueNow = 500
        invoice.amountDueDetail = "Progress payment"
        invoice.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Miami",
                                         state: "FL", postalCode: "32312")
        invoice.customerNotes = "Gate code 1234."
        TS.pay(invoice, 200)
        TS.changeOrder(invoice, number: "CO-LC-9", status: .approved, applied: false, lines: [(175, false)])
        b.ctx.saveChanges()

        let screen = InvoiceDetailScreen(invoice: invoice)
        GLTestHost.render(screen, container: b.container, scheme: .light, typeSize: .accessibility3)
        GLTestHost.render(screen, container: b.container, scheme: .dark, typeSize: .accessibility5)
        GLTestHost.render(screen, container: b.container, scheme: .light, typeSize: .xSmall)
    }

    @Test func rendersOnARegularWidthCanvas() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-41", status: .sent, lines: [(1000, false)])
        TS.pay(invoice, 250)
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container, size: GLTestHost.pad)
    }

    @Test func rendersARealisticFullyLoadedInvoice() throws {
        // Everything at once — tax, a whole-invoice discount, per-line discounts, a service
        // address, notes, terms, payments, a milestone request and a change order — which is the
        // state a busy job actually reaches.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-41B", status: .sent, taxRatePercent: 7.5,
                                  discountType: .percentage, discountValue: 5,
                                  lines: [(1500, true), (300, false)])
        let items = invoice.allLineItems
        items[0].discountType = .fixed
        items[0].discountValue = 125
        invoice.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Miami",
                                         state: "FL", postalCode: "32312")
        invoice.customerNotes = "Owner supplies the tile."
        invoice.terms = "Net 30. Late fee after 30 days."
        invoice.amountDueNow = 400
        invoice.amountDueDetail = "Second draw"
        TS.pay(invoice, 300, method: .zelle)
        TS.changeOrder(invoice, number: "CO-LC-13", status: .approved, applied: false,
                       lines: [(220, true)])
        b.ctx.saveChanges()

        #expect(invoice.isPartiallyPaid)
        #expect(invoice.hasAmountDueRequest)
        #expect(invoice.revisedTotal > invoice.total)
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }

    // =====================================================================================
    // MARK: - 2. Payment + amount-due sheets
    // =====================================================================================

    @Test func recordPaymentSheetPrefillsTheMilestoneNotTheWholeBalance() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-42", status: .sent, lines: [(4000, false)])
        invoice.amountDueNow = 1200
        b.ctx.saveChanges()

        // Prefilled with currentAmountDue (1200) — inside the balance, so saving is allowed.
        let sheet = RecordPaymentSheet(invoice: invoice)
        #expect(!sheet.exceedsBalance)
        #expect(!sheet.saveBlocked)
        GLTestHost.render(sheet, container: b.container)
    }

    @Test func recordPaymentSheetOnAFullyPaidInvoiceBlocksSave() throws {
        // currentAmountDue is 0 → the prefilled amount is 0 → Save is disabled.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-43", status: .sent, lines: [(1000, false)])
        TS.pay(invoice, 1000)
        b.ctx.saveChanges()
        let sheet = RecordPaymentSheet(invoice: invoice)
        #expect(sheet.saveBlocked)
        GLTestHost.render(sheet, container: b.container)
    }

    @Test func recordPaymentSheetBoundaryAtExactlyTheBalance() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-44", status: .sent, lines: [(1000, false)])
        #expect(!RecordPaymentSheet(invoice: invoice, prefillAmount: 1000).exceedsBalance)
        #expect(!RecordPaymentSheet(invoice: invoice, prefillAmount: 1000.004).exceedsBalance) // inside the epsilon
        #expect(RecordPaymentSheet(invoice: invoice, prefillAmount: 1000.01).exceedsBalance)
        #expect(RecordPaymentSheet(invoice: invoice, prefillAmount: 1000.01).saveBlocked)
    }

    @Test func recordPaymentSheetRejectsZeroAndNegativeAmounts() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-45", status: .sent, lines: [(1000, false)])
        #expect(RecordPaymentSheet(invoice: invoice, prefillAmount: 0).saveBlocked)
        #expect(RecordPaymentSheet(invoice: invoice, prefillAmount: -50).saveBlocked)
        GLTestHost.render(RecordPaymentSheet(invoice: invoice, prefillAmount: 0), container: b.container)
    }

    @Test func recordPaymentSheetRendersEveryPaymentMethodOption() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-46", status: .sent, lines: [(1000, false)])
        for method in PaymentMethod.allCases {
            let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 100, prefillMethod: method)
            #expect(!sheet.saveBlocked)
        }
        GLTestHost.render(RecordPaymentSheet(invoice: invoice, prefillAmount: 100, prefillMethod: .venmo), container: b.container)
    }

    @Test func recordPaymentSheetStripeOverageRendersTheReassuringFooter() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-47", status: .sent, lines: [(1000, false)])
        TS.pay(invoice, 800)
        b.ctx.saveChanges()
        let sheet = RecordPaymentSheet(invoice: invoice, prefillAmount: 500, prefillMethod: .stripe,
                                       prefillStripeLinkId: "plink_over")
        #expect(sheet.exceedsBalance)
        #expect(!sheet.saveBlocked)
        GLTestHost.renderBothSchemes(sheet, container: b.container)
    }

    @Test func setAmountDueSheetSeedsFromTheInvoiceAndRenders() throws {
        let b = try bench()
        let withRequest = seedInvoice(b, number: "INV-LC-48", status: .sent, lines: [(2000, false)])
        withRequest.amountDueNow = 750
        withRequest.amountDueDetail = "30% progress payment"
        let withoutRequest = seedInvoice(b, number: "INV-LC-49", status: .sent, lines: [(2000, false)])
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(SetAmountDueSheet(invoice: withRequest), container: b.container)
        GLTestHost.render(SetAmountDueSheet(invoice: withoutRequest), container: b.container)
    }

    @Test func paymentReceiptSheetRendersForEachRecordedPayment() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-50", status: .sent, lines: [(1000, false)])
        let deposit = TS.pay(invoice, 300, date: TS.day(2026, 1, 10), method: .check)
        let balance = TS.pay(invoice, 700, date: TS.day(2026, 2, 10), method: .card)
        b.ctx.saveChanges()
        #expect(close(invoice.paidThrough(deposit), 300))
        #expect(close(invoice.remainingAfter(deposit), 700))
        #expect(close(invoice.remainingAfter(balance), 0))
        GLTestHost.render(PaymentReceiptSheet(invoice: invoice, payment: deposit), container: b.container)
        GLTestHost.render(PaymentReceiptSheet(invoice: invoice, payment: balance), container: b.container)
    }

    // =====================================================================================
    // MARK: - 3. InvoicesListScreen
    // =====================================================================================

    @Test func rendersInvoicesListEmptyState() throws {
        let b = try bench()
        #expect((b.customer.invoices ?? []).isEmpty)
        GLTestHost.renderBothSchemes(InvoicesListScreen(customer: b.customer), container: b.container)
    }

    @Test func rendersInvoicesListWithEveryStatusRow() throws {
        let b = try bench()
        let draft = seedInvoice(b, number: "INV-LC-51", lines: [(1000, false)])
        draft.createdAt = .now.addingTimeInterval(-10 * 86_400)

        let sent = seedInvoice(b, number: "INV-LC-52", status: .sent, lines: [(2000, false)])
        sent.createdAt = .now.addingTimeInterval(-8 * 86_400)

        let partial = seedInvoice(b, number: "INV-LC-53", status: .sent, lines: [(3000, false)])
        partial.createdAt = .now.addingTimeInterval(-6 * 86_400)
        TS.pay(partial, 1200)

        let paid = seedInvoice(b, number: "INV-LC-54", status: .sent, lines: [(1500, false)])
        paid.createdAt = .now.addingTimeInterval(-4 * 86_400)
        TS.pay(paid, 1500)

        let overdue = seedInvoice(b, number: "INV-LC-55", status: .sent, lines: [(900, false)])
        overdue.createdAt = .now.addingTimeInterval(-2 * 86_400)
        overdue.dueDate = TS.day(2020, 1, 1)

        let untitled = seedInvoice(b, number: "INV-LC-56", lines: [(0, false)])
        untitled.jobTitle = ""
        b.ctx.saveChanges()

        #expect((b.customer.invoices ?? []).count == 6)
        GLTestHost.renderBothSchemes(InvoicesListScreen(customer: b.customer), container: b.container)
        GLTestHost.render(InvoicesListScreen(customer: b.customer), container: b.container,
                          scheme: .dark, typeSize: .accessibility3)
    }

    @Test func rendersAllInvoicesScreenAcrossStatuses() throws {
        let b = try bench()
        seedInvoice(b, number: "INV-LC-59", lines: [(100, false)])
        let paid = seedInvoice(b, number: "INV-LC-60", status: .sent, lines: [(100, false)])
        TS.pay(paid, 100)
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: b.container)
    }

    // =====================================================================================
    // MARK: - 4. InvoiceFormScreen
    // =====================================================================================

    @Test func rendersNewInvoiceFormForACustomer() throws {
        let b = try bench()
        GLTestHost.renderBothSchemes(InvoiceFormScreen(customer: b.customer), container: b.container)
    }

    @Test func rendersNewInvoiceFormOnAStripeConnectedBusiness() throws {
        // The "Include Pay button" section only exists when Stripe is connected.
        let b = try bench(stripeConnected: true)
        GLTestHost.render(InvoiceFormScreen(customer: b.customer), container: b.container)
    }

    @Test func rendersEditFormForAnInvoiceInEachLifecycleState() throws {
        let b = try bench()
        let draft = seedInvoice(b, number: "INV-LC-61", lines: [(1000, false)])
        let paid = seedInvoice(b, number: "INV-LC-62", status: .sent, lines: [(1000, false)])
        TS.pay(paid, 1000)
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceFormScreen(editing: draft), container: b.container)
        GLTestHost.render(InvoiceFormScreen(editing: paid), container: b.container)
    }

    @Test func rendersEditFormWithCustomPaymentTerms() throws {
        // .custom swaps the read-only due-date row for a DatePicker.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-63", lines: [(1000, false)])
        invoice.paymentTerms = .custom
        invoice.dueDate = TS.day(2026, 12, 24)
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceFormScreen(editing: invoice), container: b.container)
    }

    @Test func rendersEditFormForEveryPaymentTermsOption() throws {
        let b = try bench()
        for (index, terms) in PaymentTerms.allCases.enumerated() {
            let invoice = seedInvoice(b, number: "INV-LC-64-\(index)", lines: [(500, false)])
            invoice.paymentTerms = terms
            b.ctx.saveChanges()
            GLTestHost.render(InvoiceFormScreen(editing: invoice), container: b.container)
        }
    }

    @Test func rendersEditFormWithBothDiscountTypes() throws {
        // AdjustmentType != .none reveals the discount-value field.
        let b = try bench()
        let percentage = seedInvoice(b, number: "INV-LC-65",
                                     discountType: .percentage, discountValue: 15,
                                     lines: [(1000, false)])
        let fixed = seedInvoice(b, number: "INV-LC-66",
                                discountType: .fixed, discountValue: 200,
                                lines: [(1000, false)])
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceFormScreen(editing: percentage), container: b.container)
        GLTestHost.render(InvoiceFormScreen(editing: fixed), container: b.container)
    }

    @Test func rendersEditFormWithPerLineDiscountsAndMultipleGroups() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-67", taxRatePercent: 7.5,
                                  lines: [(1000, true), (400, false)])
        let items = invoice.allLineItems
        items[0].discountType = .percentage; items[0].discountValue = 12.5
        items[1].discountType = .fixed;      items[1].discountValue = 75
        let second = InvoiceGroup(name: "Prep", note: "Sub-floor", sortIndex: 1)
        second.invoice = invoice
        b.ctx.insert(second)
        let line = InvoiceLineItem(name: "Leveling", quantity: 120, unit: .squareFoot,
                                   unitPrice: 2, sortIndex: 0)
        line.group = second
        b.ctx.insert(line)
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(InvoiceFormScreen(editing: invoice), container: b.container)
    }

    @Test func rendersEditFormWithReadOnlyChangeOrderLines() throws {
        // Change-order lines render as a read-only row (a credit's negative price can't round-trip
        // a money field), and a change-order-linked group can't be removed.
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-68", status: .sent,
                                  lines: [(1000, false), (-250, false)])
        let group = try #require(invoice.sortedGroups.first)
        let credit = try #require(group.sortedLineItems.last)
        credit.fromChangeOrder = true
        credit.details = "Omitted backsplash"

        let order = TS.changeOrder(invoice, number: "CO-LC-8", status: .approved, applied: true,
                                   lines: [(-250, false)])
        group.changeOrder = order
        b.ctx.saveChanges()
        GLTestHost.renderBothSchemes(InvoiceFormScreen(editing: invoice), container: b.container)
    }

    @Test func rendersEditFormForAnInvoiceWithNoGroups() throws {
        // The form seeds one blank group so there is always something to type into.
        let b = try bench()
        let invoice = Invoice(number: "INV-LC-69", jobTitle: "Bare", customer: b.customer)
        b.ctx.insert(invoice)
        b.ctx.saveChanges()
        #expect(invoice.sortedGroups.isEmpty)
        GLTestHost.render(InvoiceFormScreen(editing: invoice), container: b.container)
    }

    @Test func rendersJobBilledFormCarryingScopeFromTheSourceEstimate() throws {
        let b = try bench()
        let estimate = TS.estimate(number: "EST-LC-2", taxRatePercent: 7.5,
                                   lines: [(1800, true), (600, false)])
        estimate.customer = b.customer
        estimate.terms = "Balance on completion."
        estimate.customerNotes = "Gate code 1234."
        b.ctx.insert(estimate)
        let job = ScheduledJob(title: "Carry job", estimate: estimate,
                               customer: b.customer, agreedPrice: 2400)
        b.ctx.insert(job)
        b.ctx.saveChanges()
        #expect((job.billingInvoices ?? []).isEmpty)
        GLTestHost.renderBothSchemes(InvoiceFormScreen(customer: b.customer, job: job), container: b.container)
    }

    @Test func rendersJobBilledFormCarryingScopeFromTheSourceInvoice() throws {
        let b = try bench()
        let source = seedInvoice(b, number: "INV-LC-70", status: .sent, taxRatePercent: 7.5,
                                 discountType: .percentage, discountValue: 10,
                                 lines: [(1000, true), (500, false)])
        // A change-order line on the SOURCE must be stripped of its link when carried forward.
        let sourceGroup = try #require(source.sortedGroups.first)
        let coOrder = TS.changeOrder(source, number: "CO-LC-7", status: .approved, applied: true,
                                     lines: [(100, false)])
        sourceGroup.changeOrder = coOrder
        let sourceCOLine = try #require(sourceGroup.sortedLineItems.last)
        sourceCOLine.fromChangeOrder = true

        let job = ScheduledJob(title: "Second draw", invoice: source,
                               customer: b.customer, agreedPrice: 1500)
        b.ctx.insert(job)
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceFormScreen(customer: b.customer, job: job), container: b.container)
    }

    @Test func rendersJobBilledFormWithNoCarryOnceTheJobIsAlreadyBilled() throws {
        // A second progress draw starts BLANK — re-carrying the scope would double the job total.
        let b = try bench()
        let job = ScheduledJob(title: "Already billed", customer: b.customer, agreedPrice: 5000)
        b.ctx.insert(job)
        let firstDraw = seedInvoice(b, number: "INV-LC-71", status: .sent, lines: [(2500, false)])
        firstDraw.job = job
        b.ctx.saveChanges()
        #expect((job.billingInvoices ?? []).count == 1)
        GLTestHost.render(InvoiceFormScreen(customer: b.customer, job: job), container: b.container)
    }

    @Test func rendersEditFormAtAccessibilityTypeSize() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-72", status: .sent, taxRatePercent: 7.5,
                                  discountType: .percentage, discountValue: 10,
                                  lines: [(1000, true)])
        invoice.amountDueNow = 300
        invoice.amountDueDetail = "Deposit"
        b.ctx.saveChanges()
        GLTestHost.render(InvoiceFormScreen(editing: invoice), container: b.container,
                          scheme: .dark, typeSize: .accessibility3)
    }

    // =====================================================================================
    // MARK: - 5. Applying a change order (the detail screen's "Add to invoice" action)
    // =====================================================================================

    /// The money of applying a change order belongs to CalendarJobsEstimatesCoverageTests
    /// (applyingAddAndSubtractChangeOrdersMovesTheInvoiceTotal). This suite owns the RENDER of a
    /// detail screen whose change order has already been billed, in both directions.
    @Test func rendersInvoiceDetailAfterAnAddAndACreditChangeOrderWereApplied() throws {
        let b = try bench()
        let added = seedInvoice(b, number: "INV-LC-73", status: .sent, lines: [(1000, false)])
        let addOrder = TS.changeOrder(added, number: "CO-LC-10", status: .approved,
                                      taxRatePercent: 0, applied: false, lines: [(325.50, false)])
        let credited = seedInvoice(b, number: "INV-LC-74", status: .sent, lines: [(2000, false)])
        let creditOrder = TS.changeOrder(credited, number: "CO-LC-11", status: .approved, applied: false,
                                         lines: [(-450, false)])
        b.ctx.saveChanges()
        addOrder.addItemsToInvoice(using: b.ctx)
        creditOrder.addItemsToInvoice(using: b.ctx)
        b.ctx.saveChanges()

        #expect(addOrder.appliedToInvoice && creditOrder.appliedToInvoice)
        GLTestHost.renderBothSchemes(InvoiceDetailScreen(invoice: added), container: b.container)
        GLTestHost.render(InvoiceDetailScreen(invoice: credited), container: b.container)
    }

    @Test func changeOrderCreditLargerThanTheInvoiceFloorsTheTotalAtZero() throws {
        let b = try bench()
        let invoice = seedInvoice(b, number: "INV-LC-75", status: .sent, lines: [(500, false)])
        let order = TS.changeOrder(invoice, number: "CO-LC-12", status: .approved, applied: false,
                                   lines: [(-900, false)])
        b.ctx.saveChanges()
        order.addItemsToInvoice(using: b.ctx)
        b.ctx.saveChanges()

        #expect(invoice.subtotal < 0)
        #expect(close(invoice.total, 0))
        #expect(close(invoice.balanceDue, 0))
        #expect(invoice.isPaid)          // sent + nothing owed
        GLTestHost.render(InvoiceDetailScreen(invoice: invoice), container: b.container)
    }
}
