//
//  InvoiceMoneyTests.swift
//  GLSmallBusinessTests
//
//  Invoice-level money and status logic — everything the invoice screens print that sits ON TOP
//  of EstimateTotals (which MoneyMathTests owns): line items that floor or vanish, payments and the
//  balance, the isPaid / isOverdue / displayStatus boundaries, paid-through ordering, change-order
//  rollups and full-rate change-order tax, the detail screen's line/group helpers, payment terms
//  and due dates, numbering, recipients, and estimate → invoice conversion.
//
//  Nothing here renders, so the suite runs in parallel; the rendering variants of these states
//  live in InvoiceLifecycleCoverageTests, which is serialized for the reasons in its header.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct InvoiceMoneyTests {

    // MARK: - Line items the totals must survive

    @Test func invoiceWithNoLinesAtAllIsZero() {
        // groups == nil is the on-disk state of a brand-new invoice.
        let invoice = Invoice(number: "INV-LC-M1")
        #expect(invoice.allLineItems.isEmpty)
        #expect(close(invoice.subtotal, 0))
        #expect(close(invoice.taxAmount, 0))
        #expect(close(invoice.total, 0))
        #expect(close(invoice.balanceDue, 0))
        #expect(close(invoice.currentAmountDue, 0))
    }

    @Test func veryLargeQuantityTimesPriceStaysFinite() {
        let invoice = Invoice(number: "INV-LC-M11")
        let group = InvoiceGroup(name: "Big")
        group.invoice = invoice
        let item = InvoiceLineItem(name: "Bulk", quantity: 1_000_000, unit: .squareFoot,
                                   unitPrice: 1_000, sortIndex: 0)
        item.group = group
        group.lineItems = [item]
        invoice.groups = [group]
        #expect(invoice.total.isFinite)
        #expect(close(invoice.total, 1_000_000_000))
    }

    @Test func negativeUnitPriceOnOriginalWorkFloorsTheLineAtZero() throws {
        // Only change-order lines are allowed to go negative; original work floors, so the credit
        // contributes nothing to the invoice.
        let invoice = TS.invoice(lines: [(1000, false), (-400, false)])
        let credit = try #require(invoice.allLineItems.last)
        #expect(close(credit.lineTotal, 0))
        #expect(close(invoice.subtotal, 1000))
        #expect(close(invoice.total, 1000))
    }

    @Test func zeroQuantityLineContributesNothing() {
        let invoice = Invoice(number: "INV-LC-M12")
        let group = InvoiceGroup(name: "Zero qty")
        group.invoice = invoice
        let item = InvoiceLineItem(name: "Nothing", quantity: 0, unit: .squareFoot,
                                   unitPrice: 12.5, isTaxable: true, sortIndex: 0)
        item.group = group
        group.lineItems = [item]
        invoice.groups = [group]
        invoice.taxRatePercent = 7.5
        #expect(close(item.grossLineTotal, 0))
        #expect(close(invoice.total, 0))
    }

    // MARK: - Payments + balance

    @Test func balanceDueNeverGoesNegativeOnOverpayment() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 2500)
        #expect(close(invoice.amountPaid, 2500))
        #expect(close(invoice.balanceDue, 0))
        #expect(invoice.isPaid)
    }

    @Test func negativePaymentRaisesTheBalanceAboveTheTotal() {
        // DOCUMENTED BEHAVIOUR: nothing rejects a negative payment amount at the model level, so a
        // -$200 entry makes the invoice owe MORE than it is worth. (The Record-payment sheet blocks
        // this at the UI, but a CloudKit-synced or legacy record isn't re-validated.)
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, -200)
        #expect(close(invoice.amountPaid, -200))
        #expect(close(invoice.balanceDue, 1200))
        #expect(invoice.balanceDue > invoice.total)
        #expect(!invoice.isPaid)
        #expect(!invoice.isPartiallyPaid)   // amountPaid > 0 is false
    }

    @Test func mixedSignPaymentsNetOutCorrectly() {
        // A refund recorded as a negative entry alongside real payments.
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 600, date: TS.day(2026, 1, 1))
        TS.pay(invoice, -100, date: TS.day(2026, 1, 15))   // partial refund
        TS.pay(invoice, 500, date: TS.day(2026, 2, 1))
        #expect(close(invoice.amountPaid, 1000))
        #expect(close(invoice.balanceDue, 0))
        #expect(invoice.isPaid)
    }

    @Test func isPaidBoundarySitsAtHalfACent() {
        let almost = TS.invoice(lines: [(1000, false)])
        TS.pay(almost, 999.99)
        #expect(close(almost.balanceDue, 0.01))
        #expect(!almost.isPaid)
        #expect(almost.isPartiallyPaid)

        let inside = TS.invoice(lines: [(1000, false)])
        TS.pay(inside, 999.996)      // 0.004 left — inside the epsilon
        #expect(inside.isPaid)
        #expect(!inside.isPartiallyPaid)
    }

    @Test func hasAmountDueRequestBoundarySitsAtHalfACentAndCapsAtTheBalance() {
        let invoice = TS.invoice(lines: [(1000, false)])
        #expect(!invoice.hasAmountDueRequest)      // nothing requested → the whole balance is due
        #expect(close(invoice.currentAmountDue, 1000))
        invoice.amountDueNow = 0.005
        #expect(!invoice.hasAmountDueRequest)      // strictly greater than
        invoice.amountDueNow = 0.006
        #expect(invoice.hasAmountDueRequest)
        invoice.amountDueNow = 5000                // asked for more than the invoice is worth
        #expect(invoice.hasAmountDueRequest)
        #expect(close(invoice.currentAmountDue, 1000))   // capped, never the raw request
        invoice.amountDueNow = -50                 // a negative request is ignored
        #expect(!invoice.hasAmountDueRequest)
        #expect(close(invoice.currentAmountDue, 1000))
    }

    // MARK: - isOverdue / displayStatus

    @Test func overdueRequiresSentStatusAndAPastDueDate() {
        let draft = TS.invoice(status: .draft, lines: [(1000, false)])
        draft.dueDate = TS.day(2020, 1, 1)
        #expect(!draft.isOverdue)                  // drafts are never overdue
        #expect(draft.displayStatus == "Draft")

        let future = TS.invoice(status: .sent, lines: [(1000, false)])
        future.dueDate = .now.addingTimeInterval(86_400)
        #expect(!future.isOverdue)

        let past = TS.invoice(status: .sent, lines: [(1000, false)])
        past.dueDate = .now.addingTimeInterval(-1)
        #expect(past.isOverdue)
    }

    @Test func paidInvoiceIsNeverOverdue() {
        let invoice = TS.invoice(status: .sent, lines: [(1000, false)])
        invoice.dueDate = TS.day(2019, 6, 1)
        TS.pay(invoice, 1000)
        #expect(!invoice.isOverdue)
        #expect(invoice.displayStatus == "Paid")
    }

    @Test func displayStatusPrecedenceIsPaidThenOverdueThenPartial() {
        let base = { () -> Invoice in
            let invoice = TS.invoice(status: .sent, lines: [(1000, false)])
            invoice.dueDate = TS.day(2020, 1, 1)
            return invoice
        }
        let overdueOnly = base()
        #expect(overdueOnly.displayStatus == "Overdue")

        let overdueAndPartial = base()
        TS.pay(overdueAndPartial, 100)
        #expect(overdueAndPartial.displayStatus == "Overdue")

        let settled = base()
        TS.pay(settled, 1000)
        #expect(settled.displayStatus == "Paid")

        let partialNotDue = TS.invoice(status: .sent, lines: [(1000, false)])
        partialNotDue.dueDate = .now.addingTimeInterval(86_400)
        TS.pay(partialNotDue, 100)
        #expect(partialNotDue.displayStatus == "Partially Paid")
    }

    // MARK: - paidThrough / remainingAfter

    @Test func paidThroughOrdersByDateNotInsertionOrder() {
        let invoice = TS.invoice(lines: [(1000, false)])
        let late = TS.pay(invoice, 300, date: TS.day(2026, 3, 1))
        let early = TS.pay(invoice, 200, date: TS.day(2026, 1, 1))
        #expect(close(invoice.paidThrough(early), 200))
        #expect(close(invoice.paidThrough(late), 500))
        #expect(close(invoice.remainingAfter(early), 800))
        #expect(close(invoice.remainingAfter(late), 500))
    }

    @Test func remainingAfterNeverGoesNegative() {
        let invoice = TS.invoice(lines: [(1000, false)])
        let over = TS.pay(invoice, 1500)
        #expect(close(invoice.remainingAfter(over), 0))
    }

    @Test func paidThroughForAPaymentOnAnotherInvoiceReturnsTheWholeSum() {
        // DOCUMENTED BEHAVIOUR: the loop breaks on an id match, so a foreign payment falls through
        // and reports the full total paid. Callers only ever pass one of the invoice's own payments.
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 400)
        let foreign = InvoicePayment(amount: 999, date: .now, method: .cash)
        #expect(close(invoice.paidThrough(foreign), 400))
        #expect(close(invoice.remainingAfter(foreign), 600))
    }

    // MARK: - Change orders

    @Test func changeOrderTotalsRollUpOnlyApprovedUnappliedOrders() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.changeOrder(invoice, number: "CO-A", status: .pending, lines: [(500, false)])
        TS.changeOrder(invoice, number: "CO-B", status: .declined, lines: [(500, false)])
        TS.changeOrder(invoice, number: "CO-C", status: .approved, applied: true, lines: [(500, false)])
        TS.changeOrder(invoice, number: "CO-D", status: .approved, applied: false, lines: [(250, false)])
        #expect(close(invoice.approvedChangeOrderTotal, 250))
        #expect(close(invoice.revisedTotal, 1250))
        #expect(close(invoice.balanceDue, 1000))   // an unapplied CO is informational, never billed
    }

    @Test func approvedCreditChangeOrderLowersTheRevisedTotal() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.changeOrder(invoice, number: "CO-E", status: .approved, applied: false, lines: [(-300, false)])
        #expect(close(invoice.approvedChangeOrderTotal, -300))
        #expect(close(invoice.revisedTotal, 700))
        #expect(close(invoice.balanceDue, 1000))   // still not billed until it's added
    }

    @Test func changeOrderTaxIsAddedAtTheFullRate() {
        let invoice = TS.invoice(taxRatePercent: 10, discountType: .percentage, discountValue: 100,
                                 lines: [(1000, true), (500, true)])
        let items = invoice.allLineItems
        items[1].fromChangeOrder = true
        // Original work is 100% discounted → base total 0. The CO line is untouched by the discount.
        #expect(close(invoice.discountAmount, 1000))
        #expect(close(invoice.taxAmount, 50))
        #expect(close(invoice.total, 550))
    }

    // MARK: - Detail screen line/group helpers

    @Test func displayLineTotalAndGroupSubtotalOnAMixedGroup() throws {
        let invoice = TS.invoice(lines: [(1000, false), (250, false), (-150, false)])
        let group = try #require(invoice.sortedGroups.first)
        let items = group.sortedLineItems
        items[1].fromChangeOrder = true       // positive change-order add
        items[2].fromChangeOrder = true       // credit
        items[0].discountType = .percentage
        items[0].discountValue = 10           // original work with a per-line discount

        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(screen.displayLineTotal(items[0]), 900))
        #expect(close(screen.displayLineTotal(items[1]), 250))
        #expect(close(screen.displayLineTotal(items[2]), -150))
        #expect(close(screen.groupSubtotal(group), 1000))
        #expect(close(invoice.subtotal, 1000))   // lines and totals card reconcile
    }

    @Test func groupSubtotalOfAnEmptyGroupIsZero() {
        let invoice = TS.invoice(lines: [(100, false)])
        let empty = InvoiceGroup(name: "Empty")
        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(close(screen.groupSubtotal(empty), 0))
    }

    // MARK: - Payment terms + due dates

    @Test func paymentTermsProduceTheExpectedDueDates() {
        let start = TS.day(2026, 3, 10)
        #expect(PaymentTerms.dueOnReceipt.dueDate(from: start) == start)
        #expect(PaymentTerms.net15.dueDate(from: start) == TS.day(2026, 3, 25))
        #expect(PaymentTerms.net30.dueDate(from: start) == TS.day(2026, 4, 9))
        #expect(PaymentTerms.custom.dueDate(from: start) == nil)
        #expect(PaymentTerms.custom.days == nil)
    }

    @Test func net30AcrossAMonthEndAndALeapDay() {
        #expect(PaymentTerms.net30.dueDate(from: TS.day(2026, 1, 31)) == TS.day(2026, 3, 2))
        // 2028 is a leap year: Feb 1 + 30 days lands on Mar 2 (29 days in February).
        #expect(PaymentTerms.net30.dueDate(from: TS.day(2028, 2, 1)) == TS.day(2028, 3, 2))
        #expect(PaymentTerms.net15.dueDate(from: TS.day(2026, 12, 25)) == TS.day(2027, 1, 9))
    }

    @Test func invoiceInitDerivesTheDueDateFromTheTerms() {
        let created = TS.day(2026, 5, 1)
        let net15 = Invoice(number: "INV-LC-M2", createdAt: created, paymentTerms: .net15)
        #expect(net15.dueDate == TS.day(2026, 5, 16))

        // .custom has no derivable date, so it falls back to the creation date.
        let custom = Invoice(number: "INV-LC-M3", createdAt: created, paymentTerms: .custom)
        #expect(custom.dueDate == created)

        // An explicit due date always wins.
        let explicitDue = Invoice(number: "INV-LC-M4", createdAt: created,
                                  paymentTerms: .net30, dueDate: TS.day(2026, 9, 9))
        #expect(explicitDue.dueDate == TS.day(2026, 9, 9))
    }

    @Test func everyPaymentTermsCaseHasALabel() {
        for terms in PaymentTerms.allCases {
            #expect(!terms.label.isEmpty)
            #expect(PaymentTerms(rawValue: terms.rawValue) == terms)
        }
        #expect(PaymentTerms.allCases.count == 4)
    }

    @Test func everyInvoiceStatusCaseHasALabel() {
        for status in InvoiceStatus.allCases {
            #expect(!status.label.isEmpty)
            #expect(InvoiceStatus(rawValue: status.rawValue) == status)
        }
        #expect(InvoiceStatus.allCases.count == 2)
    }

    // MARK: - Recipients

    @Test func recipientsPreferTheLiveCustomerOverTheSnapshot() {
        let customer = Customer(firstName: "Dana", lastName: "Lee",
                                email: "new@example.com", phoneNumber: "(850) 555-0000")
        let invoice = TS.invoice(lines: [(100, false)])
        invoice.customerEmail = "old@example.com"
        invoice.customerPhone = "(850) 555-9999"
        #expect(invoice.recipientEmail == "old@example.com")   // no live customer yet
        invoice.customer = customer
        #expect(invoice.recipientEmail == "new@example.com")
        #expect(invoice.recipientPhone == "(850) 555-0000")

        // A blank live value falls back to the snapshot rather than sending to nobody.
        customer.email = "   "
        customer.phoneNumber = ""
        #expect(invoice.recipientEmail == "old@example.com")
        #expect(invoice.recipientPhone == "(850) 555-9999")
    }

    // MARK: - Estimate → invoice conversion

    @Test func conversionCarriesLinesTaxDiscountAndDepositButNoPayments() throws {
        let ctx = try TestStore.makeContainer().mainContext
        let estimate = TS.estimate(number: "EST-LC-3", taxRatePercent: 7.5,
                                   lines: [(1000, true), (500, false)])
        estimate.customerFirstName = "Sofia"
        estimate.customerLastName = "Nguyen"
        estimate.customerBusinessName = "Nguyen PM"
        estimate.serviceAddress = Address(street1: "305 John Knox Rd", city: "Miami",
                                          state: "FL", postalCode: "32303")
        estimate.discountType = .percentage
        estimate.discountValue = 10
        estimate.depositType = .fixed
        estimate.depositValue = 400
        estimate.terms = "Balance on completion."
        estimate.customerNotes = "Materials on site."

        let invoice = Invoice.make(from: estimate, number: "INV-LC-M5", in: ctx)
        #expect(invoice.number == "INV-LC-M5")
        #expect(invoice.sourceEstimateNumber == "EST-LC-3")
        #expect(invoice.customerDisplayName == "Sofia Nguyen")
        #expect(invoice.serviceAddress.street1 == "305 John Knox Rd")
        #expect(close(invoice.taxRatePercent, 7.5))
        #expect(invoice.discountType == .percentage)
        #expect(close(invoice.total, estimate.total))
        #expect(invoice.allLineItems.count == 2)
        #expect(invoice.terms == "Balance on completion.")
        #expect(close(invoice.amountDueNow, 400))
        #expect(invoice.amountDueDetail == "Deposit to start")
        #expect((invoice.payments ?? []).isEmpty)        // a deposit is REQUESTED, never pre-paid
        #expect(close(invoice.balanceDue, invoice.total))
    }

    @Test func conversionOfADepositFreeEstimateLeavesNoAmountDueRequest() throws {
        let ctx = try TestStore.makeContainer().mainContext
        let estimate = TS.estimate(number: "EST-LC-4", lines: [(1000, false)])
        let invoice = Invoice.make(from: estimate, number: "INV-LC-M6", in: ctx)
        #expect(close(estimate.depositAmount, 0))
        #expect(!invoice.hasAmountDueRequest)
        #expect(invoice.amountDueDetail.isEmpty)
        #expect(close(invoice.currentAmountDue, invoice.balanceDue))
    }

    @Test func conversionOfAnEmptyEstimateProducesAZeroInvoice() throws {
        let ctx = try TestStore.makeContainer().mainContext
        let estimate = Estimate(number: "EST-LC-5", jobTitle: "Nothing agreed yet")
        ctx.insert(estimate)
        let invoice = Invoice.make(from: estimate, number: "INV-LC-M7", in: ctx)
        #expect(invoice.allLineItems.isEmpty)
        #expect(close(invoice.total, 0))
        #expect(!invoice.hasAmountDueRequest)
    }

    @Test func conversionSeedsThePayLinkChoiceFromTheBusinessDefault() throws {
        let ctx = try TestStore.makeContainer().mainContext
        let profile = BusinessProfile()
        profile.payLinkDefaultOn = false
        ctx.insert(profile)
        ctx.saveChanges()

        let estimate = TS.estimate(number: "EST-LC-6", lines: [(1000, false)], in: ctx)
        let off = Invoice.make(from: estimate, number: "INV-LC-M8", in: ctx)
        #expect(!off.includePayLink)

        profile.payLinkDefaultOn = true
        ctx.saveChanges()
        let on = Invoice.make(from: estimate, number: "INV-LC-M9", in: ctx)
        #expect(on.includePayLink)
    }

    @Test func changeOrderLinesIgnorePerLineAndWholeDocumentDiscounts() {
        let inv = TS.invoice(taxRatePercent: 10, discountType: .percentage, discountValue: 20,
                             lines: [(1000, true)])
        let group = inv.sortedGroups[0]
        let co = InvoiceLineItem(name: "CO", quantity: 1, unitPrice: 500, isTaxable: true, sortIndex: 1)
        co.fromChangeOrder = true
        co.group = group
        group.lineItems = (group.lineItems ?? []) + [co]
        #expect(close(inv.total, 1430))

        co.fromChangeOrder = false
        #expect(close(inv.total, 1320))
        co.fromChangeOrder = true

        let original = group.sortedLineItems.first { !$0.fromChangeOrder }!
        original.discountType = .fixed; original.discountValue = 100
        #expect(close(inv.total, 1342))
    }

    @Test func invoiceMadeFromEstimateKeepsPerLineDiscount() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let est = Estimate(number: "EST-1")
        ctx.insert(est)
        let g = EstimateGroup(name: "G"); g.estimate = est; ctx.insert(g)
        let item = EstimateLineItem(name: "X", quantity: 1, unitPrice: 100, sortIndex: 0,
                                    discountType: .percentage, discountValue: 25)
        item.group = g; ctx.insert(item)

        let inv = Invoice.make(from: est, number: "INV-1", in: ctx)
        let invItem = inv.sortedGroups.first?.sortedLineItems.first
        #expect(invItem?.discountType == .percentage)
        #expect(close(invItem?.discountValue ?? -1, 25))
        #expect(close(invItem?.lineTotal ?? -1, 75))
    }
}
