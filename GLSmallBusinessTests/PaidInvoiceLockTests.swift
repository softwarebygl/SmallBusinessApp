//
//  PaidInvoiceLockTests.swift
//  GLSmallBusinessTests
//
//  Pins the app half of the paid-invoice money lock (UIComponents/PaidInvoiceLock.swift), added
//  for the owner ruling of 2026-08-23: once an invoice's derived state is paid, the sync Worker
//  refuses DELETES of the invoice, its groups, and its line items as well as money edits
//  (gl-business-api sync-manifest.json / src/merge.ts, `paid_locked`).
//
//  What these tests are for: the app and the server must answer "is this locked?" the same way.
//  If the app permits a delete the server refuses, the record is gone here and alive there —
//  silent divergence, the exact bug class the last QA round cleared out. So the things worth
//  pinning are (a) `isMoneyLocked` is exactly the derived paid verdict, in every state including
//  the awkward ones, (b) the change-order guard fires ONLY where an invoice group would
//  actually be deleted — a lock that always fires is as broken as one that never does — and
//  (c) `Customer.hasPaidInvoice`, the same rule one level up (the Worker refuses a customer
//  delete whose cascade reaches a paid invoice).
//
//  The last section pins the other side of the line: what the lock must NOT block. The milestone
//  request (`amountDueNow`) is `paid_lock_exempt`, so the payment that settles an invoice still
//  draws it down — a paid invoice that keeps asking for money is the bug the exemption exists to
//  prevent, and the arithmetic showing an exempt write can never charge anyone is here too.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct PaidInvoiceLockTests {

    // MARK: - Invoice.isMoneyLocked mirrors the derived paid verdict

    @Test func unpaidInvoiceIsNotLocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        #expect(!invoice.isMoneyLocked)
    }

    @Test func partiallyPaidInvoiceIsNotLocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 400)
        #expect(close(invoice.balanceDue, 600))
        #expect(!invoice.isMoneyLocked, "money still owed — editing and deleting stay open")
    }

    @Test func fullyPaidInvoiceIsLocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 1000)
        #expect(invoice.isMoneyLocked)
    }

    @Test func overpaidInvoiceIsLocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 1200)
        #expect(invoice.isMoneyLocked, "an overpayment is settled money too")
    }

    @Test func aBalanceInsideTheHalfCentEpsilonIsLocked() {
        // The server's money.ts compares `balanceDue <= 0.005` on the same formula. A tenth of a
        // cent left over is float noise, not an amount owed, and both halves must agree — or the
        // app permits a delete the server refuses over a rounding artifact.
        let invoice = TS.invoice(lines: [(1000, false)])
        TS.pay(invoice, 999.999)
        #expect(invoice.isMoneyLocked)
    }

    @Test func zeroTotalDraftIsNotLockedButAZeroTotalSentInvoiceIs() {
        // The comped-invoice clause, copied verbatim on both sides: a brand-new $0 DRAFT is not
        // "paid", but a $0 invoice that has been SENT reads Paid rather than sitting unpaid
        // forever. The lock follows it exactly, whatever one thinks of the clause itself.
        let draft = TS.invoice(status: .draft, lines: [(0, false)])
        #expect(!draft.isMoneyLocked)

        let sent = TS.invoice(status: .sent, lines: [(0, false)])
        #expect(sent.isMoneyLocked)
    }

    @Test func lockIsExactlyTheDerivedPaidVerdictInEveryState() {
        // One assertion for the whole contract: the app must never diverge from `isPaid`, because
        // `isPaid` is the formula the server reimplements. If someone widens or narrows the lock,
        // this fails before the two halves can disagree in a customer's hands.
        let cases: [(String, Invoice)] = [
            ("unpaid", TS.invoice(lines: [(1000, false)])),
            ("partly paid", { let i = TS.invoice(lines: [(1000, false)]); TS.pay(i, 400); return i }()),
            ("paid", { let i = TS.invoice(lines: [(1000, false)]); TS.pay(i, 1000); return i }()),
            ("overpaid", { let i = TS.invoice(lines: [(1000, false)]); TS.pay(i, 1200); return i }()),
            ("zero draft", TS.invoice(status: .draft, lines: [(0, false)])),
            ("zero sent", TS.invoice(status: .sent, lines: [(0, false)])),
            ("taxed and discounted, paid in full", {
                let i = TS.invoice(taxRatePercent: 8, discountType: .percentage, discountValue: 10,
                                   lines: [(1000, true)])
                TS.pay(i, i.total)
                return i
            }()),
        ]
        for (name, invoice) in cases {
            #expect(invoice.isMoneyLocked == invoice.isPaid, "\(name): lock drifted from the paid verdict")
        }
        // Guard against a vacuous sweep: the table must actually contain both answers.
        #expect(cases.contains { $0.1.isMoneyLocked })
        #expect(cases.contains { !$0.1.isMoneyLocked })
    }

    // MARK: - The reason deletes had to be locked at all

    @Test func removingALineMovesTheTotalAsFarAsRepricingItToZero() {
        // The whole argument for the ruling, as arithmetic: the paid lock already refused
        // re-pricing a line to 0, while deleting that line outright moved the total by the exact
        // same $500 and sailed through. Either both are refused or the lock guards only the
        // polite route.
        let repriced = TS.invoice(lines: [(500, false), (500, false)])
        #expect(close(repriced.total, 1000))
        repriced.sortedGroups[0].sortedLineItems[1].unitPrice = 0
        #expect(close(repriced.total, 500), "the edit the lock has always refused")

        let deleted = TS.invoice(lines: [(500, false), (500, false)])
        let group = deleted.sortedGroups[0]
        let kept = group.sortedLineItems[0]
        group.sortedLineItems[1].group = nil   // detach both ways so no inverse can restore it
        group.lineItems = [kept]
        #expect(close(deleted.total, 500), "the delete that used to be allowed — same $500 either way")
    }

    // MARK: - ChangeOrder.isBilledToLockedInvoice

    @Test func appliedChangeOrderOnAPaidInvoiceIsBlocked() {
        // Deleting (or re-syncing) an APPLIED order deletes the InvoiceGroup it pushed onto the
        // invoice — a delete inside a paid invoice, which the server refuses.
        let invoice = TS.invoice(lines: [(1000, false)])
        let order = TS.changeOrder(invoice, status: .approved, applied: true)
        TS.pay(invoice, invoice.total)
        #expect(invoice.isMoneyLocked)
        #expect(order.isBilledToLockedInvoice)
    }

    @Test func unappliedChangeOrderOnAPaidInvoiceStaysDeletable() {
        // It owns nothing on the invoice: removeItemsFromInvoice / resyncInvoiceItems both no-op,
        // so nothing inside the paid invoice is touched and the server would accept the delete.
        // Blocking it would refuse work the server permits — the divergence in the other
        // direction, and just as wrong.
        let invoice = TS.invoice(lines: [(1000, false)])
        let order = TS.changeOrder(invoice, status: .pending, applied: false)
        TS.pay(invoice, invoice.total)
        #expect(invoice.isMoneyLocked)
        #expect(!order.isBilledToLockedInvoice)
    }

    @Test func appliedChangeOrderOnAnUnpaidInvoiceIsNotBlocked() {
        let invoice = TS.invoice(lines: [(1000, false)])
        let order = TS.changeOrder(invoice, status: .approved, applied: true)
        TS.pay(invoice, 100)
        #expect(!invoice.isMoneyLocked)
        #expect(!order.isBilledToLockedInvoice)
    }

    // MARK: - Customer.hasPaidInvoice — the lock one level up
    //
    // Owner ruling, 2026-08-23: deleting a CUSTOMER cascades to their invoices, and for one day
    // that cascade carried paid ones — with their InvoicePayments — into the grave that deleting
    // the invoice directly is refused for. The Worker now refuses that delete too
    // (gl-business-api/src/sync.ts `paidInvoiceInSubtree`, reason `paid_locked`), so the app has
    // to block the same three gestures or the customer is gone here and alive there.

    @Test func customerWithAPaidInvoiceIsBlockedFromDeletion() {
        let customer = Customer(firstName: "Rosa", lastName: "Alvarez")
        let paid = TS.invoice(number: "INV-PL-1", lines: [(1000, false)])
        paid.customer = customer
        customer.invoices = [paid]
        TS.pay(paid, 1000)
        #expect(paid.isMoneyLocked)
        #expect(customer.hasPaidInvoice)
    }

    @Test func customerWithOnlyUnpaidInvoicesStaysDeletable() {
        // A lock that fires on every customer is as broken as one that never does: nothing here
        // is settled, so the server accepts the cascade and blocking it would refuse work the
        // server permits — the divergence in the other direction.
        let customer = Customer(firstName: "Dana", lastName: "Reyes")
        let open = TS.invoice(number: "INV-PL-2", lines: [(1000, false)])
        let partly = TS.invoice(number: "INV-PL-3", lines: [(500, false)])
        for invoice in [open, partly] { invoice.customer = customer }
        customer.invoices = [open, partly]
        TS.pay(partly, 200)
        #expect(!customer.hasPaidInvoice)
    }

    @Test func customerWithNoInvoicesStaysDeletable() {
        // A brand-new lead: the relationship has never been materialized, so this is the nil path
        // through `hasPaidInvoice` rather than the empty-array one. Reading it must not throw and
        // must not block — a customer you just typed in by mistake stays deletable.
        let customer = Customer(firstName: "New", lastName: "Lead")
        #expect((customer.invoices ?? []).isEmpty)
        #expect(!customer.hasPaidInvoice)
    }

    @Test func oneSettledInvoiceAmongManyIsEnoughToBlock() {
        // The block is ANY, not ALL: the cascade takes every invoice, so one settled invoice in a
        // long history is exactly as fatal as a customer whose every invoice is paid.
        let customer = Customer(firstName: "Long", lastName: "History")
        let invoices = (1...4).map { TS.invoice(number: "INV-PL-1\($0)", lines: [(400, false)]) }
        for invoice in invoices { invoice.customer = customer }
        customer.invoices = invoices
        #expect(!customer.hasPaidInvoice)
        TS.pay(invoices[2], 400)
        #expect(customer.hasPaidInvoice)
    }

    // MARK: - The drawdown the lock must NOT block

    @Test func theSettlingPaymentStillDrawsTheRequestDownToZero() {
        // The payment that pays an invoice off is exactly when a stale milestone request is worst,
        // and it is the one the server used to refuse (amountDueNow is protected, and the invoice
        // becomes derived-paid the moment the payment lands). It is `paid_lock_exempt` now —
        // a REQUEST for money is not a record of money collected — so the app keeps writing it.
        let invoice = TS.invoice(lines: [(1000, false)])
        invoice.amountDueNow = 1000
        invoice.amountDueDetail = "Balance on completion"
        TS.pay(invoice, 1000)
        invoice.drawDownAmountDueRequest(by: 1000)
        #expect(invoice.isMoneyLocked, "the invoice really is settled — this is the locked case")
        #expect(close(invoice.amountDueNow, 0))
        #expect(invoice.amountDueDetail.isEmpty, "an empty request keeps no label")
        #expect(!invoice.hasAmountDueRequest)
    }

    @Test func aPartialDrawdownKeepsTheRemainderAndItsLabel() {
        let invoice = TS.invoice(lines: [(1000, false)])
        invoice.amountDueNow = 600
        invoice.amountDueDetail = "50% deposit"
        TS.pay(invoice, 250)
        invoice.drawDownAmountDueRequest(by: 250)
        #expect(close(invoice.amountDueNow, 350))
        #expect(invoice.amountDueDetail == "50% deposit", "money is still being asked for")
    }

    @Test func drawdownFloorsAtZeroAndNoOpsWithNoRequestOpen() {
        // An overpayment must not drive the request negative (a negative request would read as
        // "no request" by the epsilon and then print as a credit), and an invoice asking for the
        // full balance has nothing to draw down — the write must not happen at all.
        let over = TS.invoice(lines: [(1000, false)])
        over.amountDueNow = 400
        over.drawDownAmountDueRequest(by: 900)
        #expect(close(over.amountDueNow, 0))

        let noRequest = TS.invoice(lines: [(1000, false)])
        noRequest.amountDueDetail = "left over from an older milestone"
        noRequest.drawDownAmountDueRequest(by: 500)
        #expect(close(noRequest.amountDueNow, 0))
        #expect(noRequest.amountDueDetail == "left over from an older milestone",
                "no request open means no write — not even to the label")
    }

    @Test func aPaidInvoiceNeverAsksForMoneyEvenWithAStaleRequest() {
        // Why the exemption cannot move a dollar, as arithmetic: every surface (detail screen,
        // PDF, message, pay-link amount) reads `currentAmountDue`, which is capped at the balance.
        // A stale request on a settled invoice therefore asks for exactly nothing.
        let invoice = TS.invoice(lines: [(1000, false)])
        invoice.amountDueNow = 5000
        TS.pay(invoice, 1000)
        #expect(invoice.isMoneyLocked)
        #expect(close(invoice.currentAmountDue, 0))
    }

    @Test func changeOrderWithNoInvoiceIsNotBlocked() {
        // A detached order (its invoice deleted out from under it on another device) must not
        // read as locked — there is no invoice left whose money could be settled.
        let order = ChangeOrder(number: "CO-0009", title: "Orphan", taxRatePercent: 0)
        order.appliedToInvoice = true
        #expect(order.invoice == nil)
        #expect(!order.isBilledToLockedInvoice)
    }
}
