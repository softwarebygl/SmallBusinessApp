//
//  LapsedReadOnlyUITests.swift
//  GLSmallBusinessUITests
//
//  The LAPSED app, driven. Until this file existed, nothing in either test target ever launched it
//  — `grep -rc forceLapsed GLSmallBusinessUITests` returned nothing (2026-08-26) — even though
//  `-forceLapsed` was added for exactly this reason: the read-only app is otherwise unreachable
//  without a genuinely expired subscription, so there was no way to LOOK at it, let alone tap it.
//  The unit suite proved the GATE says no to every operation; it could not prove that a control
//  reaches the gate at all, and three that didn't shipped.
//
//  So each test here does the same three things, in order, because two of the three are the ruling:
//    1. tap a control that would WRITE,
//    2. assert the person is told IN PLAIN ENGLISH what stopped and how to undo it,
//    3. assert the write did NOT happen.
//  (3) is what makes these more than screenshot tests. A refusal that explains itself and writes
//  anyway is the worse bug of the two.
//
//  The base launch (`-demoMode`) seeds the dataset; this suite adds `-forceLapsed`, which is read
//  BEFORE the demo bypass in both `SubscriptionManager.isLapsed` and `AccessGate.decide`, so the
//  combination is a lapsed app with records in it. Both are `#if DEBUG` and hard-compiled out of
//  Release.
//

import XCTest

final class LapsedReadOnlyUITests: GLUITestCase {
    override class var extraLaunchArguments: [String] { ["-forceLapsed"] }

    /// The refusal alert, by its title. The title is the one string every refusal shares; the
    /// operation's name lives in the message, which each test asserts for itself.
    private var refusalAlert: XCUIElement {
        app.alerts["Your subscription ended"]
    }

    // MARK: - The app says it is read-only before anyone taps anything

    /// The banner is the half of the ruling that does not wait to be asked. It is what makes the
    /// SILENT refusals defensible — the `.task` polls and first-render bootstraps that log without
    /// alerting — so if it ever stops rendering, those become genuinely silent.
    ///
    /// Matched on a fragment rather than the whole sentence: the copy lives in GoldLifeUI and is
    /// shared across apps, and pinning it verbatim here would make a package-side wording change
    /// fail in the wrong repo. `ReadOnlyGateTests.theCatalogCarriesTheSharedBannerKeys` is where
    /// the exact sentence is pinned, in both languages.
    func testLapsedAppWearsBannerAndRefusesCustomerCreateAndDelete() {
        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "subscription ended"))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15),
                      "A lapsed app must say so on screen without being asked — the banner is missing.")

        app.openContacts("Customers")
        let addCustomer = app.glNavBar("Customers").buttons["Add Customer"]
        XCTAssertTrue(addCustomer.waitForExistence(timeout: 15),
                      "The Customers list should offer its direct + (Add Customer) button.")
        addCustomer.tap()

        XCTAssertTrue(refusalAlert.waitForExistence(timeout: 10),
                      "Tapping Add Customer while lapsed must explain itself, not do nothing.")
        let createExplanation = refusalAlert.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Saving this customer"))
            .firstMatch
        XCTAssertTrue(createExplanation.exists,
                      "The refusal must name the operation in plain English: \(refusalAlert.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(refusalAlert.buttons["Reactivate"].exists,
                      "The refusal must offer the way back, not just the bad news.")

        refusalAlert.buttons["OK"].tap()
        XCTAssertTrue(refusalAlert.waitForNonExistence(timeout: 5),
                      "OK should dismiss the refusal.")
        XCTAssertTrue(addCustomer.isHittable,
                      "After a refused create the Customers list must still be the screen in front. \(app.visibleSummary())")
        XCTAssertFalse(app.glNavBar("New Customer").exists,
                       "A refused create must not still open the form.")

        // Deleting a customer while lapsed must also refuse out loud and leave the row untouched.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Nguyen, Sofia")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The demo customer should be listed.")
        row.swipeLeft()

        let swipeDelete = app.buttons["Delete"]
        guard swipeDelete.waitForExistence(timeout: 5) else {
            XCTFail("A swipe on a customer row should offer Delete.")
            return
        }
        swipeDelete.tap()

        XCTAssertTrue(refusalAlert.waitForExistence(timeout: 10),
                      "Deleting a customer while lapsed must explain itself.")
        let deleteExplanation = refusalAlert.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Deleting this customer"))
            .firstMatch
        XCTAssertTrue(deleteExplanation.exists,
                      "The refusal must name the operation in plain English: \(refusalAlert.staticTexts.allElementsBoundByIndex.map(\.label))")
        refusalAlert.buttons["OK"].tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Nguyen, Sofia")).firstMatch.exists,
                      "the customer was deleted anyway — a lapsed app must do nothing on the owner's behalf")
    }

    // MARK: - Billing an approved change order

    func testLapsedAppRefusesToBillAChangeOrderAndLeavesTheBalanceAlone() {
        relaunch(adding: ["-uiTestChangeOrder"])
        app.openRecordsHub()
        app.openRecordsList("All Invoices")

        let invoiceRow = app.staticTexts["INV-0099"]
        XCTAssertTrue(invoiceRow.waitForExistence(timeout: 15), "fixture invoice INV-0099 not found")
        invoiceRow.tap()

        XCTAssertTrue(app.staticTexts["$700.00"].waitForExistence(timeout: 15),
                      "balance should be $700.00 before anything is added")

        let add = app.buttons["Add to invoice"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "'Add to invoice' button missing")
        XCTAssertTrue(app.scrollUntilHittable(add),
                      "'Add to invoice' should scroll on screen. \(app.visibleSummary())")
        if add.frame.maxY > 750 {
            app.swipeUp()
        }
        add.tap()

        XCTAssertTrue(refusalAlert.waitForExistence(timeout: 10),
                      "Billing a change order while lapsed must explain itself.")
        let explanation = refusalAlert.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Changing this change order"))
            .firstMatch
        XCTAssertTrue(explanation.exists,
                      "The refusal must name the operation in plain English: \(refusalAlert.staticTexts.allElementsBoundByIndex.map(\.label))")
        refusalAlert.buttons["OK"].tap()

        XCTAssertTrue(app.staticTexts["$700.00"].waitForExistence(timeout: 10),
                      "the balance must be untouched after a refused add")
        XCTAssertFalse(app.staticTexts["$900.00"].exists,
                       "the change order was billed anyway — a lapsed app must do nothing on the owner's behalf")
    }
}
