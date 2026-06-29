//
//  ChangeOrderBalanceUITests.swift
//  GLSmallBusinessUITests
//
//  Verifies the change-order/balance fix against deterministic demo data, seeded only under the
//  `-uiTestChangeOrder` launch arg: a $1,000 invoice with $300 paid and one APPROVED, not-yet-added
//  change order of +$200. The change order must NOT affect the balance until it's added to the invoice;
//  adding it must bill it exactly once.
//

import XCTest

final class ChangeOrderBalanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoMode", "-uiTestChangeOrder"]
        app.launch()
    }

    /// Scrolls until `element` can be tapped (the change-order card sits below the totals).
    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 8) {
        var tries = 0
        while !element.isHittable && tries < maxSwipes { app.swipeUp(); tries += 1 }
    }

    func testApprovedChangeOrderEntersBalanceOnlyWhenAdded() {
        // Open the fixture invoice: Menu → All Invoices → INV-0099.
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "Menu button missing")
        menu.tap()
        let allInvoices = app.staticTexts["All Invoices"]
        XCTAssertTrue(allInvoices.waitForExistence(timeout: 10), "All Invoices row missing")
        allInvoices.tap()
        let invoiceRow = app.staticTexts["INV-0099"]
        XCTAssertTrue(invoiceRow.waitForExistence(timeout: 10), "fixture invoice INV-0099 not found")
        invoiceRow.tap()

        // Before adding: balance = $1,000 − $300 = $700. The $200 change order is NOT counted yet.
        XCTAssertTrue(app.staticTexts["$700.00"].waitForExistence(timeout: 10),
                      "balance should be $700.00 before the change order is added")
        XCTAssertFalse(app.staticTexts["$900.00"].exists,
                       "balance must not include the change order before it's added")

        // The approved change order is surfaced in the invoice with an inline Add-to-invoice button.
        let addButton = app.buttons["Add to invoice"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "'Add to invoice' button missing")
        scrollToHittable(addButton)
        addButton.tap()

        // After adding: total $1,200, balance $1,200 − $300 = $900 (billed exactly once).
        XCTAssertTrue(app.staticTexts["$900.00"].waitForExistence(timeout: 10),
                      "balance should update to $900.00 once the change order is added")
    }
}
