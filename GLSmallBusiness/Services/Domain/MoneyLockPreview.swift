//
//  MoneyLockPreview.swift
//  GLSmallBusiness
//
//  "Would this edit lock the invoice?" — answered BEFORE the edit is written.
//
//  A paid invoice is money-locked (PaidInvoiceLock.swift): the server refuses edits and deletes to
//  it, so the app does too. An edit that makes the invoice read Paid — a discount that zeroes it,
//  flipping a $0 draft to Sent, a change-order credit that covers the balance — therefore closes a
//  door behind the person. The forms ask about the commonest one (ZeroingDiscountGuard); the
//  assistant must confirm every one. Both read the verdict from here, computed on a scratch copy of
//  the numbers (never on the live model, which would have to be written to be measured).
//
//  `InvoiceMath` is the invoice money formula itself, so the model, the form preview and this
//  preview can never drift: `Invoice.totals` and `Invoice.isPaid` delegate to it.
//

import Foundation
import SwiftData
import GoldLifeDocuments

// MARK: - Invoice math extensions for My Business

extension GLInvoiceMath {
    /// `Invoice.isPaid`: nothing owed, and either there was something to bill, something was paid,
    /// or the invoice was sent (so a comped $0 sent invoice reads Paid, a $0 draft does not).
    nonisolated static func isPaid(total: Double, amountPaid: Double, status: InvoiceStatus) -> Bool {
        isPaid(total: total, amountPaid: amountPaid, isSent: status == .sent)
    }

    /// The same totals over form drafts (the invoice form's Summary and the services' previews).
    @MainActor
    static func totals(groups: [InvoiceGroupDraft], taxRatePercent: Double,
                       discountType: AdjustmentType, discountValue: Double) -> GLDocumentTotals {
        let original: [(lineTotal: Decimal, isTaxable: Bool)] = groups.flatMap(\.lines)
            .filter { !$0.fromChangeOrder }.map { ($0.exactLineTotal, $0.isTaxable) }
        // A group pushed from a change order keeps that order's signed rate, whatever the form's
        // invoice rate is now.
        let billed: [(signedLineTotal: Decimal, isTaxable: Bool, taxRatePercent: Double)] = groups.flatMap { group in
            let rate = InvoiceGroup.changeOrderTaxRate(group.changeOrder, invoiceRate: taxRatePercent)
            return group.lines.filter(\.fromChangeOrder).map { ($0.exactSignedLineTotal, $0.isTaxable, rate) }
        }
        return totals(original: original, ratedChangeOrder: billed,
                      taxRatePercent: taxRatePercent, discountType: discountType,
                      discountValue: discountValue)
    }
}


nonisolated enum MoneyLockPreview {

    /// True when an invoice that is NOT locked now would be locked by the proposed numbers.
    static func wouldLock(currentlyLocked: Bool, proposedTotal: Double, amountPaid: Double,
                          status: InvoiceStatus) -> Bool {
        !currentlyLocked && InvoiceMath.isPaid(total: proposedTotal, amountPaid: amountPaid, status: status)
    }

    /// The zeroing-discount question (ZeroingDiscountGuard delegates here): a whole-document discount
    /// took real work down to nothing, so the document would lock the moment it reads Sent with no
    /// payment yet. Status-blind on purpose — "Sent" is one tap away on the same form.
    static func discountZeroesDocument(totals: EstimateTotals, discountType: AdjustmentType) -> Bool {
        discountType != .none && totals.subtotal > DomainMoney.epsilon
            && InvoiceMath.isPaid(total: totals.total, amountPaid: 0, status: .sent)
    }
}

@MainActor
extension MoneyLockPreview {

    /// Would saving `draft` onto `invoice` (nil = a new invoice) lock it? Kept lines only, the way
    /// the save stores them; payments are the invoice's live ones.
    static func wouldLock(_ invoice: Invoice?, applying draft: InvoiceDraft) -> Bool {
        let kept = DocumentDraftRules.keptGroups(draft.groups)
        let totals = InvoiceMath.totals(groups: kept, taxRatePercent: draft.taxRatePercent,
                                        discountType: draft.discountType, discountValue: draft.discountValue)
        return wouldLock(currentlyLocked: invoice?.isMoneyLocked ?? false, proposedTotal: totals.total,
                         amountPaid: invoice?.amountPaid ?? 0, status: draft.status)
    }

    /// Would changing only the status lock it (a $0 draft marked Sent)?
    static func wouldLock(_ invoice: Invoice, status: InvoiceStatus) -> Bool {
        wouldLock(currentlyLocked: invoice.isMoneyLocked, proposedTotal: invoice.total,
                  amountPaid: invoice.amountPaid, status: status)
    }

    /// Would adding this approved change order's items to its invoice lock it (a credit that covers
    /// the balance)? Mirrors `ChangeOrder.addItemsToInvoice`: every item joins as a full-price,
    /// un-discounted change-order line.
    static func wouldLock(applying changeOrder: ChangeOrder) -> Bool {
        guard let invoice = changeOrder.invoice else { return false }
        let (original, billed) = invoice.billedLines()
        // The added rows bill at the rate the order was signed at.
        let added: [(signedLineTotal: Decimal, isTaxable: Bool, taxRatePercent: Double)] =
            changeOrder.sortedLineItems.map { ($0.exactLineTotal, $0.isTaxable, changeOrder.taxRatePercent) }
        let totals = InvoiceMath.totals(
            original: original,
            ratedChangeOrder: billed + added,
            taxRatePercent: invoice.taxRatePercent, discountType: invoice.discountType,
            discountValue: invoice.discountValue)
        return wouldLock(currentlyLocked: invoice.isMoneyLocked, proposedTotal: totals.total,
                         amountPaid: invoice.amountPaid, status: invoice.status)
    }

    /// Would SAVING `draft` onto this order lock its invoice? An order already on the invoice has
    /// its billed rows re-pushed by `ChangeOrderService.update`, so editing an applied order's
    /// amounts moves the invoice total — and dropping enough of it can leave the invoice fully
    /// paid, and locked. Its own billed group is taken off first; the draft's items go back on in
    /// its place, signed (a credit subtracts). An order that is NOT on the invoice changes nothing.
    static func wouldLock(_ changeOrder: ChangeOrder, applying draft: ChangeOrderDraft) -> Bool {
        guard changeOrder.appliedToInvoice, let invoice = changeOrder.invoice else { return false }
        let (original, billed) = invoice.billedLines(excluding: changeOrder.invoiceGroup)
        // The rows the save would keep, exactly as `ChangeOrderService.write` keeps them, at the
        // rate the save stores on the order.
        let kept = draft.items.filter { !DocumentDraftRules.trim($0.name).isEmpty }
        let rate = ChangeOrderService.taxRateAfterSave(changeOrder, keeping: kept, invoiceRate: invoice.taxRatePercent)
        let added: [(signedLineTotal: Decimal, isTaxable: Bool, taxRatePercent: Double)] =
            kept.map { ($0.exactLineTotal, $0.isTaxable, rate) }
        let totals = InvoiceMath.totals(original: original, ratedChangeOrder: billed + added,
                                        taxRatePercent: invoice.taxRatePercent,
                                        discountType: invoice.discountType,
                                        discountValue: invoice.discountValue)
        return wouldLock(currentlyLocked: invoice.isMoneyLocked, proposedTotal: totals.total,
                         amountPaid: invoice.amountPaid, status: invoice.status)
    }

    /// Would taking this applied order's items back OFF its invoice lock it? Moving an added order
    /// off Approved removes its billed group (`ChangeOrder.removeItemsFromInvoice`), so dropping a
    /// charge can leave an invoice fully paid — and locked. Tool only (the status picker's own
    /// refusals cover the screen).
    static func wouldLock(removing changeOrder: ChangeOrder) -> Bool {
        guard changeOrder.appliedToInvoice, let invoice = changeOrder.invoice else { return false }
        let (original, billed) = invoice.billedLines(excluding: changeOrder.invoiceGroup)
        let totals = InvoiceMath.totals(original: original, ratedChangeOrder: billed,
                                        taxRatePercent: invoice.taxRatePercent,
                                        discountType: invoice.discountType,
                                        discountValue: invoice.discountValue)
        return wouldLock(currentlyLocked: invoice.isMoneyLocked, proposedTotal: totals.total,
                         amountPaid: invoice.amountPaid, status: invoice.status)
    }

    /// Would recording this payment settle (and so lock) the invoice? Always a plain fact for a
    /// payment of the whole balance — the assistant says it; nothing refuses it.
    static func wouldLock(_ invoice: Invoice, recordingPayment amount: Double) -> Bool {
        // What `amountPaid` will read once it is recorded: every payment, this one included, added
        // exactly and rounded once.
        let paid = DomainMoney.roundedSum(invoice.liveRows(invoice.payments).map(\.amount) + [amount])
        return wouldLock(currentlyLocked: invoice.isMoneyLocked, proposedTotal: invoice.total,
                         amountPaid: paid, status: invoice.status)
    }
}
