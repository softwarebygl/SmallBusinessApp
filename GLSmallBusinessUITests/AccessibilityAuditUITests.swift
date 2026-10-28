//
//  AccessibilityAuditUITests.swift
//  GLSmallBusinessUITests
//
//  VoiceOver and tap-target guard (audit 2026-10-03 F55, law 16). Two instruments:
//
//  1. Apple's own audit, `performAccessibilityAudit`, on each root screen and the detail
//     screens F55 named (Customers, Jobs, Menu, Settings, a customer, an invoice, a job, the
//     Contractor Package, an employee), for what this guard owns: a hit area under 44 pt, a
//     control with no usable name, a missing trait, an element VoiceOver can't reach. Contrast,
//     Dynamic Type and clipping are not run here (palette/type work, and the slowest checks:
//     with them the long invoice timed out).
//  2. What VoiceOver would SAY, read from the element tree: no button's spoken name carries a
//     chevron ("Forward") or a monogram, no switch or button is nameless, the photo pickers say
//     what they do, multi-select marks carry "Selected", and the search clear button, the ⓘ and
//     the hour chips have 44 pt targets.
//
//  Note on the tree: XCUITest lists a button's child images even when they are hidden from
//  VoiceOver, so "an Image labeled Forward exists" proves nothing; what VoiceOver reads is the
//  BUTTON's label, and that is what is checked.
//

import XCTest

final class AccessibilityAuditUITests: GLUITestCase {

    /// The audit types this guard fails on.
    private static let failingTypes: XCUIAccessibilityAuditType =
        [.hitRegion, .sufficientElementDescription, .trait, .elementDetection]

    /// Runs Apple's audit (the `failingTypes`) on what is on screen now. Every issue is attached
    /// to the run and fails the test, except the audit's "label not human-readable" guess, which
    /// it makes about DATA (an email address, "$1,056.84") that VoiceOver reads correctly.
    ///
    /// `knownOpen` names elements whose too-small hit area lives in a file this fix could not
    /// edit; they are recorded, not failed, and each must still be found, so the exception is
    /// dropped the day it is fixed.
    private func audit(_ screen: String, knownOpen: Set<String> = [],
                       file: StaticString = #filePath, line: UInt = #line) {
        var issues: [(label: String?, isHitRegion: Bool, text: String, readable: Bool)] = []
        var runError: Error?
        // One retry when the audit itself runs out of time (code -56) on a long screen.
        for attempt in 1...2 {
            issues.removeAll()
            do {
                try app.performAccessibilityAudit(for: Self.failingTypes) { issue in
                    guard let element = issue.element,
                          element.frame != .zero,
                          element.frame.width > 0,
                          element.frame.height > 0 else {
                        return true
                    }
                    issues.append((element.label, issue.auditType == .hitRegion,
                                   "[\(issue.compactDescription)] label='\(element.label)' "
                                   + "id='\(element.identifier)' frame=\(element.frame)",
                                   issue.compactDescription != "Label not human-readable"))
                    return true   // handled here; the assertion below names every failure at once
                }
                runError = nil
                break
            } catch let error as NSError where error.code == -56 && attempt == 1 {
                runError = error
            } catch {
                runError = error
                break
            }
        }
        let attachment = XCTAttachment(string: issues.map(\.text).joined(separator: "\n"))
        attachment.name = "accessibility-audit-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNil(runError, "\(screen): the audit could not run: \(String(describing: runError))",
                     file: file, line: line)
        let open = issues.filter { $0.isHitRegion && $0.label.map(knownOpen.contains) == true }
        let failures = issues.filter { issue in issue.readable && !open.contains { $0.text == issue.text } }
        XCTAssertTrue(failures.isEmpty,
                      "\(screen): \(failures.count) accessibility issue(s):\n" + failures.map(\.text).joined(separator: "\n"),
                      file: file, line: line)
        let fixed = knownOpen.subtracting(open.compactMap(\.label))
        XCTAssertTrue(fixed.isEmpty, "\(screen): no longer too small, drop from knownOpen: \(fixed.sorted())",
                      file: file, line: line)
    }

    /// What VoiceOver would read on screen now: no button's name carries a chevron ("Forward"),
    /// and no switch or button goes without a name.
    private func assertEveryControlIsNamed(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let forward = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Forward"))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(forward.isEmpty, "\(screen): a decorative chevron is read aloud in \(forward)",
                      file: file, line: line)
        let unnamedSwitches = app.switches.allElementsBoundByIndex
            .filter { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(unnamedSwitches.isEmpty,
                      "\(screen): \(unnamedSwitches.count) switch(es) with no name", file: file, line: line)
        let buttons = app.buttons.allElementsBoundByIndex.filter(\.exists)
        let namedFrames = buttons.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.frame)
        let unnamedButtons = buttons
            .filter { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { button in !namedFrames.contains { $0.insetBy(dx: -1, dy: -1).contains(button.frame) } }
            .map { "\($0.identifier) \($0.frame)" }
        XCTAssertTrue(unnamedButtons.isEmpty, "\(screen): buttons with no name: \(unnamedButtons)",
                      file: file, line: line)
    }

    private func tapPrefix(_ prefix: String) -> Bool {
        let query = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        var swipes = 0
        while !(query.firstMatch.exists && query.firstMatch.isHittable) && swipes < 8 {
            app.swipeUp(); swipes += 1
        }
        guard query.firstMatch.exists, query.firstMatch.isHittable else { return false }
        query.firstMatch.tap()
        return true
    }

    private func openCustomer() {
        app.openContacts("Customers")
        app.scrollToRow("Carter, Danielle").tap()
        XCTAssertTrue(app.buttons["More Info"].waitForExistence(timeout: 5),
                      "The customer hub should open. \(app.visibleSummary())")
    }

    // MARK: - Consolidated Accessibility Journeys

    func testCustomersControlsAndContractsPassAccessibilityAudit() {
        app.openContacts("Customers")
        audit("customers")
        assertEveryControlIsNamed("customers")

        // Search clear button 44pt target
        XCTAssertTrue(app.searchFields["inListSearchField"].firstMatch.waitForExistence(timeout: 5))
        let field = app.searchFields.matching(identifier: "inListSearchField").allElementsBoundByIndex
            .first(where: \.isHittable) ?? app.searchFields["inListSearchField"].firstMatch
        XCTAssertTrue(field.tapForKeyboardFocus())
        field.typeText("Car")
        let clear = app.buttons["Clear search"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(clear.frame.width, 43.5, "clear target \(clear.frame)")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 43.5, "clear target \(clear.frame)")
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5), "Clear should empty the field.")

        // Multi-select trait
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Carter, Danielle")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(row), "Carter row should be on screen. \(app.visibleSummary())")
        XCTAssertFalse(row.isSelected, "An unpicked row must not read Selected.")
        row.tap()
        XCTAssertTrue(row.isSelected, "A picked row must carry the Selected trait.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }

        // Contracts root & detail
        app.tabBars.buttons["Contracts"].tap()
        XCTAssertTrue(app.glNavBar("Contracts").waitForExistence(timeout: 5))
        audit("contracts")
        assertEveryControlIsNamed("contracts")

        XCTAssertTrue(tapPrefix("Bathroom regrout"), "The sample contract should open. \(app.visibleSummary())")
        audit("contract")
        assertEveryControlIsNamed("contract")
        app.swipeUp()
        audit("contract-scrolled-1")
        assertEveryControlIsNamed("contract-scrolled-1")
    }

    func testCustomerHubInvoiceAndEmployeePassAccessibilityAudit() {
        // 1. Customer Hub & Invoice
        openCustomer()
        XCTAssertTrue(app.buttons["Add photo"].exists, "The avatar picker should read Add photo. \(app.visibleSummary())")
        XCTAssertFalse(app.buttons["DC"].exists, "The avatar picker must not read its monogram.")
        audit("customer-hub")
        assertEveryControlIsNamed("customer-hub")

        XCTAssertTrue(tapPrefix("Invoices"))
        XCTAssertTrue(tapPrefix("Luxury Vinyl"))
        audit("invoice", knownOpen: ["dani.carter@gmail.com", "(850) 555-0148"])
        assertEveryControlIsNamed("invoice")
        app.swipeUp()
        audit("invoice-scrolled-1")
        assertEveryControlIsNamed("invoice-scrolled-1")

        // Pop back to Contacts root (Invoice -> Invoices list -> Customer Hub -> Contacts root)
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 2), back.isHittable {
                back.tap()
            }
        }

        // 2. Employees & Log Hours
        app.openContacts("Employees")
        app.scrollToRow("Caldwell, Owen").tap()
        XCTAssertTrue(app.buttons["Add photo"].waitForExistence(timeout: 5),
                      "The avatar picker should read Add photo. \(app.visibleSummary())")
        audit("employee")
        assertEveryControlIsNamed("employee")

        let log = app.buttons["Log hours"]
        XCTAssertTrue(app.scrollUntilHittable(log), "Log hours should be reachable. \(app.visibleSummary())")
        XCTAssertGreaterThanOrEqual(log.frame.height, 44, "Log hours target \(log.frame)")
        log.tap()
        let chip = app.buttons["8 hours"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "The 8-hour chip should show. \(app.visibleSummary())")
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44, "hour chip \(chip.frame)")
        audit("log-hours")
        assertEveryControlIsNamed("log-hours")
    }

    func testMenuAndSettingsPassAccessibilityAudit() {
        app.openContacts("Customers")
        app.buttons["Menu"].tap()
        audit("menu")
        app.tapMenuRow("Settings")
        let info = app.buttons["About Appearance"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "Settings should show the Appearance ⓘ. \(app.visibleSummary())")
        XCTAssertGreaterThanOrEqual(info.frame.width, 43.5, "ⓘ target \(info.frame)")
        XCTAssertGreaterThanOrEqual(info.frame.height, 43.5, "ⓘ target \(info.frame)")
        audit("settings")
    }
}
