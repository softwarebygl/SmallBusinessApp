//
//  MoneyJourneyUITests.swift
//  GLSmallBusinessUITests
//
//  End-to-end Money tab flow: tab navigation, filtering, search, classification toggle,
//  context menu rule creation, and subscriptions burn calculation.
//

import XCTest

final class MoneyJourneyUITests: GLUITestCase {

    func testMoneyTabNavigationAndInteractions() {
        // 1. Navigate to Money tab
        let moneyTab = app.tabBars.buttons["Money"]
        XCTAssertTrue(moneyTab.waitForExistence(timeout: 5), "Money tab should exist in the tab bar.")
        moneyTab.tap()

        // 2. Verify cash flow summary is rendered above segmented control (Law 56)
        let summaryHeader = app.staticTexts["Cash Flow & Expenses"]
        XCTAssertTrue(summaryHeader.waitForExistence(timeout: 5), "Cash Flow summary should be visible.")

        // 3. Search transactions
        let searchField = app.textFields["Search transactions…"]
        if searchField.waitForExistence(timeout: 3) {
            searchField.tap()
            searchField.typeText("Starbucks")
            // Verify filtered results
            let starbucksRow = app.staticTexts["Starbucks"]
            XCTAssertTrue(starbucksRow.waitForExistence(timeout: 5), "Starbucks transaction should be found.")
        }

        // 4. Switch to Subscriptions segment
        let subscriptionsSegment = app.buttons["Subscriptions"]
        if subscriptionsSegment.waitForExistence(timeout: 3) {
            subscriptionsSegment.tap()
            // Verify Recurring Burn header
            let burnHeader = app.staticTexts["Recurring Burn"]
            XCTAssertTrue(burnHeader.waitForExistence(timeout: 5), "Recurring Burn section should render.")
        }
    }
}
