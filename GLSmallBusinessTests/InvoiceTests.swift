//
//  InvoiceTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct InvoiceTests {
    @Test func totalsFromLineItems() {
        let inv = TS.invoice(taxRatePercent: 10, lines: [(100, true), (100, false)])
        #expect(close(inv.subtotal, 200))
        #expect(close(inv.taxAmount, 10))
        #expect(close(inv.total, 210))
    }

    @Test func discountAppliesToTotal() {
        let inv = TS.invoice(discountType: .percentage, discountValue: 20, lines: [(2400, false)])
        #expect(close(inv.discountAmount, 480))
        #expect(close(inv.total, 1920))
    }

    @Test func paymentsReduceBalance() {
        let inv = TS.invoice(lines: [(1000, false)])
        TS.pay(inv, 300)
        TS.pay(inv, 200)
        #expect(close(inv.amountPaid, 500))
        #expect(close(inv.balanceDue, 500))
        #expect(inv.isPartiallyPaid)
        #expect(!inv.isPaid)
    }

    @Test func fullPaymentMarksPaid() {
        let inv = TS.invoice(lines: [(1000, false)])
        TS.pay(inv, 1000)
        #expect(inv.isPaid)
        #expect(!inv.isPartiallyPaid)
        #expect(inv.displayStatus == "Paid")
        #expect(close(inv.balanceDue, 0))
    }

    @Test func paidThroughIsCumulativeInOrder() {
        let inv = TS.invoice(lines: [(1000, false)])
        let p1 = TS.pay(inv, 200, date: TS.day(2026, 1, 1))
        let p2 = TS.pay(inv, 300, date: TS.day(2026, 2, 1))
        #expect(close(inv.paidThrough(p1), 200))
        #expect(close(inv.paidThrough(p2), 500))
        #expect(close(inv.remainingAfter(p1), 800))
        #expect(close(inv.remainingAfter(p2), 500))
    }

    @Test func overdueWhenSentAndPastDue() {
        let inv = TS.invoice(status: .sent, lines: [(1000, false)])
        inv.dueDate = TS.day(2020, 1, 1)
        #expect(inv.isOverdue)
        #expect(inv.displayStatus == "Overdue")
    }

    @Test func notOverdueWhenPaid() {
        let inv = TS.invoice(status: .sent, lines: [(1000, false)])
        inv.dueDate = TS.day(2020, 1, 1)
        TS.pay(inv, 1000)
        #expect(!inv.isOverdue)
    }

    @Test func amountDueRequestCapsAtBalance() {
        let inv = TS.invoice(lines: [(1000, false)])
        #expect(!inv.hasAmountDueRequest)
        #expect(close(inv.currentAmountDue, 1000))
        inv.amountDueNow = 5000
        #expect(inv.hasAmountDueRequest)
        #expect(close(inv.currentAmountDue, 1000))
    }

    // MARK: - Change-order rollup (the revisedTotal double-count fix)

    @Test func approvedNotAppliedChangeOrderRaisesRevisedTotal() {
        let inv = TS.invoice(lines: [(1000, false)])
        TS.changeOrder(inv, status: .approved, applied: false, lines: [(100, false)])
        #expect(close(inv.approvedChangeOrderTotal, 100))
        #expect(close(inv.revisedTotal, 1100))
    }

    @Test func appliedChangeOrderIsNotDoubleCounted() {
        let inv = TS.invoice(lines: [(1000, false)])
        TS.changeOrder(inv, status: .approved, applied: true, lines: [(100, false)])
        #expect(close(inv.approvedChangeOrderTotal, 0))
        #expect(close(inv.revisedTotal, inv.total))
    }

    @Test func pendingChangeOrderIsNotCounted() {
        let inv = TS.invoice(lines: [(1000, false)])
        TS.changeOrder(inv, status: .pending, lines: [(100, false)])
        #expect(close(inv.approvedChangeOrderTotal, 0))
    }

    @Test func nextNumberIncrementsHighest() {
        #expect(Invoice.nextNumber(after: []) == "INV-0001")
        let a = Invoice(number: "INV-0007")
        let b = Invoice(number: "INV-0003")
        #expect(Invoice.nextNumber(after: [a, b]) == "INV-0008")
    }
}
