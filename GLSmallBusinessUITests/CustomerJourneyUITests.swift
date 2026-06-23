//
//  CustomerJourneyUITests.swift
//  GLSmallBusinessUITests
//
//  A full create flow end to end: open the add form, fill it in, save, and confirm the new customer
//  shows up in the list — exercising the form fields, Save, and the list refresh in one pass.
//

import XCTest

final class CustomerJourneyUITests: GLUITestCase {

    func testCreatingACustomerAddsItToTheList() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["More"].tap()
        app.buttons["New Customer"].tap()

        let firstName = app.textFields["First name"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5), "The New Customer form should appear.")
        firstName.tap()
        firstName.typeText("Uitest")

        app.textFields["Last name"].tap()
        app.textFields["Last name"].typeText("Zylker")

        app.buttons["Save"].tap()

        // Back in the list, the customer shows as "Last, First".
        XCTAssertTrue(app.staticTexts["Zylker, Uitest"].waitForExistence(timeout: 5),
                      "A saved customer should appear in the list.")
    }
}
