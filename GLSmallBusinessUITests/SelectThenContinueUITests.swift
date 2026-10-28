//
//  SelectThenContinueUITests.swift
//  GLSmallBusinessUITests
//
//  REQUIREMENTS law 63 (select, then Continue), audit 2026-10-03 F135:
//    - New estimate / New invoice is a step flow (choose a customer, then continue). Tapping a
//      customer only SELECTS it (the selection circle moves, the screen stays put); the pinned
//      Continue is the only way forward and stays disabled until a customer is chosen.
//    - Add to Project is a picker opened from an edit screen: tapping a project selects it, Done
//      applies it, and Close keeps the old choice.
//  Before the fix, a customer tap pushed the form at once and a project tap assigned and closed.
//

import XCTest

final class SelectThenContinueUITests: GLUITestCase {

    // MARK: - Helpers

    private func openNewEstimatePicker() {
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(app.glNavBar("Contracts").waitForExistence(timeout: 5))
        app.buttons["Add"].tap()
        app.buttons["New estimate"].tap()
        XCTAssertTrue(app.glNavBar("New estimate").waitForExistence(timeout: 5),
                      "Contracts + New estimate should open the customer picker. \(app.visibleSummary())")
    }

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func openJob(_ prefix: String) {
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(app.glNavBar("Contracts").waitForExistence(timeout: 5))
        let job = button(beginningWith: prefix)
        XCTAssertTrue(app.scrollUntilHittable(job), "Job \(prefix) should be in the Contracts list. \(app.visibleSummary())")
        job.tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5),
                      "The job detail should open. \(app.visibleSummary())")
    }

    private func openAddToProject() {
        app.buttons["More"].tap()
        let add = app.buttons["Add to project"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "A job with no project offers Add to project. \(app.visibleSummary())")
        add.tap()
        XCTAssertTrue(app.glNavBar("Add to Project").waitForExistence(timeout: 5),
                      "Add to project should open its sheet. \(app.visibleSummary())")
    }

    // MARK: - Customer picker (step flow)

    func testCustomerPickerRequiresSelectionThenContinuePushesTheForm() {
        openNewEstimatePicker()
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "Continue is always visible (pinned).")
        XCTAssertTrue(continueButton.isHittable, "Continue is on screen, never below the fold.")
        XCTAssertFalse(continueButton.isEnabled, "Nothing chosen yet: Continue is disabled.")

        let reed = button(beginningWith: "Reed, Marcus")
        XCTAssertTrue(reed.waitForExistence(timeout: 5), "\(app.visibleSummary())")
        reed.tap()

        // The tap only selects: the screen stays put and the circle is on Reed.
        XCTAssertFalse(app.glNavBar("New Estimate").waitForExistence(timeout: 2),
                       "Tapping a customer must not push the estimate form (law 63).")
        XCTAssertTrue(app.glNavBar("New estimate").exists, "The customer picker should still be showing.")
        XCTAssertTrue(reed.isSelected, "The tapped customer should wear the selected circle.")

        // Another tap moves the circle.
        let carter = button(beginningWith: "Carter, Danielle")
        XCTAssertTrue(carter.waitForExistence(timeout: 5))
        carter.tap()
        XCTAssertTrue(carter.isSelected, "The circle should move to the newly tapped customer.")
        XCTAssertFalse(reed.isSelected, "Only one customer is selected at a time.")

        // Continue is the only way forward.
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
        XCTAssertTrue(app.glNavBar("New Estimate").waitForExistence(timeout: 5),
                      "Continue should push the estimate form. \(app.visibleSummary())")
    }

    // MARK: - Add to Project (picker opened from an edit screen)

    func testProjectPickerSelectsClosesWithoutApplyingThenDoneApplies() {
        openJob("Master Bath")
        openAddToProject()
        let project = button(beginningWith: "Reed kitchen remodel")
        XCTAssertTrue(project.waitForExistence(timeout: 5), "\(app.visibleSummary())")
        project.tap()

        // The tap only selects: the sheet stays up with the circle on the project.
        XCTAssertTrue(app.glNavBar("Add to Project").waitForExistence(timeout: 2),
                      "Tapping a project must not assign and close the sheet (law 63).")
        XCTAssertTrue(project.isSelected, "The tapped project should wear the selected circle.")

        app.buttons["Close"].tap()
        XCTAssertTrue(app.glNavBar("Add to Project").waitForNonExistence(timeout: 5), "Close should dismiss the sheet.")
        app.buttons["More"].tap()
        let addAgain = app.buttons["Add to project"]
        XCTAssertTrue(addAgain.waitForExistence(timeout: 5),
                      "Close keeps the old choice: the job is still in no project. \(app.visibleSummary())")
        XCTAssertFalse(app.buttons["Change project"].exists)

        // Reopen and apply with Done.
        addAgain.tap()
        XCTAssertTrue(app.glNavBar("Add to Project").waitForExistence(timeout: 5))
        let projectAgain = button(beginningWith: "Reed kitchen remodel")
        XCTAssertTrue(projectAgain.waitForExistence(timeout: 5))
        projectAgain.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The sheet should offer Done. \(app.visibleSummary())")
        done.tap()
        XCTAssertTrue(app.glNavBar("Add to Project").waitForNonExistence(timeout: 5), "Done should close the sheet.")
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Change project"].waitForExistence(timeout: 5),
                      "Done applies the choice: the job is now in the project. \(app.visibleSummary())")
    }
}
