//
//  SwipeDeleteUITests.swift
//  GLSmallBusinessUITests
//
//  REQUIREMENTS law 8, "The swipe only asks": swipe → Delete shows the alert while the row is
//  still listed; Cancel keeps it; Delete removes it and the app stays up. The lists used
//  `.onDelete` (and the Price Sheet a destructive full swipe), which pull the row the moment
//  Delete is tapped — the 2026-09-26 iPhone Customers crash ("Invalid number of items in
//  section") came from exactly that. SwipeDeleteRoutingTests pins every list's code; these drive
//  the real thing on one alert list, the one list that never asked, and the iPad column.
//

import XCTest

final class SwipeDeleteUITests: GLUITestCase {

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// iPhone Customers → Marcus Reed → Estimates: swipe EST-0001, Delete asks first.
    func testEstimateSwipeDeleteAsksFirstAndKeepsTheRowUntilConfirmed() throws {
        try XCTSkipIf(isPad, "The iPhone Estimates path; the iPad column has its own test.")
        app.openContacts("Customers")
        app.row("Reed, Marcus").tap()
        let estimates = app.staticTexts["Estimates"]
        XCTAssertTrue(app.scrollUntilHittable(estimates), "Marcus Reed's detail should list Estimates.")
        estimates.tap()
        XCTAssertTrue(app.glNavBar("Estimates").waitForExistence(timeout: 5),
                      "The customer's Estimates list should open.")

        let row = app.staticTexts["EST-0001"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The demo data should list EST-0001.")
        assertSwipeAsksThenDeletes(row: row, alertTitle: "Delete this estimate?") { $0.buttons["Delete"].tap() }
    }

    /// iPhone Customers → Danielle Carter → Invoices: swipe INV-0001 (deposit paid, so not
    /// locked), Delete asks first. Invoice rows read the invoice's totals, which is what crashed
    /// the Estimates list one render after a confirmed delete (EstimateLineItem.discountType).
    func testInvoiceSwipeDeleteAsksFirstAndKeepsTheRowUntilConfirmed() throws {
        try XCTSkipIf(isPad, "The iPhone Invoices path.")
        app.openContacts("Customers")
        app.row("Carter, Danielle").tap()
        let invoices = app.staticTexts["Invoices"]
        XCTAssertTrue(app.scrollUntilHittable(invoices), "Danielle Carter's detail should list Invoices.")
        invoices.tap()
        XCTAssertTrue(app.glNavBar("Invoices").waitForExistence(timeout: 5),
                      "The customer's Invoices list should open.")

        // An invoice with recorded payments is protected from deletion (C25).
        let paidRow = app.staticTexts["INV-0001"]
        XCTAssertTrue(paidRow.waitForExistence(timeout: 5), "The demo data should list INV-0001.")
        paidRow.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5))
        swipeDelete.tap()
        let refusalAlert = app.alerts.firstMatch
        XCTAssertTrue(refusalAlert.waitForExistence(timeout: 5), "Payments should block deletion.")
        refusalAlert.buttons["OK"].tap()

        // Create an unpaid invoice to verify swipe delete on an invoice without payments asks first and deletes.
        app.buttons["New Invoice"].tap()
        let jobTitle = app.textFields["Job title"]
        XCTAssertTrue(jobTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(jobTitle.tapForKeyboardFocus())
        jobTitle.typeText("Test Grout")
        app.buttons["Save"].tap()

        let row = app.staticTexts["Test Grout"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The saved invoice should be listed.")
        assertSwipeAsksThenDeletes(row: row, alertTitle: "Delete this invoice?") { $0.buttons["Delete"].tap() }
    }

    /// Price Sheet: a catalog item can't be recovered, so the swipe must ask (F71). It was a
    /// destructive full swipe that deleted on the spot.
    func testPriceSheetSwipeDeleteAsksFirst() throws {
        try XCTSkipIf(isPad, "The iPhone Menu path.")
        app.openRecordsHub()
        app.openRecordsList("Price Sheet")
        let addFirst = app.buttons["Add First Item"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 5), "The demo Price Sheet should start empty.")
        addFirst.tap()
        let name = app.textFields["Service or item name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "The New Catalog Item form should open.")
        XCTAssertTrue(name.tapForKeyboardFocus(), "The name field should take the keyboard.")
        name.typeText("Uitest Grout")
        XCTAssertTrue(name.waitForValue("Uitest Grout"), "The name should land in full.")
        app.buttons["Save"].tap()

        let row = app.staticTexts["Uitest Grout"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The saved item should be listed.")
        assertSwipeAsksThenDeletes(row: row, alertTitle: "Delete this item?") { $0.buttons["Delete"].tap() }
    }

    /// iPad Contacts → Customers column (every iPad gets the split view): swipe → Delete →
    /// type the name → Delete removes the customer and the app stays up. This column kept
    /// `.onDelete` after the iPhone list was fixed in build 84.
    func testIPadCustomersColumnSwipeDeleteAsksFirstWithoutCrashing() throws {
        try XCTSkipUnless(isPad, "The iPad split view's Customers column runs on iPad only.")
        let row = app.staticTexts["Nguyen, Sofia"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The demo Customers column should list Sofia Nguyen.")
        // The typed-name alert is titled with the name itself, so it is found as the one alert up.
        assertSwipeAsksThenDeletes(row: row, alertTitle: nil) { alert in
            let field = alert.textFields.firstMatch
            XCTAssertTrue(field.tapForKeyboardFocus(), "The name field should take the keyboard.")
            field.typeText("Sofia Nguyen")
            XCTAssertTrue(field.waitForValue("Sofia Nguyen"), "The typed name should land in full.")
            let confirm = alert.buttons["Delete"]
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: confirm)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 5), .completed, "Typing the name turns Delete on.")
            confirm.tap()
        }
        XCTAssertTrue(app.staticTexts["Reed, Marcus"].waitForExistence(timeout: 5),
                      "The column should still be on screen after the delete.")
    }

    // MARK: - The one shape every swipe delete must have

    /// Swipe → Delete: the alert is up and the row is STILL listed. Cancel: the row stays.
    /// Swipe → Delete → `confirm`: the row goes and the app is still running.
    private func assertSwipeAsksThenDeletes(row: XCUIElement, alertTitle: String?,
                                            file: StaticString = #filePath, line: UInt = #line,
                                            confirm: (XCUIElement) -> Void) {
        let cell = app.cells.containing(.staticText, identifier: row.label).firstMatch
        let target = cell.exists ? cell : row
        target.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "The swipe should reveal Delete.", file: file, line: line)
        swipeDelete.tap()

        let alert = alertTitle.map { app.alerts[$0] } ?? app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "Delete should ask first (\(alertTitle ?? "typed name")). \(app.visibleSummary())", file: file, line: line)
        XCTAssertTrue(row.exists, "The row must stay listed while the alert asks (law 8).", file: file, line: line)
        // The proof shot: the alert up, the row still under it.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "swipe-delete-alert \(alertTitle ?? "typed name")"
        shot.lifetime = .keepAlways
        add(shot)
        alert.buttons["Cancel"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "Cancel should close the alert.", file: file, line: line)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Cancel must keep the row.", file: file, line: line)

        target.swipeLeft()
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "The swipe should reveal Delete again.", file: file, line: line)
        swipeDelete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete should ask again.", file: file, line: line)
        confirm(alert)

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed,
                       "The confirmed delete should remove the row.", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "A swipe delete must never crash the app.", file: file, line: line)
    }
}
