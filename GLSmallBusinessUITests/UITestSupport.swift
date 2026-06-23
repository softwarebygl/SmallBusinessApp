//
//  UITestSupport.swift
//  GLSmallBusinessUITests
//
//  Base for every UI test. Launches the app in demo mode, which seeds a known dataset and skips the
//  paywall, so every test starts from the same screen with the same data.
//

import XCTest

class GLUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
        app.launch()
    }
}
