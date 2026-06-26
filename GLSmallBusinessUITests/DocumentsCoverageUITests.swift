//
//  DocumentsCoverageUITests.swift
//  GLSmallBusinessUITests
//
//  Opens the remaining heavy document/info screens — Personal info, the company "More Info" and W-9,
//  the per-customer Invoices list + new-invoice form, and a receipt's detail. These are the largest
//  views still untouched by the other suites.
//

import XCTest

final class DocumentsCoverageUITests: GLUITestCase {

    func testPersonalInfoOpens() {
        openMenu()
        app.staticTexts["Personal"].tap()
        XCTAssertTrue(app.navigationBars["My Personal Info"].waitForExistence(timeout: 5),
                      "Menu → Personal should open the personal info screen.")
    }

    func testCompanyMoreInfoOpens() {
        openCompanyHub()
        app.staticTexts["More Info"].tap()
        XCTAssertTrue(app.navigationBars["More Info"].waitForExistence(timeout: 5),
                      "The company hub's More Info should push the company details.")
    }

    func testGenerateW9Opens() {
        openCompanyHub()
        let w9 = app.staticTexts["Generate a W-9"]
        XCTAssertTrue(w9.waitForExistence(timeout: 5))
        if !w9.isHittable { app.swipeUp() }
        w9.tap()
        XCTAssertTrue(app.navigationBars["Generate a W-9"].waitForExistence(timeout: 5),
                      "Generate a W-9 should open the W-9 sheet.")
    }

    func testInvoicesListAndNewInvoiceFormOpen() {
        app.tabBars.buttons["Customers"].tap()
        app.staticTexts["Carter, Danielle"].tap()
        app.staticTexts["Invoices"].tap()
        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 5),
                      "The customer's Invoices list should open.")
        app.buttons["More"].tap()
        app.buttons["New Invoice"].tap()
        XCTAssertTrue(app.textFields["Job title"].waitForExistence(timeout: 5),
                      "New Invoice should open the invoice form.")
    }

    func testReceiptDetailOpens() {
        openMenu()
        app.staticTexts["All Receipts"].tap()
        XCTAssertTrue(app.navigationBars["All Receipts"].waitForExistence(timeout: 5))
        app.staticTexts["Henderson Hardware"].tap()
        XCTAssertFalse(app.navigationBars["All Receipts"].waitForExistence(timeout: 3),
                       "Tapping a receipt should open its detail.")
    }

    private func openMenu() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
    }

    private func openCompanyHub() {
        openMenu()
        app.staticTexts["Business"].tap()
        XCTAssertTrue(app.staticTexts["Insurance & Licensing"].waitForExistence(timeout: 5),
                      "The company hub should open.")
    }
}
