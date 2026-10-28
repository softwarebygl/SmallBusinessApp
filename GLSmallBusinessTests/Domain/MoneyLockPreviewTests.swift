//
//  MoneyLockPreviewTests.swift
//  GLSmallBusinessTests — Domain
//
//  "Would this edit lock the invoice?" — computed before the write, and in agreement with the
//  model's own verdict and with the forms' zeroing-discount question.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct MoneyLockPreviewTests {

    private func draft(price: Double, discount: AdjustmentType = .none, value: Double = 0,
                       status: InvoiceStatus = .draft) -> InvoiceDraft {
        var draft = InvoiceDraft()
        draft.jobTitle = "Job"
        draft.status = status
        draft.discountType = discount
        draft.discountValue = value
        var line = InvoiceLineDraft()
        line.name = "Work"
        line.unitPrice = price
        draft.groups = [InvoiceGroupDraft(lines: [line])]
        return draft
    }

    @Test func invoiceMathIsTheModelsFormula() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(taxRatePercent: 7.5, discountType: .percentage, discountValue: 12,
                                 lines: [(1000, true), (250, false)], in: context)
        let credit = TS.changeOrder(invoice, status: .approved, lines: [(-300, true)], in: context)
        credit.addItemsToInvoice(using: context)
        context.saveChanges()

        let fromDraft = InvoiceDraft(invoice).totals
        #expect(fromDraft.subtotal == invoice.totals.subtotal)
        #expect(fromDraft.discount == invoice.totals.discount)
        #expect(fromDraft.tax == invoice.totals.tax)
        #expect(fromDraft.total == invoice.totals.total)

        for (total, paid, status) in [(0.0, 0.0, InvoiceStatus.draft), (0, 0, .sent), (100, 99.996, .draft),
                                      (100, 99.99, .sent), (0, 5, .draft), (50, 50, .draft)] {
            let probe = TS.invoice(number: "P", status: status, lines: [(total, false)], in: context)
            if paid > 0 { TS.pay(probe, paid, in: context) }
            #expect(InvoiceMath.isPaid(total: total, amountPaid: paid, status: status) == probe.isPaid,
                    "total \(total) paid \(paid) \(status.rawValue)")
        }
    }

    /// The forms' question and the assistant's question agree on every shape.
    @Test func theZeroingDiscountGuardDelegatesHere() {
        for subtotal in [0.0, 0.004, 0.006, 100] {
            for total in [0.0, 0.004, 0.006, 50] {
                for type in AdjustmentType.allCases {
                    let totals = EstimateTotals(exactSubtotal: DomainMoney.decimal(subtotal), discount: 0, tax: 0,
                                                total: DomainMoney.decimal(total))
                    #expect(ZeroingDiscountGuard.fires(subtotal: subtotal, total: total, discountType: type)
                            == MoneyLockPreview.discountZeroesDocument(totals: totals, discountType: type))
                    // …and it is the plain arithmetic the guard always meant.
                    #expect(MoneyLockPreview.discountZeroesDocument(totals: totals, discountType: type)
                            == (type != .none && subtotal > 0.005 && total <= 0.005))
                }
            }
        }
    }

    @Test func draftsThatWouldLock() throws {
        let context = try DomainFixtures.context()
        // New invoice: a 100% discount locks once it reads Sent, not while it is a draft.
        #expect(MoneyLockPreview.wouldLock(nil, applying: draft(price: 500, discount: .percentage, value: 100, status: .sent)))
        #expect(!MoneyLockPreview.wouldLock(nil, applying: draft(price: 500, discount: .percentage, value: 100)))
        #expect(!MoneyLockPreview.wouldLock(nil, applying: draft(price: 500, status: .sent)))

        // Existing invoice with a payment: a discount that brings the total down to what was paid.
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        TS.pay(invoice, 400, in: context)
        context.saveChanges()
        var edit = InvoiceDraft(invoice)
        edit.discountType = .fixed
        edit.discountValue = 600
        #expect(MoneyLockPreview.wouldLock(invoice, applying: edit))
        edit.discountValue = 500
        #expect(!MoneyLockPreview.wouldLock(invoice, applying: edit))
        #expect(!MoneyLockPreview.wouldLock(invoice, applying: InvoiceDraft(invoice)), "blank line filter only; nothing changes")

        // Already locked: nothing more to flip.
        TS.pay(invoice, 600, in: context)
        context.saveChanges()
        #expect(invoice.isMoneyLocked)
        #expect(!MoneyLockPreview.wouldLock(invoice, applying: edit))
    }

    @Test func statusCreditsAndPaymentsThatWouldLock() throws {
        let context = try DomainFixtures.context()
        let comped = TS.invoice(lines: [(0, false)], in: context)
        let invoice = TS.invoice(number: "INV-2", lines: [(1000, false)], in: context)
        TS.pay(invoice, 700, in: context)
        let credit = TS.changeOrder(invoice, status: .approved, lines: [(-300, false)], in: context)
        let smallCredit = TS.changeOrder(invoice, number: "CO-0002", status: .approved, lines: [(-100, false)], in: context)
        context.saveChanges()

        #expect(MoneyLockPreview.wouldLock(comped, status: .sent), "a $0 invoice reads Paid once sent")
        #expect(!MoneyLockPreview.wouldLock(comped, status: .draft))
        #expect(MoneyLockPreview.wouldLock(applying: credit), "the credit covers the $300 balance")
        #expect(!MoneyLockPreview.wouldLock(applying: smallCredit))
        #expect(MoneyLockPreview.wouldLock(invoice, recordingPayment: 300))
        #expect(!MoneyLockPreview.wouldLock(invoice, recordingPayment: 299))
        // The preview measured a scratch copy — nothing was written.
        #expect(!context.hasChanges && !credit.appliedToInvoice && invoice.sortedGroups.count == 1)
    }

    /// A credit signed at 10% on an invoice now at 0% takes off $110, not $100 (law 87, QA F82):
    /// the preview prices it the way the invoice will bill it.
    @Test func aCreditIsPreviewedAtTheRateItWasSignedAt() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, true)], in: context)
        TS.pay(invoice, 895, in: context)
        let credit = TS.changeOrder(invoice, status: .approved, taxRatePercent: 10, lines: [(-100, true)], in: context)
        context.saveChanges()

        #expect(MoneyLockPreview.wouldLock(applying: credit), "$1,000 − $110 = $890, already paid $895")
        credit.addItemsToInvoice(using: context)
        context.saveChanges()
        #expect(invoice.total == 890 && invoice.isPaid, "the preview's verdict is the model's")
    }

    /// Taking one order off leaves the other billed at ITS signed rate: $1,000 + $110 = $1,110,
    /// $5 still owed on $1,105 paid — no lock. (At the invoice's 0% it would read $1,100 and lock.)
    @Test func removingAnOrderLeavesTheOthersAtTheirSignedRates() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, true)], in: context)
        let first = TS.changeOrder(invoice, status: .approved, taxRatePercent: 10, lines: [(100, true)], in: context)
        let second = TS.changeOrder(invoice, number: "CO-0002", status: .approved, taxRatePercent: 10,
                                    lines: [(100, true)], in: context)
        context.saveChanges()
        first.addItemsToInvoice(using: context)
        second.addItemsToInvoice(using: context)
        TS.pay(invoice, 1105, in: context)
        context.saveChanges()

        #expect(invoice.total == 1220 && !invoice.isPaid)
        #expect(!MoneyLockPreview.wouldLock(removing: second))
    }
}
