//
//  IPadSelectionResetUITests.swift
//  GLSmallBusinessUITests
//
//  iPad split view (F23, 2026-10-03 QA): a screen pushed in the detail column for person A
//  (the Edit form, Log Hours, More Info) must close when person B is picked in the middle
//  column. Before the fix the detail root kept its identity across the pick, so A's Edit form
//  stayed up over B with Save live, and Save wrote A's details onto B (Log Hours: A's rate
//  logged for B). Every leg picks B with the push still open and then checks that the push is
//  gone, B's own detail shows, and A's record is unchanged.
//
//  iPad only: the split view is the iPad shell (RootView keys the shell on the device).
//

import XCTest

final class IPadSelectionResetUITests: GLUITestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        super.setUp()
        // Landscape keeps all three columns on screen, so the middle column can be tapped while
        // a push is open in the detail column (the gesture the finding describes).
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Customer A's Edit form is open; picking customer B closes it and shows B. A keeps its name
    /// and B keeps its own (HEAD: the form stayed, and its Save renamed B to A).
    func testCustomerEditFormClosesWhenAnotherCustomerIsPicked() throws {
        try XCTSkipUnless(isPad, "The split view's detail column exists on iPad only.")
        pick("Reed, Marcus")
        openMoreMenuItem("Edit")
        let editBar = app.glNavBar("Edit Customer")
        XCTAssertTrue(editBar.waitForExistence(timeout: 5), "Edit should open A's form. \(app.visibleSummary())")
        attachShot("1-customer-A-edit-open")

        pick("Nguyen, Sofia")
        let formStayed = editBar.waitForExistence(timeout: 2)
        attachShot("2-customer-B-picked")
        if formStayed {
            // Show the damage the open form does: its Save writes A's details onto B.
            app.navigationBars.buttons["Save"].firstMatch.tap()
        }
        XCTAssertFalse(formStayed, "Picking another customer must close the open Edit form (it stayed over B).")
        XCTAssertTrue(app.glNavBar("Nguyen, Sofia").waitForExistence(timeout: 5),
                      "B's own detail should show. \(app.visibleSummary())")
        XCTAssertTrue(app.staticTexts["Reed, Marcus"].exists, "Customer A keeps its name.")
        XCTAssertTrue(app.staticTexts["Nguyen, Sofia"].exists, "Customer B keeps its own name.")
    }

    /// Employee A's Log Hours form is open; picking employee B closes it (HEAD: it stayed, and
    /// its Save logged hours for B at A's rate).
    func testEmployeeLogHoursClosesWhenAnotherEmployeeIsPicked() throws {
        try XCTSkipUnless(isPad, "The split view's detail column exists on iPad only.")
        openSegment("Employees")
        pick("Caldwell, Owen")
        let logHours = app.buttons["Log hours"]
        XCTAssertTrue(app.scrollUntilHittable(logHours), "A's payroll card should offer Log hours. \(app.visibleSummary())")
        logHours.tap()
        let formBar = app.glNavBar("Log Hours")
        XCTAssertTrue(formBar.waitForExistence(timeout: 5), "Log hours should open A's form. \(app.visibleSummary())")
        attachShot("1-employee-A-log-hours-open")

        pick("Whitfield, Hannah")
        let formStayed = formBar.waitForExistence(timeout: 2)
        attachShot("2-employee-B-picked")
        XCTAssertFalse(formStayed, "Picking another employee must close the open Log Hours form (it stayed over B).")
        XCTAssertTrue(app.glNavBar("Whitfield, Hannah").waitForExistence(timeout: 5),
                      "B's own detail should show. \(app.visibleSummary())")
    }

    /// A plain push (More Info) from customer A closes when customer B is picked.
    func testCustomerMoreInfoPushClosesWhenAnotherCustomerIsPicked() throws {
        try XCTSkipUnless(isPad, "The split view's detail column exists on iPad only.")
        pick("Reed, Marcus")
        let moreInfo = app.buttons["More Info"]
        XCTAssertTrue(moreInfo.waitForExistence(timeout: 5), "A's hub should offer More Info. \(app.visibleSummary())")
        moreInfo.tap()
        let moreInfoBar = app.glNavBar("More Info")
        XCTAssertTrue(moreInfoBar.waitForExistence(timeout: 5), "More Info should open. \(app.visibleSummary())")

        pick("Nguyen, Sofia")
        let pushStayed = moreInfoBar.waitForExistence(timeout: 2)
        attachShot("customer-B-picked-over-more-info")
        XCTAssertFalse(pushStayed, "Picking another customer must close A's More Info.")
        XCTAssertTrue(app.glNavBar("Nguyen, Sofia").waitForExistence(timeout: 5),
                      "B's own detail should show. \(app.visibleSummary())")
    }

    // MARK: - Helpers

    /// Taps a person's row in the middle column and waits for their detail to show.
    private func pick(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The column should list \(name). \(app.visibleSummary())",
                      file: file, line: line)
        row.tap()
    }

    private func openSegment(_ segment: String) {
        let control = app.segmentedControls.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "The Contacts segmented control should show.")
        control.buttons[segment].tap()
    }

    /// Opens the detail's ••• menu and taps one of its items.
    private func openMoreMenuItem(_ item: String) {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "The detail should show its More menu. \(app.visibleSummary())")
        more.tap()
        let entry = app.buttons[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The More menu should offer \(item).")
        entry.tap()
    }

    private func attachShot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
