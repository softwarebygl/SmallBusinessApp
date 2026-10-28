//
//  SearchBehaviorUITests.swift
//  GLSmallBusinessUITests
//
//  How the in-list search behaves, on screen (QA 2026-10-03):
//  - F51: a Price Sheet search with no matches kept "No Results" but dropped the search field
//    itself, so the person couldn't clear it and had to leave the screen.
//  - F129 / L9: All Jobs pushed from All Documents used the system nav-bar search while every
//    other pushed record list uses the in-list search row (law 47a).
//  - F130: the lists with an in-list search field left the keyboard up on scroll and on a tap
//    outside the field (law 9), until some form had happened to install the tap recognizer.
//

import XCTest

final class SearchBehaviorUITests: GLUITestCase {

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// GoldLifeUI's in-list search field (`GLInListSearchHeader`, identifier `inListSearchField`)
    /// with this prompt. Addressed by prompt too: the Customers list under the Menu sheet keeps
    /// its own in-list field in the tree.
    private func inListSearchField(_ prompt: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND placeholderValue == %@", "inListSearchField", prompt)).firstMatch
    }

    /// Any OTHER search field with this prompt: the system `.searchable` one.
    private func systemSearchField(_ prompt: String) -> XCUIElement {
        app.searchFields.matching(NSPredicate(
            format: "identifier != %@ AND placeholderValue == %@", "inListSearchField", prompt)).firstMatch
    }

    private let gutter: CGFloat = 8

    private var searchCapsule: XCUIElement {
        app.otherElements["inListSearchField.capsule"].firstMatch
    }

    func testCustomersSearchAlignmentKeyboardDismissAndContractsRootSearch() throws {
        try XCTSkipIf(isPad, "The iPhone Customers list and Contracts tab.")
        app.openContacts("Customers")
        let row = app.row("Carter, Danielle")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The demo Customers list should list Danielle Carter.")
        XCTAssertTrue(searchCapsule.waitForExistence(timeout: 5), "The Customers search row should be on screen.")

        let cell = app.cells.containing(NSPredicate(format: "label == %@", "Carter, Danielle")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "Danielle Carter's row should be a list cell.")
        let capsule = searchCapsule.frame
        let card = cell.frame.insetBy(dx: gutter, dy: 0)
        XCTAssertEqual(capsule.minX, card.minX, accuracy: 0.5, "The search capsule's left edge should sit on the cards'.")
        XCTAssertEqual(capsule.maxX, card.maxX, accuracy: 0.5, "The search capsule's right edge should sit on the cards'.")
        XCTAssertEqual(capsule.minX, gutter, accuracy: 0.5, "Customers' search should sit on the 8 pt gutter.")

        let field = inListSearchField("Search customers")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The Customers search row should be on screen.")
        XCTAssertTrue(field.tapForKeyboardFocus(), "The search field should take the keyboard.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search should raise the keyboard.")

        let bar = app.glNavBar("Customers")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The Customers bar should be on screen.")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "A tap outside the field should put the keyboard away.")

        // Contracts root toolbar search check in the same launch.
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(app.glNavBar("Contracts").waitForExistence(timeout: 5), "The Contracts tab should open.")
        XCTAssertFalse(inListSearchField("Search contracts").exists, "The Contracts tab root has no in-list search row.")
        let glass = app.buttons["Search contracts"]
        XCTAssertTrue(glass.waitForExistence(timeout: 5), "The Contracts root shows its magnifying glass.")
        glass.tap()
        XCTAssertTrue(systemSearchField("Search contracts").waitForExistence(timeout: 5),
                      "The magnifying glass should open the system search. \(app.visibleSummary())")
    }

    func testPriceSheetFormGuardAlignmentNoMatchSearchAndAllJobsInListSearch() throws {
        try XCTSkipIf(isPad, "The iPhone Menu path.")
        app.openRecordsHub()
        app.openRecordsList("All Jobs")
        XCTAssertTrue(inListSearchField("Search jobs").waitForExistence(timeout: 5),
                      "Pushed All Jobs should search through the in-list row, like its siblings. \(app.visibleSummary())")
        XCTAssertFalse(systemSearchField("Search jobs").exists,
                       "Pushed All Jobs should have no system search field.")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.openRecordsList("Price Sheet")
        // 1. Unedited form goes back without asking.
        app.buttons["New Catalog Item"].tap()
        XCTAssertTrue(app.glNavBar("New Catalog Item").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discardBackButton"].exists, "An untouched form keeps the system Back.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.glNavBar("Price Sheet").waitForExistence(timeout: 5))

        // 2. Edited form asks before discarding, then create item.
        let addFirst = app.buttons["Add First Item"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 5), "The demo Price Sheet should start empty.")
        addFirst.tap()
        let name = app.textFields["Service or item name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "The New Catalog Item form should open.")
        XCTAssertTrue(name.tapForKeyboardFocus(), "The name field should take the keyboard.")
        name.typeText("Uitest Tile")
        XCTAssertTrue(name.waitForValue("Uitest Tile"), "The name should land in full.")

        let back = app.buttons["discardBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "An edited form swaps in the guarded Back button.")
        back.tap()
        let alert = app.alerts["Discard changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Back on an edited form should ask first.")
        alert.buttons["Keep Editing"].tap()
        XCTAssertEqual(name.value as? String, "Uitest Tile")
        app.buttons["Save"].tap()

        // 3. Alignment & No-match search behavior.
        let item = app.staticTexts["Uitest Tile"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The saved item should be listed.")
        XCTAssertTrue(searchCapsule.waitForExistence(timeout: 5), "A Price Sheet with items shows its search row.")
        let cell = app.cells.containing(.staticText, identifier: "Uitest Tile").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "The item's card should be a list cell.")
        let capsule = searchCapsule.frame
        XCTAssertEqual(capsule.minX, cell.frame.minX, accuracy: 0.5, "The search capsule's left edge should sit on the cards'.")
        XCTAssertEqual(capsule.maxX, cell.frame.maxX, accuracy: 0.5, "The search capsule's right edge should sit on the cards'.")
        XCTAssertEqual(capsule.minX, gutter, accuracy: 0.5, "The Price Sheet's search should sit on the 8 pt gutter.")

        let field = inListSearchField("Search services & materials")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "A Price Sheet with items shows its search row.")
        XCTAssertTrue(field.tapForKeyboardFocus(), "The search field should take the keyboard.")
        field.typeText("zzz")

        XCTAssertTrue(app.staticTexts["No Results for “zzz”"].waitForExistence(timeout: 5)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No Results")).firstMatch.exists,
                      "A search with no matches should say so. \(app.visibleSummary())")
        XCTAssertTrue(field.exists, "The search field must stay on screen after a search with no matches.")
        XCTAssertTrue(field.waitForValue("zzz"), "The field should still hold the search.")

        let clear = app.buttons["Clear search"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "The field's clear button should be reachable.")
        clear.tap()
        XCTAssertTrue(app.staticTexts["Uitest Tile"].waitForExistence(timeout: 5),
                      "Clearing the search should bring the rows back.")
    }
}
