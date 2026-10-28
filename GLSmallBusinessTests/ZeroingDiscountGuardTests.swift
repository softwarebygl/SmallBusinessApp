//
//  ZeroingDiscountGuardTests.swift
//  GLSmallBusinessTests
//
//  The pre-save confirmation that stops a mistyped whole-document discount from creating an
//  invoice nobody can fix.
//
//  What the guard has to get right is not one condition but the SEPARATION between four
//  look-alike documents that all end at $0 or all carry a discount: the typo (fires), the
//  ordinary discount (silent), the deliberately comped job (silent), and no discount at all
//  (silent). A guard that over-fires is worse than none — people learn to tap through it, and
//  the one time it matters they tap through that too. So every negative case here is as
//  load-bearing as the positive one.
//
//  The last suite pins the guard to the actual trap rather than to an isolated boolean: the
//  same numbers that make it fire are shown to produce a REAL invoice that reads Paid and is
//  therefore money-locked. If the comped clause or the lock ever moves, these fail and say so.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct ZeroingDiscountGuardTests {

    // MARK: The predicate

    /// The typo this whole guard exists for: 15% typed as 150. `EstimateTotals` clamps it to the
    /// whole subtotal, so the document is wiped out and the person is never told.
    @Test func firesOnAPercentageThatWipesTheDocumentOut() {
        let totals = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                    discountType: .percentage, discountValue: 150,
                                    depositType: .none, depositValue: 0)
        #expect(close(totals.subtotal, 1000))
        #expect(close(totals.total, 0))
        #expect(ZeroingDiscountGuard.fires(totals: totals, discountType: .percentage))
    }

    /// The percentage field caps at 100 at the keyboard, so 100 — not 150 — is what a typo
    /// actually lands on now. It still zeroes the document, which is exactly why the cap is not
    /// the fix and this guard is.
    @Test func firesAtExactlyOneHundredPercent() {
        let totals = EstimateTotals(lines: [(2500, true)], taxRatePercent: 7.5,
                                    discountType: .percentage, discountValue: 100,
                                    depositType: .none, depositValue: 0)
        #expect(close(totals.subtotal, 2500))
        #expect(close(totals.total, 0))   // tax scales with the discount, so it goes to 0 too
        #expect(ZeroingDiscountGuard.fires(totals: totals, discountType: .percentage))
    }

    /// A fixed discount is never capped — dollars are dollars — so $1,500 off a $1,000 job is
    /// reachable by typing and zeroes it just as completely.
    @Test func firesOnAFixedAmountThatCoversTheWholeSubtotal() {
        let totals = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                    discountType: .fixed, discountValue: 1500,
                                    depositType: .none, depositValue: 0)
        #expect(ZeroingDiscountGuard.fires(totals: totals, discountType: .fixed))

        // And at the exact boundary, where the discount equals the subtotal to the cent.
        let exact = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                   discountType: .fixed, discountValue: 1000,
                                   depositType: .none, depositValue: 0)
        #expect(ZeroingDiscountGuard.fires(totals: exact, discountType: .fixed))
    }

    /// An ordinary discount is the feature working. Silence is the whole point — this is the case
    /// that decides whether the alert stays meaningful.
    @Test func staysSilentOnAnOrdinaryDiscount() {
        let percent = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                     discountType: .percentage, discountValue: 15,
                                     depositType: .none, depositValue: 0)
        #expect(close(percent.total, 850))
        #expect(!ZeroingDiscountGuard.fires(totals: percent, discountType: .percentage))

        let fixed = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                   discountType: .fixed, discountValue: 250,
                                   depositType: .none, depositValue: 0)
        #expect(close(fixed.total, 750))
        #expect(!ZeroingDiscountGuard.fires(totals: fixed, discountType: .fixed))
    }

    /// A discount that leaves only pennies is still an ordinary discount, not a wipeout. The
    /// half-cent epsilon is the same one `Invoice.isPaid` uses, so "zero" means the same thing on
    /// both sides of the warning.
    @Test func staysSilentWhenACentSurvives() {
        let totals = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                    discountType: .fixed, discountValue: 999.99,
                                    depositType: .none, depositValue: 0)
        #expect(close(totals.total, 0.01))
        #expect(!ZeroingDiscountGuard.fires(totals: totals, discountType: .fixed))
    }

    /// A genuinely comped job — no line items, or every line at $0 — is $0 on purpose, and the
    /// owner relies on it reading Paid. There is no discount involved and nothing to warn about.
    @Test func staysSilentOnALegitimatelyZeroDocumentWithNoDiscount() {
        let empty = EstimateTotals(lines: [], taxRatePercent: 0,
                                   discountType: .none, discountValue: 0,
                                   depositType: .none, depositValue: 0)
        #expect(close(empty.subtotal, 0))
        #expect(close(empty.total, 0))
        #expect(!ZeroingDiscountGuard.fires(totals: empty, discountType: .none))

        let freeLines = EstimateTotals(lines: [(0, false), (0, true)], taxRatePercent: 7,
                                       discountType: .none, discountValue: 0,
                                       depositType: .none, depositValue: 0)
        #expect(close(freeLines.total, 0))
        #expect(!ZeroingDiscountGuard.fires(totals: freeLines, discountType: .none))
    }

    /// `.none` is checked first and on its own: a stale `discountValue` left behind when someone
    /// switches the picker back to None must not resurrect the warning.
    @Test func staysSilentWhenTheDiscountTypeIsNone() {
        // Same numbers that fire above, with only the type changed.
        #expect(!ZeroingDiscountGuard.fires(subtotal: 1000, total: 0, discountType: .none))

        // And through the real math, where a leftover 150 is ignored because the type is None.
        let totals = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                    discountType: .none, discountValue: 150,
                                    depositType: .none, depositValue: 0)
        #expect(close(totals.discount, 0))
        #expect(close(totals.total, 1000))
        #expect(!ZeroingDiscountGuard.fires(totals: totals, discountType: .none))
    }

    /// An empty draft with a discount typed into it is $0 for the obvious reason: there is no work
    /// on it yet. Warning here would fire on a form someone is still filling in.
    @Test func staysSilentOnAnEmptyDraftThatHappensToCarryADiscount() {
        let totals = EstimateTotals(lines: [], taxRatePercent: 0,
                                    discountType: .percentage, discountValue: 100,
                                    depositType: .none, depositValue: 0)
        #expect(close(totals.subtotal, 0))
        #expect(!ZeroingDiscountGuard.fires(totals: totals, discountType: .percentage))
    }

    /// An estimate deposit is not a discount and never reduces the total, so a 100% deposit must
    /// not trip the guard — the estimate form passes both through the same `adjustmentSection`.
    @Test func staysSilentOnAFullDepositWithNoDiscount() {
        let totals = EstimateTotals(lines: [(1000, false)], taxRatePercent: 0,
                                    discountType: .none, discountValue: 0,
                                    depositType: .percentage, depositValue: 100)
        #expect(close(totals.total, 1000))
        #expect(close(totals.deposit, 1000))
        #expect(!ZeroingDiscountGuard.fires(totals: totals, discountType: .none))
    }

    // MARK: The invoice form's own totals (change orders included)

    /// Change-order items are billed at full price on top of the discounted original work, so a
    /// 100% discount that wipes the original out still leaves the change order owing. The invoice
    /// is not zeroed and must save without a question.
    @Test func staysSilentWhenAChangeOrderKeepsTheInvoiceAboveZero() throws {
        let invoice = TS.invoice(discountType: .percentage, discountValue: 100,
                                 lines: [(1000, false), (400, false)])
        let group = try #require(invoice.sortedGroups.first)
        let coLine = try #require(group.sortedLineItems.last)
        coLine.fromChangeOrder = true

        #expect(close(invoice.subtotal, 1400))
        #expect(close(invoice.total, 400), "the original work is wiped out; the change order still bills")
        #expect(!ZeroingDiscountGuard.fires(subtotal: invoice.subtotal, total: invoice.total,
                                            discountType: invoice.discountType))
    }

    /// The mirror image: a change-order CREDIT can take an invoice to $0 with no discount anywhere.
    /// That is a deliberate zero — the guard is about discounts, not about $0. Two independent
    /// clauses keep it quiet here (no discount, and nothing left to discount), which is the point:
    /// neither one alone is carrying the separation.
    @Test func staysSilentOnAnInvoiceZeroedByAChangeOrderCredit() throws {
        let invoice = TS.invoice(lines: [(1000, false), (-1000, false)])
        let group = try #require(invoice.sortedGroups.first)
        let credit = try #require(group.sortedLineItems.last)
        credit.fromChangeOrder = true

        #expect(close(invoice.total, 0))
        #expect(invoice.discountType == .none)
        #expect(!ZeroingDiscountGuard.fires(subtotal: invoice.subtotal, total: invoice.total,
                                            discountType: invoice.discountType))
    }

    // MARK: The trap the guard is warning about

    /// The reason the alert says what it says. These are the same numbers as
    /// `firesAtExactlyOneHundredPercent`, saved as a sent invoice: it reads Paid off the comped
    /// clause, and paid means money-locked — no edit, no delete, no way back.
    ///
    /// If this ever stops holding, the alert's second sentence has become a lie and has to change
    /// with it.
    @Test func theInvoiceTheGuardWarnsAboutIsGenuinelyStuck() {
        let stuck = TS.invoice(status: .sent, discountType: .percentage, discountValue: 100,
                               lines: [(2500, false)])
        #expect(close(stuck.subtotal, 2500))
        #expect(close(stuck.total, 0))
        #expect(ZeroingDiscountGuard.fires(subtotal: stuck.subtotal, total: stuck.total,
                                           discountType: stuck.discountType))
        #expect(stuck.isPaid, "a sent $0 invoice reads Paid — the comped clause, working as designed")
        #expect(stuck.isMoneyLocked, "and Paid means the app and the Worker both refuse edits and deletes")
    }

    /// The same invoice left as a DRAFT is not locked yet — but it is one tap on the Status picker
    /// away from being locked, on this very form. That is why the guard is deliberately blind to
    /// status: warning only on the already-sent case would let the trap through the front door.
    @Test func theDraftIsNotLockedYetAndTheGuardStillFires() {
        let draft = TS.invoice(status: .draft, discountType: .percentage, discountValue: 100,
                               lines: [(2500, false)])
        #expect(!draft.isPaid)
        #expect(!draft.isMoneyLocked)
        #expect(ZeroingDiscountGuard.fires(subtotal: draft.subtotal, total: draft.total,
                                           discountType: draft.discountType))

        draft.status = .sent
        #expect(draft.isMoneyLocked, "one tap on Status is all it takes")
    }
}
