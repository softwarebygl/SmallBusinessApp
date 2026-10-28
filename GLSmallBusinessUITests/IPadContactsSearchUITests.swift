//
//  IPadContactsSearchUITests.swift
//  GLSmallBusinessUITests
//
//  iPad Contacts search (F52, 2026-10-03 QA): the iPad split's Customers column carries the same
//  in-list search row as the iPhone list, under the Contacts picker, and typing filters the
//  column. Before the fix the column had no search at all, so an iPad owner with 200 customers
//  could only scroll.
//
//  iPad only: the split view is the iPad shell (RootView keys the shell on the device).
//

import XCTest

final class IPadContactsSearchUITests: GLUITestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        super.setUp()
        // Landscape keeps the middle column on screen beside the detail.
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Typing "car" in the Customers column leaves Danielle Carter and drops the others.
    func testTypingFiltersTheCustomersColumn() throws {
        try XCTSkipUnless(isPad, "The split view's Contacts column exists on iPad only.")
        let carter = app.staticTexts["Carter, Danielle"].firstMatch
        let reed = app.staticTexts["Reed, Marcus"].firstMatch
        XCTAssertTrue(carter.waitForExistence(timeout: 10), "The demo column should list Danielle Carter. \(app.visibleSummary())")
        XCTAssertTrue(reed.exists, "The demo column should list Marcus Reed. \(app.visibleSummary())")

        let search = app.textFields["inListSearchField"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The Customers column should show its search field. \(app.visibleSummary())")
        XCTAssertEqual(search.placeholderValue, "Search customers")
        XCTAssertTrue(search.tapForKeyboardFocus(), "The search field should take the keyboard.")
        search.typeText("car")
        XCTAssertTrue(search.waitForValue("car"), "The query should land in full.")

        XCTAssertTrue(carter.waitForExistence(timeout: 5), "Danielle Carter matches 'car'.")
        let reedGone = NSPredicate(format: "exists == false")
        expectation(for: reedGone, evaluatedWith: app.cells.containing(.staticText, identifier: "Reed, Marcus").firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Nguyen, Sofia").firstMatch.exists,
                       "Sofia Nguyen doesn't match 'car'.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ipad-customers-column-filtered-car"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
