//
//  CoverageExpansionUITests.swift
//  GLSmallBusinessUITests
//
//  Reaches the remaining heavy screens that the other suites don't: an estimate's detail, the new-
//  estimate form, and the Statistics screen. Opening them guards their navigation and exercises a lot
//  of otherwise-untouched view code.
//

import XCTest

final class CoverageExpansionUITests: GLUITestCase {

    func testEstimateDetailOpens() {
        openCarterEstimates()
        app.staticTexts["EST-0002"].tap()
        XCTAssertTrue(app.navigationBars["EST-0002"].waitForExistence(timeout: 5),
                      "Tapping an estimate should open its detail.")
    }

    func testNewEstimateFormOpens() {
        openCarterEstimates()
        app.buttons["More"].tap()
        app.buttons["New Estimate"].tap()
        XCTAssertTrue(app.textFields["Job title"].waitForExistence(timeout: 5),
                      "New Estimate should open the estimate form.")
        app.buttons["Cancel"].tap()
    }

    func testStatisticsOpens() {
        app.tabBars.buttons["Customers"].tap()
        app.buttons["Menu"].tap()
        app.staticTexts["Business"].tap()

        // The Statistics row is near the bottom of the company hub — reveal it before tapping.
        let statsRow = app.staticTexts["Statistics"]
        XCTAssertTrue(statsRow.waitForExistence(timeout: 5))
        if !statsRow.isHittable { app.swipeUp() }
        statsRow.tap()

        // The period picker sits at the top of Statistics and renders regardless of data.
        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5),
                      "Statistics should open with its period picker.")
    }

    /// Customers → Danielle Carter → her Estimates list (she has EST-0002 in the demo data).
    private func openCarterEstimates() {
        app.tabBars.buttons["Customers"].tap()
        app.staticTexts["Carter, Danielle"].tap()
        app.staticTexts["Estimates"].tap()
        XCTAssertTrue(app.navigationBars["Estimates"].waitForExistence(timeout: 5),
                      "The customer's Estimates list should open.")
    }
}
