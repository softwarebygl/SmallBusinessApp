//
//  ScreenSweepUITests.swift
//  GLSmallBusinessUITests
//
//  Opens the app's main screens and confirms each one appears. This is the dead-interaction guard:
//  it catches an add button, menu row, list row, or link that silently goes nowhere (the class of bug
//  that left the Insurance rows dead). Opening this many screens also exercises most of the view code.
//

import XCTest

final class ScreenSweepUITests: GLUITestCase {

    // MARK: - Add forms open (iPhone routes each through the "More" menu)

    func testAddCustomerFormOpens() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["More"].tap()
        app.buttons["New Customer"].tap()
        XCTAssertTrue(app.navigationBars["New Customer"].waitForExistence(timeout: 5),
                      "New Customer should open the New Customer form.")
    }

    func testAddEmployeeFormOpens() {
        app.tabBars.buttons["Employees"].tap()
        app.buttons["More"].tap()
        app.buttons["New employee"].tap()
        XCTAssertTrue(app.navigationBars["New Employee"].waitForExistence(timeout: 5),
                      "New employee should open the New Employee form.")
    }

    func testAddSubcontractorFormOpens() {
        app.tabBars.buttons["Subcontractors"].tap()
        app.buttons["More"].tap()
        app.buttons["New subcontractor"].tap()
        XCTAssertTrue(app.navigationBars["New Subcontractor"].waitForExistence(timeout: 5),
                      "New subcontractor should open the New Subcontractor form.")
    }

    // MARK: - Hubs open from a row, and "More Info" pushes

    func testCustomerHubAndMoreInfoOpen() {
        app.tabBars.buttons["Customers"].tap()
        app.staticTexts["Carter, Danielle"].tap()
        XCTAssertTrue(app.navigationBars["Carter, Danielle"].waitForExistence(timeout: 5),
                      "Tapping a customer row should open that customer's hub.")
        app.buttons["More Info"].tap()
        XCTAssertTrue(app.staticTexts["Email"].waitForExistence(timeout: 5),
                      "More Info should push the customer's details.")
    }

    // MARK: - Menu → company hub → Insurance (the dead-rows regression guard)

    func testMenuOpensCompanyHub() {
        openMenu()
        app.staticTexts["Business"].tap()
        XCTAssertTrue(app.staticTexts["Insurance & Licensing"].waitForExistence(timeout: 5),
                      "Tapping Business should open the company hub with its action rows.")
    }

    func testInsuranceScreenOpensFromCompanyHub() {
        openMenu()
        app.staticTexts["Business"].tap()
        app.staticTexts["Insurance & Licensing"].tap()
        XCTAssertTrue(app.navigationBars["Insurance & Licensing"].waitForExistence(timeout: 5),
                      "The Insurance & Licensing screen should open from the company hub.")
    }

    private func openMenu() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
    }
}
