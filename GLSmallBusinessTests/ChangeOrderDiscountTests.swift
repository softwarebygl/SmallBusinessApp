//
//  ChangeOrderDiscountTests.swift
//  GLSmallBusinessTests
//
//  A change order applied to a discounted invoice is charged at FULL price (its own total) — the
//  invoice's overall discount only applies to the original work — so the invoice matches the signed
//  change order exactly.
//

import Testing
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ChangeOrderDiscountTests {
    @Test func changeOrderIsNotDiscountedOnTheInvoice() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let invoice = Invoice(number: "INV-0001")
        invoice.taxRatePercent = 10
        invoice.discountType = .percentage
        invoice.discountValue = 20            // 20% off the ORIGINAL work only
        ctx.insert(invoice)
        let group = InvoiceGroup(name: "Work", sortIndex: 0)
        group.invoice = invoice
        ctx.insert(group)

        let original = InvoiceLineItem(name: "Tile", quantity: 1, unitPrice: 1000, isTaxable: true, sortIndex: 0)
        original.group = group
        ctx.insert(original)

        let co = InvoiceLineItem(name: "Extra work", quantity: 1, unitPrice: 500, isTaxable: true, sortIndex: 1)
        co.fromChangeOrder = true             // pushed in from a change order
        co.group = group
        ctx.insert(co)

        // Original: $1000 − 20% = $800; tax 1000 × 0.8 × 10% = $80 → $880.
        // Change order at FULL price: $500 + 10% tax $50 = $550 (NOT discounted).
        #expect(close(invoice.subtotal, 1500))        // 1000 + 500
        #expect(close(invoice.discountAmount, 200))   // 20% of the $1000 original only
        #expect(close(invoice.taxAmount, 130))        // $80 original (discounted) + $50 CO (full)
        #expect(close(invoice.total, 1430))           // $880 + $550 — matches the signed change order

        // Control: without the flag, the old behavior discounts everything (total $1320).
        co.fromChangeOrder = false
        #expect(close(invoice.total, 1320))
    }
}
