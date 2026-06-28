//
//  SessionChangesUITests.swift
//  GLSmallBusinessUITests
//
//  UI automation for the interactive changes a unit test can't reach: phone auto-dashing (#5), the
//  unsaved-changes guard (#7), the per-line discount control (#6), and the receipt form's Job picker +
//  photo upload (#2/#3). Runs in the harness (no macOS permission prompt), in demo mode.
//

import XCTest

final class SessionChangesUITests: GLUITestCase {

    // #5 — auto-dash, AND robustness: typeText sends all 10 digits faster than any human, which used to
    // drop a digit with the old SwiftUI .onChange reformat. PhoneTextField formats atomically, so this
    // (the original failing case) must now produce the full number — no character dropped.
    func testPhoneFieldAutoDashesWithoutDroppingDigits() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["More"].tap()
        app.buttons["New Customer"].tap()

        let phone = app.textFields["Phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "The New Customer form should have a Phone field.")
        phone.tap()
        phone.typeText("5551234567")
        XCTAssertEqual(phone.value as? String, "555-123-4567",
                       "Typing 10 digits should auto-format to 555-123-4567 with no digit lost.")
    }

    // #7 — editing a form then going Back prompts to discard, and confirming leaves the form. The PROMPT
    // is the data-loss protection; without the guard a stray swipe-back would have silently discarded.
    func testUnsavedChangesGuardPromptsAndDiscardLeaves() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["More"].tap()
        app.buttons["New Customer"].tap()

        let firstName = app.textFields["First name"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        firstName.tap()
        firstName.typeText("Dirty")

        let back = app.buttons["discardBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5),
                      "Editing should swap in the discard-guard Back button.")
        back.tap()

        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5),
                      "Going back with unsaved edits should prompt to discard.")
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.navigationBars["Customers"].waitForExistence(timeout: 5),
                      "Confirming discard should leave the form.")
    }

    // #7 — a form with NO edits navigates back normally (no guard button, no prompt).
    func testCleanFormHasNoDiscardGuard() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["More"].tap()
        app.buttons["New Customer"].tap()
        XCTAssertTrue(app.navigationBars["New Customer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discardBackButton"].exists,
                       "An untouched form should not show the discard-guard Back button.")
    }

    // #6 — the per-line discount control is present in the estimate line editor.
    func testEstimateLineItemHasDiscountControl() {
        app.tabBars.buttons["Customers"].tap()
        app.staticTexts["Carter, Danielle"].tap()
        app.staticTexts["Estimates"].tap()
        app.buttons["More"].tap()
        app.buttons["New Estimate"].tap()
        XCTAssertTrue(app.textFields["Job title"].waitForExistence(timeout: 5),
                      "New Estimate should open the estimate form.")

        let picker = app.buttons["lineDiscountPicker"].firstMatch
        var swipes = 0
        while !picker.exists && swipes < 5 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(picker.exists, "#6: each line item should have a discount control.")
    }

    // #2 + #3 — the receipt form (created from scratch) has a Job picker and a photo-upload option.
    func testReceiptFormHasJobPickerAndPhotoUpload() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
        app.staticTexts["All Receipts"].tap()
        let receiptsBar = app.navigationBars["All Receipts"]
        XCTAssertTrue(receiptsBar.waitForExistence(timeout: 5))

        // The add control is "More" when receipts exist (demo has some), else "Add Receipt".
        let addButton = receiptsBar.buttons["More"].exists ? receiptsBar.buttons["More"]
                                                           : receiptsBar.buttons["Add Receipt"]
        addButton.tap()
        app.buttons["Add Manually"].tap()

        XCTAssertTrue(app.navigationBars["New Receipt"].waitForExistence(timeout: 5),
                      "Add Manually should open the receipt form.")
        XCTAssertTrue(app.buttons["Upload a photo of the receipt"].waitForExistence(timeout: 5),
                      "#3: the receipt form should offer a photo upload.")
        let jobPicker = app.buttons["receiptJobPicker"].firstMatch
        var swipes = 0
        while !jobPicker.exists && swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(jobPicker.exists, "#2: the receipt form should have a Job picker.")
    }
}
