//
//  ZeroingDiscountGuard.swift
//  GLSmallBusiness
//
//  The one place a mistyped whole-document discount is caught: BEFORE the document is written.
//
//  The trap this closes, spelled out because every piece of it is correct on its own:
//  a discount big enough to wipe the document out leaves `total` at 0. On an invoice that has
//  been sent, `Invoice.isPaid` then reads TRUE — deliberately, so a genuinely comped job shows
//  "Paid" instead of sitting "Overdue" forever (Invoice.swift). And a paid invoice is money-locked
//  (PaidInvoiceLock.swift): the sync Worker refuses edits AND deletes to it, so the app refuses
//  them too. Chain the three and someone who meant 15% and typed 150 owns an invoice that can
//  never be corrected and never be deleted — the only way out is abandoning it and making a new one.
//
//  Why the fix lives here and not in any of those three: each of them is right, and each is
//  load-bearing somewhere else. Narrowing the comped clause would flip Paid→Unpaid on comped
//  invoices already in customers' hands, and would have to land in Estimate.swift, Invoice.swift,
//  the Worker's money.ts and the shared conformance vectors simultaneously. Loosening the money
//  lock would re-open the divergence bug it exists to prevent. Creation is the only point where
//  the trap is cheap: nothing is written yet, so a single question — "did you mean this?" — costs
//  one tap and unwinds the whole chain.
//
//  Why the percentage cap at 100 (see `adjustmentSection`) is NOT this guard: 100% still zeroes
//  the document. The cap makes the clamp honest; this makes the consequence visible.
//
//  House rule, same as PaidInvoiceLock: explain, never a dead disabled control. Save stays
//  tappable and the alert says what saving will do.
//

import SwiftUI

/// Whether the document's own totals show the zeroing-discount trap.
///
/// `nonisolated` because it is pure arithmetic over values the caller already has — the forms
/// call it from `@MainActor`, the tests call it from anywhere, and nothing here touches state.
nonisolated enum ZeroingDiscountGuard {

    /// True when a whole-document discount is what took a document with real work on it down to
    /// nothing billable.
    ///
    /// All three clauses earn their place:
    /// - `discountType != .none` — a $0 document with no discount is not this bug. A comped job
    ///   entered as a $0 line, or an invoice zeroed by a change-order credit, is a deliberate
    ///   $0 and must save without a word.
    /// - `subtotal > 0.005` — there has to be work to discount. An empty draft is $0 for the
    ///   obvious reason, and warning about it would train people to dismiss this alert.
    /// - `total <= 0.005` — the discount actually consumed everything. An ordinary discount that
    ///   leaves a balance is the feature working.
    ///
    /// The half-cent epsilon is the same one the money lock and `Invoice.isPaid` use, so this
    /// predicate and the "Paid" verdict it is warning about agree on where zero is; a tighter or
    /// looser one here would warn about invoices that don't lock, or miss ones that do.
    ///
    /// Deliberately blind to `status`: an invoice only locks once it reads Paid, which for a $0
    /// total means once it is sent. But the Status picker sits on this same form, "Sent" is one
    /// tap away, and a $0 draft becomes a $0 sent invoice the moment it is delivered — warning
    /// only on the already-sent case would let the trap through by the front door.
    ///
    /// The verdict itself lives in `MoneyLockPreview.discountZeroesDocument` — the same question the
    /// assistant asks before it writes — so the form's alert and the assistant's confirmation can
    /// never disagree about where zero is.
    static func fires(subtotal: Double, total: Double, discountType: AdjustmentType) -> Bool {
        MoneyLockPreview.discountZeroesDocument(
            totals: EstimateTotals(exactSubtotal: DomainMoney.decimal(subtotal), discount: 0, tax: 0,
                                   total: DomainMoney.decimal(total)),
            discountType: discountType)
    }

    /// Convenience over the totals the forms already compute for their Summary section, so the
    /// preview the person is reading is literally what gets judged.
    static func fires(totals: EstimateTotals, discountType: AdjustmentType) -> Bool {
        fires(subtotal: totals.subtotal, total: totals.total, discountType: discountType)
    }
}

extension View {
    /// The confirmation shown before saving an invoice a discount has zeroed.
    ///
    /// It names the consequence in the order it will be felt: nothing gets billed, and then the
    /// door closes behind it. The second sentence is the whole reason this alert exists — "you
    /// can't edit or delete it" is the fact that turns a typo into a permanent record, and it is
    /// the one thing a person cannot discover by looking at the form.
    ///
    /// Cancel is the effortless way out (`.cancel` role: bolded, and what Escape and a tap outside
    /// choose), because the overwhelmingly likelier reading of a zeroed invoice is a typo. Save is
    /// plain, not destructive — comping a job is a real thing to do, and colouring it red would
    /// scold the person doing it on purpose.
    func zeroingDiscountInvoiceAlert(isPresented: Binding<Bool>, onSave: @escaping () -> Void) -> some View {
        alert("This discount brings the total to $0", isPresented: isPresented) {
            Button("Save") { onSave() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing will be billed. A $0 invoice reads as paid, and paid invoices can’t be edited or deleted.")
        }
    }

    /// The same confirmation for an estimate, minus the lock.
    ///
    /// A separate sentence on purpose: an estimate is never money-locked, so borrowing the
    /// invoice's warning would threaten a consequence that does not exist here — and a warning
    /// that overstates itself is the fastest way to teach people to tap through it. What is left
    /// is the part that is still true: the customer would be quoted nothing at all.
    func zeroingDiscountEstimateAlert(isPresented: Binding<Bool>, onSave: @escaping () -> Void) -> some View {
        alert("This discount brings the total to $0", isPresented: isPresented) {
            Button("Save") { onSave() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing would be billed for this job. Check the discount if you meant a smaller number.")
        }
    }
}
