//
//  SampleMenuExitUITests.swift
//  GLSmallBusinessUITests
//
//  Audit 2026-10-03 F36, on screen. From the gate's "Explore with sample data" the Menu ends
//  with "Exit Sample Mode", and Exit returns to the gate.
//  The old Menu showed a greyed-out "Sign out" there, with no way out of the sample. The Gold
//  Life ID card in the sample shows the sample person with no Edit and no Delete.
//
//  This suite launches WITHOUT `-demoMode`: that DEBUG harness skips the gate, and the gate's
//  sample door is the Release path this test is about. The simulator must be signed out.
//

import XCTest

final class SampleMenuExitUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // The base flags minus `-demoMode` (GLUITestCase.baseLaunchArguments).
        app.launchArguments = ["-uiTestNoAnimations", "-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        app.launch()
    }

    override func tearDown() {
        if (testRun?.totalFailureCount ?? 0) > 0, let app, app.state != .notRunning {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "a11y-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        super.tearDown()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheMenuOffersExitSampleModeAndExitReturnsToTheGate() {
        let sampleDoor = app.buttons["Explore with sample data"]
        let banner = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Exploring sample data")).firstMatch
        // A sample session left running by an earlier launch re-opens in the sample; otherwise
        // the gate shows the door.
        if !banner.waitForExistence(timeout: 3) {
            XCTAssertTrue(sampleDoor.waitForExistence(timeout: 15),
                          "The gate should offer sample data (is the simulator signed in?). \(app.visibleSummary())")
            sampleDoor.tap()
            XCTAssertTrue(banner.waitForExistence(timeout: 15), "the sample should open. \(app.visibleSummary())")
        }

        // The sample opens on Contacts; the gate's hand-off can briefly hold two tab bars, so
        // the first match is the one on screen.
        let contacts = app.tabBars.buttons["Contacts"].firstMatch
        XCTAssertTrue(contacts.waitForExistence(timeout: 10), "the tab bar should show. \(app.visibleSummary())")
        contacts.tap()
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the Menu button should show. \(app.visibleSummary())")
        menu.tap()

        // The Gold Life ID card in the sample: the sample person, no Edit, but Delete row is visible (Guideline 5.1.1(v)).
        let pill = app.buttons["Gold Life ID"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the Gold Life ID pill should show. \(app.visibleSummary())")
        pill.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        attach("sample-gold-life-id")
        XCTAssertFalse(app.navigationBars.buttons["Edit"].exists, "Edit must not be live in the sample")

        let deleteRow = app.buttons["Delete my Gold Life ID"]
        if !deleteRow.exists {
            _ = app.scrollUntilHittable(deleteRow)
        }
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5), "Delete my Gold Life ID row must show in sample mode (Guideline 5.1.1(v))")
        deleteRow.tap()

        let sampleMsg = app.staticTexts["goldLifeID.deletion.sampleModeMessage"]
        XCTAssertTrue(sampleMsg.waitForExistence(timeout: 5), "Sample deletion disclosure message must be visible")

        let sampleSignIn = app.buttons["goldLifeID.deletion.sampleModeSignInButton"]
        XCTAssertTrue(sampleSignIn.waitForExistence(timeout: 5), "Sign In CTA button must be visible")

        // 1. Verify tapping "Sign In" directly exits sample mode back to the 3 Doors gate without crashing
        sampleSignIn.tap()
        XCTAssertTrue(sampleDoor.waitForExistence(timeout: 10),
                      "Tapping Sign In on sample deletion card should return immediately to gate. \(app.visibleSummary())")

        // 2. Re-enter sample mode to verify Menu's canonical Exit Sample Mode button and alert
        sampleDoor.tap()
        let contactsAgain = app.tabBars.buttons["Contacts"].firstMatch
        XCTAssertTrue(contactsAgain.waitForExistence(timeout: 10),
                      "Re-entering sample mode should show Contacts tab")

        let menuButtonAgain = app.buttons["Menu"]
        XCTAssertTrue(menuButtonAgain.waitForExistence(timeout: 5), "Menu button should exist")
        menuButtonAgain.tap()

        let exit = app.buttons["Exit Sample Mode"]
        guard app.scrollUntilHittable(exit) else {
            XCTFail("The Menu should end with Exit Sample Mode. \(app.visibleSummary())")
            return
        }
        XCTAssertFalse(app.buttons["Sign out"].exists, "no greyed-out Sign out in the sample")
        attach("sample-menu-exit")
        XCTAssertTrue(exit.isEnabled, "Exit Sample Mode must be tappable")
        exit.tap()

        let alert = app.alerts["Exit Sample Mode"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Exit should ask first. \(app.visibleSummary())")
        alert.buttons["Exit"].tap()

        XCTAssertTrue(sampleDoor.waitForExistence(timeout: 10),
                      "Exit should return to the gate. \(app.visibleSummary())")
        attach("gate-after-exit")
    }
}
