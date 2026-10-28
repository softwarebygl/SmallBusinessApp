//
//  AllInvoicesOwedTotalPerformanceTests.swift
//  GLSmallBusinessTests
//
//  QA F92 (2026-10-03): what one "Owed to you" computation costs on a large account — 500
//  invoices, each with three line items and a payment. Before the fix All Invoices paid this
//  twice per draw, keystrokes included; now it is paid once per data change
//  (FetchAndDecodeScopeHostedTests.typingInSearchNeverRecomputesTheOwedTotal pins the count).
//  XCTest's measure() records the time in the result bundle; the figure is also checked.
//
//  Nothing is hosted and nothing is saved, so this class cannot interleave with the hosted
//  Swift Testing suites (GLTestHost header).
//

import XCTest
import SwiftData
@testable import GLSmallBusiness

@MainActor
final class AllInvoicesOwedTotalPerformanceTests: XCTestCase {

    func testOwedTotalOverFiveHundredInvoices() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let invoices = (0..<500).map { i -> Invoice in
            let invoice = TS.invoice(number: String(format: "INV-PF-%04d", i), status: .sent,
                                     lines: [(100, false), (200, false), (300, false)], in: context)
            TS.pay(invoice, 100, in: context)
            return invoice
        }
        // 500 × ($600 − $100 paid) = $250,000.00 owed.
        XCTAssertEqual(OwedToYouCard.owedTotal(invoices), 250_000, accuracy: 0.005)
        measure {
            _ = OwedToYouCard.owedTotal(invoices)
        }
    }
}
