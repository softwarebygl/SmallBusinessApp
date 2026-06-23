//
//  NavigationDeepUITests.swift
//  GLSmallBusinessUITests
//
//  Opens the heavier detail/list screens (employee + subcontractor hubs, the Job-Records lists, an
//  invoice's detail). These are the largest views in the app, so reaching them both guards their
//  navigation and meaningfully exercises their code.
//

import XCTest

final class NavigationDeepUITests: GLUITestCase {

    func testEmployeeHubAndMoreInfoOpen() {
        app.tabBars.buttons["Employees"].tap()
        app.staticTexts["Garcia, Jason"].tap()
        XCTAssertTrue(app.navigationBars["Garcia, Jason"].waitForExistence(timeout: 5),
                      "Tapping an employee row should open that employee's hub.")
        app.buttons["More Info"].tap()
        XCTAssertTrue(app.staticTexts["Email"].waitForExistence(timeout: 5),
                      "More Info should push the employee's details.")
    }

    func testSubcontractorHubAndMoreInfoOpen() {
        app.tabBars.buttons["Subcontractors"].tap()
        app.staticTexts["Mendoza, Luis"].tap()
        XCTAssertTrue(app.navigationBars["Mendoza, Luis"].waitForExistence(timeout: 5),
                      "Tapping a subcontractor row should open that subcontractor's hub.")
        app.buttons["More Info"].tap()
        XCTAssertTrue(app.staticTexts["Email"].waitForExistence(timeout: 5),
                      "More Info should push the subcontractor's details.")
    }

    func testJobRecordsListsOpen() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
        openListThenBack("All Estimates")
        openListThenBack("All Invoices")
        openListThenBack("All Change Orders")
        openListThenBack("All Receipts")
    }

    func testInvoiceDetailOpens() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
        app.staticTexts["All Invoices"].tap()
        XCTAssertTrue(app.navigationBars["All Invoices"].waitForExistence(timeout: 5))
        app.staticTexts["INV-0001"].tap()
        XCTAssertFalse(app.navigationBars["All Invoices"].waitForExistence(timeout: 3),
                       "Tapping an invoice should leave the list and open its detail.")
    }

    /// Taps a Job-Records row, confirms the list opened, then returns to the Menu.
    private func openListThenBack(_ title: String) {
        app.staticTexts[title].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5),
                      "\(title) should open its list.")
        app.navigationBars[title].buttons.firstMatch.tap()
    }
}
