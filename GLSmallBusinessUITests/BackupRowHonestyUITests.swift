//
//  BackupRowHonestyUITests.swift
//  GLSmallBusinessUITests
//
//  Audit 2026-10-03 F88, on screen: Settings' Backup row says what is still on this iPhone
//  instead of a backup time nothing earned. `-uiTestSignOutWarning` (DEBUG) gives the demo store
//  a history baseline and an engine with no session, so nothing reaches the network: the
//  baseline used to stamp the backup time ("Backup 10:41 AM" with nothing backed up), and an
//  edit folded into the outbox now reads "1 change waiting".
//

import XCTest

final class BackupRowHonestyUITests: GLUITestCase {
    override class var extraLaunchArguments: [String] { ["-uiTestSignOutWarning"] }

    func testTheBackupRowNamesTheChangeStillWaiting() {
        app.openContacts("Customers")
        app.buttons["Menu"].tap()
        app.tapMenuRow("Settings")

        // Nothing has ever reached the server: no time may be shown.
        let notYet = app.staticTexts["Not yet backed up"]
        XCTAssertTrue(notYet.waitForExistence(timeout: 5),
                      "a store that never synced showed a backup time. \(app.visibleSummary())")
        saveProof("C22-backup-row-before-edit")

        // One real edit, folded into the outbox by the Menu's sign-out count (local, no network).
        let toggle = app.switches["Show address on documents"]
        XCTAssertTrue(app.scrollUntilHittable(toggle), "Settings should show the address toggle. \(app.visibleSummary())")
        let before = toggle.value as? String
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: flipped, evaluatedWith: toggle)], timeout: 5), .completed,
                       "the switch did not change (was \(before ?? "nil")). \(app.visibleSummary())")
        app.navigationBars.buttons.firstMatch.tap()
        app.tapMenuRow("Sign out")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Sign out should ask first. \(app.visibleSummary())")
        let warning = alert.staticTexts["1 change hasn’t been backed up yet. If you sign out now, it’s lost. Connect to the internet first to keep it."]
        XCTAssertTrue(warning.exists, "the alert must name the edit just saved: \(alert.debugDescription)")
        alert.buttons["Cancel"].tap()

        app.tapMenuRow("Settings")
        let waiting = app.staticTexts["1 change waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5),
                      "the Backup row must name the change still on this iPhone. \(app.visibleSummary())")
        saveProof("C22-backup-row-1-change-waiting")
    }

    /// The screen as it stands, attached to the run and (when asked) written as a PNG.
    private func saveProof(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["MB_PROOF_DIR"], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
