//
//  SessionChangesUITests.swift
//  GLSmallBusinessUITests
//
//  UI automation for the interactive changes a unit test can't reach: phone auto-dashing (#5), the
//  unsaved-changes guard (#7), the per-line discount control (#6), and the receipt form's Job picker +
//  photo upload (#2/#3). Runs in the harness (no macOS permission prompt), in demo mode.
//

import UIKit
import XCTest

final class SessionChangesUITests: GLUITestCase {

    func testCustomerFormCleanBackPhoneAutoDashAndDiscardGuard() {
        app.openContacts("Customers")
        app.buttons["Add Customer"].tap()
        XCTAssertTrue(app.glNavBar("New Customer").waitForExistence(timeout: 5))

        // #7 — an untouched form has no discard-guard Back button.
        XCTAssertFalse(app.buttons["discardBackButton"].exists,
                       "An untouched form should not show the discard-guard Back button.")

        // #5 — phone auto-dashing without dropping digits.
        let phone = app.textFields["Phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "The New Customer form should have a Phone field.")
        XCTAssertTrue(phone.tapForKeyboardFocus(), "Tapping Phone should give it the keyboard.")
        phone.typeText("5551234567")
        phone.waitForValue("555-123-4567")
        XCTAssertEqual(phone.value as? String, "555-123-4567",
                       "Typing 10 digits should auto-format to 555-123-4567 with no digit lost.")

        // #7 — editing a form then going Back prompts to discard, and confirming leaves the form.
        let back = app.buttons["discardBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5),
                      "Editing should swap in the discard-guard Back button.")
        back.tap()

        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5),
                      "Going back with unsaved edits should prompt to discard.")
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.glNavBar("Customers").waitForExistence(timeout: 5),
                      "Confirming discard should leave the form.")
    }

    // #6 — the per-line discount control is present in the estimate line editor.
    func testEstimateLineItemHasDiscountControl() {
        app.openContacts("Customers")
        app.staticTexts["Carter, Danielle"].tap()
        app.staticTexts["Estimates"].tap()
        // LAW 40: "+" (a11y "New Estimate") is a direct navbar button now, no "More" menu.
        app.buttons["New Estimate"].tap()
        XCTAssertTrue(app.textFields["Job title"].waitForExistence(timeout: 5),
                      "New Estimate should open the estimate form.")

        // Presence is the contract here (nothing is tapped), so the assertion stays on it.
        let picker = app.buttons["lineDiscountPicker"].firstMatch
        app.scrollUntilHittable(picker, maxSwipes: 5)
        XCTAssertTrue(picker.exists, "#6: each line item should have a discount control.")
    }

    // Tax ID (SSN/EIN) — same atomic-formatting fix as phone: typing 9 digits at once must keep them
    // all (a dropped SSN/EIN digit would silently produce a wrong tax ID on the 1099).
    func testTaxIdFieldFormatsWithoutDroppingDigits() {
        app.openContacts("Subcontractors")
        // LAW 40: the subcontractors "..." became the 1099-report menu; add is the direct "+"
        // button (a11y "Add Subcontractor").
        app.buttons["Add Subcontractor"].tap()
        XCTAssertTrue(app.glNavBar("New Subcontractor").waitForExistence(timeout: 5))

        // The Tax ID is masked behind Face ID; scroll it into view and reveal it first (demo mode
        // bypasses the biometric prompt). Scrolled to hittable, not merely present, so the tap can't
        // land on a pre-rendered-but-off-screen row and miss.
        let reveal = app.buttons["taxIdRevealButton"]
        XCTAssertTrue(app.scrollUntilHittable(reveal),
                      "The Tax ID reveal control should be on screen. \(app.visibleSummary())")
        // Coordinate tap: a small .plain button in a LabeledContent value slot doesn't always fire from
        // a plain element .tap() under XCUITest, so hit its center point directly.
        reveal.tap()

        let tin = app.textFields["tinField"]
        XCTAssertTrue(tin.waitForExistence(timeout: 5), "Revealing should show the Tax ID field.")
        XCTAssertTrue(tin.tapForKeyboardFocus(), "Tapping the Tax ID field should give it the keyboard.")
        tin.typeText("987654321")   // distinct from the SSN placeholder so the assert is meaningful
        tin.waitForValue("987-65-4321")   // same read-after-typeText race as the phone test
        XCTAssertEqual(tin.value as? String, "987-65-4321",
                       "Typing 9 digits should format as an SSN with no digit dropped.")
    }

    // #2 + #3 — the receipt form (created from scratch) has a Job picker and a photo-upload option.
    func testReceiptFormHasJobPickerAndPhotoUpload() {
        app.openContacts("Customers")
        app.buttons["Menu"].tap()
        // Job Records moved into Business -> All Documents (owner restructure 2026-08-22);
        // the receipts row and screen were renamed "All Expenses" (IA audit 2026-09-01).
        app.tapMenuRow("My Business Details")
        app.tapMenuRow("Documents")
        app.tapMenuRow("All Expenses")
        let receiptsBar = app.glNavBar("All Expenses")
        XCTAssertTrue(receiptsBar.waitForExistence(timeout: 5))

        // The add control is ALWAYS the "+" menu (a11y "Add Receipt") — it no longer mutates
        let addReceipt = app.buttons["Add Receipt"]
        XCTAssertTrue(addReceipt.waitForExistence(timeout: 5))
        addReceipt.tap()
        let addManually = app.buttons["Add Manually"]
        XCTAssertTrue(addManually.waitForExistence(timeout: 5))
        addManually.tap()

        XCTAssertTrue(app.glNavBar("New Receipt").waitForExistence(timeout: 5),
                      "Add Manually should open the receipt form.")
        XCTAssertTrue(app.buttons["Upload a photo of the receipt"].waitForExistence(timeout: 5),
                      "#3: the receipt form should offer a photo upload.")
        // Presence is the contract here (nothing is tapped), so the assertion stays on it.
        let jobPicker = app.buttons["receiptJobPicker"].firstMatch
        app.scrollUntilHittable(jobPicker, maxSwipes: 4)
        XCTAssertTrue(jobPicker.exists, "#2: the receipt form should have a Job picker.")
    }

    // Menu ▸ Payments ▸ Connect Stripe & Connect Zelle, plus the Connect Zelle form and default toggle.
    func testConnectZelleMenuAndScreen() {
        app.openContacts("Customers")
        app.buttons["Menu"].tap()

        let zelleRow = app.row("Connect Zelle")
        XCTAssertTrue(app.scrollUntilHittable(zelleRow, maxSwipes: 5),
                      "Menu should show Connect Zelle under Payments. \(app.visibleSummary())")
        XCTAssertTrue(app.row("Connect Stripe").exists,
                      "Menu should show Connect Stripe alongside Connect Zelle.")

        let menuShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuShot.name = "session-menu-payments"
        menuShot.lifetime = .keepAlways
        add(menuShot)

        zelleRow.tap()
        XCTAssertTrue(app.glNavBar("Connect Zelle").waitForExistence(timeout: 5),
                      "Tapping Connect Zelle should open the Connect Zelle screen.")

        let tagField = app.textFields["Zelle name or tag"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5))
        XCTAssertTrue(tagField.tapForKeyboardFocus())
        tagField.typeText("@goldlifetile")
        tagField.waitForValue("@goldlifetile")
        XCTAssertEqual(tagField.value as? String, "@goldlifetile")

        let emailField = app.textFields["Zelle email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        XCTAssertTrue(emailField.tapForKeyboardFocus())
        emailField.typeText("pay@goldlifellc.com")
        emailField.waitForValue("pay@goldlifellc.com")
        XCTAssertEqual(emailField.value as? String, "pay@goldlifellc.com")

        let phoneField = app.textFields["Zelle phone number"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 5))
        XCTAssertTrue(phoneField.tapForKeyboardFocus())
        phoneField.typeText("5551234567")
        phoneField.waitForValue("555-123-4567")
        XCTAssertEqual(phoneField.value as? String, "555-123-4567")

        let defaultToggle = app.switches["Add Zelle by default"]
        XCTAssertTrue(defaultToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(defaultToggle.isEnabled, "Entering Zelle details should enable Add Zelle by default.")
        defaultToggle.tap()

        let zelleShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        zelleShot.name = "session-connect-zelle"
        zelleShot.lifetime = .keepAlways
        add(zelleShot)
    }
}
