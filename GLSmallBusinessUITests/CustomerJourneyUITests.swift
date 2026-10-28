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
        app.openContacts("Customers")
        // Law 40 (2026-09): the "..." menu is gone — "+" is a PERMANENT direct navbar
        // button (a11y label "Add Customer") that opens the New Customer form.
        let addButton = app.buttons["Add Customer"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5),
                      "The Customers list should have its + (Add Customer) navbar button.")
        addButton.tap()

        let firstName = app.textFields["First name"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5), "The New Customer form should appear.")
        XCTAssertTrue(firstName.tapForKeyboardFocus(), "First name should take the keyboard.")
        firstName.typeText("Uitest")
        // typeText returns before the app has every keystroke; read only once it all landed.
        XCTAssertTrue(firstName.waitForValue("Uitest"), "First name should read Uitest.")

        let lastName = app.textFields["Last name"]
        XCTAssertTrue(lastName.tapForKeyboardFocus(), "Last name should take the keyboard.")
        lastName.typeText("Zylker")
        XCTAssertTrue(lastName.waitForValue("Zylker"), "Last name should read Zylker.")

        app.buttons["Save"].tap()

        // Save lands on the new customer's DETAIL screen. Its bar title carries
        // whatever trailing pad THAT string needs (GLScript.padded is
        // per-string as of 2026-08-31 — most titles get none), so match by
        // PREFIX rather than pinning a pad width here: a test that hardcodes
        // the padding breaks every time the measurement improves, which is
        // noise, not signal. Assert the detail, then go BACK and assert the
        // LIST row (rows are plain text, never padded).
        let detailTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Zylker, Uitest")).firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5),
                      "Save should land on the new customer's detail screen.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Zylker, Uitest"].waitForExistence(timeout: 5),
                      "A saved customer should appear in the list.")
    }

    /// Swipe → Delete → type the name → Delete removes the customer and the app stays up.
    /// 2026-09-26: the swipe used `.onDelete`, which took the row out of the list before the
    /// typed-name confirmation deleted the data, and the real delete then crashed the list
    /// ("Invalid number of items in section").
    func testSwipeDeleteWithTheTypedNameRemovesTheCustomerWithoutCrashing() {
        app.openContacts("Customers")
        let row = app.row("Nguyen, Sofia")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The demo data should list Sofia Nguyen.")
        row.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "The swipe should reveal Delete.")
        swipeDelete.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete should ask for the typed name first.")
        let confirm = alert.buttons["Delete"]
        XCTAssertFalse(confirm.isEnabled, "Delete stays off until the name is typed.")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.tapForKeyboardFocus(), "The name field should take the keyboard.")
        field.typeText("Sofia Nguyen")
        XCTAssertTrue(field.waitForValue("Sofia Nguyen"), "The typed name should land in full.")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 5), .completed, "Typing the name turns Delete on.")
        confirm.tap()
        if alert.exists {
            confirm.tap()
        }

        XCTAssertTrue(app.row("Reed, Marcus").waitForExistence(timeout: 5),
                      "The list should still be on screen after the delete.")
        XCTAssertEqual(app.state, .runningForeground, "Deleting a customer must never crash the app.")
        XCTAssertTrue(app.row("Nguyen, Sofia").waitForNonExistence(timeout: 5), "The deleted customer should leave the list.")
    }
}
