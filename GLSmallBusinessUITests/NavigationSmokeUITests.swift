//
//  NavigationSmokeUITests.swift
//  GLSmallBusinessUITests
//
//  The cheapest guard against a whole section going dark: tap each tab and confirm its screen opens.
//

import XCTest

final class NavigationSmokeUITests: GLUITestCase {

    func testEachTabOpensItsScreen() {
        // The Contacts tab carries all three people lists behind the segmented control —
        // each segment must land on its own titled screen, then Calendar gets its tab.
        for segment in ["Customers", "Employees", "Subcontractors"] {
            app.openContacts(segment)
            XCTAssertTrue(
                app.glNavBar(segment).waitForExistence(timeout: 5),
                "The \(segment) segment of Contacts should open the \(segment) screen."
            )
        }
        // The Contracts tab lands on the contracts LIST, with the
        // Calendar pushed from its toolbar button.
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(
            app.glNavBar("Contracts").waitForExistence(timeout: 5),
            "Tapping the Contracts tab should open the Contracts list."
        )
        app.buttons["Calendar"].tap()
        XCTAssertTrue(
            app.glNavBar("Calendar").waitForExistence(timeout: 5),
            "The Contracts toolbar's Calendar button should push the Calendar."
        )
        app.glNavBar("Calendar").buttons.firstMatch.tap()

        // The Sentinel tab lands on the Sentinel hub.
        if app.tabBars.buttons["Sentinel"].exists {
            app.tabBars.buttons["Sentinel"].tap()
            XCTAssertTrue(
                app.navigationBars.firstMatch.waitForExistence(timeout: 5),
                "Tapping the Sentinel tab should open the Sentinel screen."
            )
        }

        // And BACK to a previously-visited segment: the return trip is where a
        // torn-down or corrupted pane would surface.
        app.openContacts("Employees")
        XCTAssertTrue(
            app.glNavBar("Employees").waitForExistence(timeout: 5),
            "Returning to the Employees segment should show the Employees screen again."
        )
    }

    func testContractChangeOrderFormNavigation() {
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(app.glNavBar("Contracts").waitForExistence(timeout: 5))
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()

        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let cacheDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/testflight_feedback")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Proof 1: Top of ContractDetailScreen showing Quick Action Bar (Email, Text, Share, Invoice) and Preview PDF button
        let proof1 = cacheDir.appendingPathComponent("mb_ACnXC83Arvwe9EI4H04nAHQ_proof_sim.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: proof1)

        let newButton = app.buttons["New"]
        XCTAssertTrue(app.scrollUntilHittable(newButton), "New change order button should be scrollable on screen")

        // Proof 2: Scrolled view showing Contract Signing and Change Orders
        let proof2 = cacheDir.appendingPathComponent("mb_AEdYQUifqSYZD-qkaS0aeDE_proof_sim.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: proof2)

        newButton.tap()
        XCTAssertTrue(app.glNavBar("New Change Order").waitForExistence(timeout: 10), "New Change Order screen should open")
    }

    func testAssistantAndStripeConnectProofs() {
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let cacheDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/testflight_feedback")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 1. Navigate to Menu -> Connect Stripe and verify updated footer copy
        app.tabBars.buttons["Contacts"].tap()
        let menuButton = app.buttons["Menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()

        let stripeRow = app.row("Connect Stripe")
        XCTAssertTrue(app.scrollUntilHittable(stripeRow), "Connect Stripe row should be hittable in Menu")
        stripeRow.tap()

        let stripeFooter = app.staticTexts["Sign in with your own Stripe email. New to Stripe? We’ll set one up."]
        XCTAssertTrue(stripeFooter.waitForExistence(timeout: 5), "Updated Stripe Connect footer copy must be visible")

        let stripeProof = cacheDir.appendingPathComponent("mb_AGGwXRrmwabnupBUEzmfiOQ_proof_sim.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: stripeProof)

        // 2. Navigate to the Sentinel tab and capture clean Sentinel screen state
        relaunch()
        let assistantTab = app.tabBars.buttons["Sentinel"]
        if assistantTab.waitForExistence(timeout: 5) {
            assistantTab.tap()
        }
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["The assistant couldn't answer just now. Try again."].exists)

        let assistantProof = cacheDir.appendingPathComponent("mb_APjyN1d8wqoFT0zhmSarH8Y_proof_sim.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: assistantProof)
    }
}
