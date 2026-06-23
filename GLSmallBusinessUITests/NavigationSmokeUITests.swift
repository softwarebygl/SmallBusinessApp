//
//  NavigationSmokeUITests.swift
//  GLSmallBusinessUITests
//
//  The cheapest guard against a whole section going dark: tap each tab and confirm its screen opens.
//

import XCTest

final class NavigationSmokeUITests: GLUITestCase {

    func testEachTabOpensItsScreen() {
        for tab in ["Customers", "Employees", "Subcontractors", "Calendar"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(
                app.navigationBars[tab].waitForExistence(timeout: 5),
                "Tapping the \(tab) tab should open the \(tab) screen."
            )
        }
    }
}
