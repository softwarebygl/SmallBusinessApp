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

    /// What EVERY UI test launches with. `-demoMode` seeds the dataset and skips the paywall;
    /// `-uiTestNoAnimations` turns UIView animations off in the app (XCUITest otherwise waits out
    /// every SwiftUI transition — ~2.7 s per event, suite review 2026-09-02); the Apple pair pins
    /// English/US so a simulator left in Spanish cannot fail every string match. The app reads its
    /// own flags with `arguments.contains`, so order carries no meaning.
    static let baseLaunchArguments = [
        "-demoMode", "-uiTestNoAnimations",
        "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
    ]

    /// A suite that needs the app in a different STATE (lapsed, a fixture dataset) overrides this
    /// instead of pasting its own launch — the base flags and the launch itself live here only.
    open class var extraLaunchArguments: [String] { [] }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        relaunch()
    }

    /// (Re)launches with the base flags, the suite's, and — for the one test in a suite that needs
    /// a fixture the rest don't — its own on top. `launch()` terminates a running instance first.
    func relaunch(adding extra: [String] = []) {
        app.launchArguments = Self.baseLaunchArguments + Self.extraLaunchArguments + extra
        app.launch()
    }

    /// "Dump the tree, don't guess": a failed test attaches the app's accessibility tree as it
    /// stood when the test ended, so the next reader sees what XCUITest saw instead of theorising
    /// from the assertion message alone.
    override func tearDown() {
        if (testRun?.totalFailureCount ?? 0) > 0, let app,
           app.state != .notRunning, app.state != .unknown {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "a11y-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        super.tearDown()
    }
}

extension XCUIApplication {
    /// THE way every test reaches a people list since the Contacts merge: one tap to the
    /// merged Contacts tab, one to the segment. Tests pass the full name ("Customers" /
    /// "Employees" / "Subcontractors"); the Subcontractors segment renders its short
    /// label "Subs" (it truncates on iPad otherwise), so the tap maps to what's visible.
    func openContacts(_ segment: String) {
        tabBars.buttons["Contacts"].tap()
        let control = segmentedControls.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5),
                      "The Contacts segmented control should exist on the \(segment) hop.")
        let visible = segment == "Subcontractors" ? "Subs" : segment
        let button = control.buttons[visible]
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "The \(visible) segment should exist.")
        if button.isHittable {
            button.tap()
        } else {
            // XCUITest sometimes computes hit point {-1,-1} for a segment whose picker
            // was just re-created by a flip (SwiftUI a11y-node quirk). Real touches
            // work — verified by driving the simulator directly — so tap the segment's
            // frame center instead of failing on the stale hittability answer.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Swipes up until `element` can be tapped, at most `maxSwipes` times; true when it can.
    ///
    /// `isHittable` is the ONE question worth asking of a lazily-rendered row: it implies
    /// `exists` (a missing element is not hittable) and it is exactly what a tap needs. A
    /// Form/List renders rows LAZILY, so a row below the fold is genuinely ABSENT from the
    /// accessibility tree until scrolled near — hence scrolling rather than a bare existence
    /// check. `element` is a query, re-resolved on every read, so one read per pass is the
    /// whole test.
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        scrollUntilHittable(maxSwipes: maxSwipes) { element } != nil
    }

    /// The loop behind `scrollUntilHittable` and the row helpers. `resolve` picks the element
    /// afresh on every pass — a row's TYPE is only knowable once it is in the tree (see `row(_:)`)
    /// — and a single `isHittable` read per pass decides. Returns the hittable element, or nil
    /// once `maxSwipes` are spent.
    private func scrollUntilHittable(maxSwipes: Int, resolving resolve: () -> XCUIElement) -> XCUIElement? {
        var target = resolve()
        var swipes = 0
        while !target.isHittable {
            guard swipes < maxSwipes else { return nil }
            swipeUp()
            swipes += 1
            target = resolve()
        }
        return target
    }

    /// Scrolls until a row is present AND on screen, then returns it — for ASSERTING on a
    /// row rather than tapping it.
    ///
    /// A bare `.exists` is not a valid check against a Form/List: rows are rendered lazily, so
    /// one below the fold is genuinely ABSENT from the accessibility tree, not merely
    /// off-screen. Two tests asserted `.exists` on rows that sit below the fold (the Gold Life
    /// ID screen's Signature row, the company hub's W-9 section) and failed for that reason
    /// alone, with the app entirely correct (2026-08-25).
    @discardableResult
    func scrollToRow(_ title: String, swipes maxSwipes: Int = 8) -> XCUIElement {
        let found = scrollUntilHittable(maxSwipes: maxSwipes) { row(title) } ?? row(title)
        XCTAssertTrue(found.exists,
                      "Row \(title) never appeared after \(maxSwipes) swipes. \(visibleSummary())")
        return found
    }

    /// Menu ▸ Documents — where every records list now lives.
    ///
    /// The 2026-08-22 restructure moved the record lists off the Menu into the All Documents
    /// hub, and the 2026-09-01 IA audit promoted that hub to a top-level "Documents" row on
    /// the Menu sheet (the old My Business Details ▸ All Documents hop was undiscoverable).
    /// One helper, so the next move breaks one place instead of five. NOTE: inside the hub
    /// the receipts row is now titled "All Expenses" (same audit) — callers pass the NEW name.
    func openRecordsHub() {
        openContacts("Customers")
        buttons["Menu"].tap()
        tapMenuRow("Documents")
        XCTAssertTrue(glNavBar("Documents").waitForExistence(timeout: 5),
                      "Menu ▸ Documents should open the records hub. \(visibleSummary())")
    }

    /// Opens one records list from the hub and asserts it arrived.
    func openRecordsList(_ title: String) {
        tapMenuRow(title)
        XCTAssertTrue(glNavBar(title).waitForExistence(timeout: 5),
                      "\(title) should open its list. \(visibleSummary())")
    }

    /// A row's element, whichever type SwiftUI published it as.
    ///
    /// A plain `Text` in a List row surfaces as a staticText; the same row wrapped in a
    /// `Button` or a `NavigationLink` surfaces as a BUTTON carrying that title as its label,
    /// and the staticText query then finds nothing. The 2026-08-22 design-system conversion
    /// (fd2828f) turned several rows from `Link`/`Text` into `Button`/`NavigationLink` and
    /// silently broke every staticText query pointed at them — the app was correct and the
    /// tests were stale. Asking for "the row titled X" instead of "the static text X" makes
    /// that class of change a non-event.
    /// NOTE the button-first order. A List SECTION HEADER publishes as a staticText carrying
    /// the section's title, and tapping it does nothing at all — `testStatisticsOpens` tapped
    /// the Menu's "Business" HEADER for months and then looked for a row it had never
    /// navigated to (found 2026-08-25 by dumping the tree instead of guessing). Rows are
    /// buttons; headers are static text. Preferring the button makes a header a non-match.
    /// Resolved ONCE per call: the type can change between scroll passes (a row not yet in the
    /// tree has no type), so scroll loops call this afresh each pass rather than caching it.
    func row(_ title: String) -> XCUIElement {
        let button = buttons[title]
        if button.exists { return button }
        let text = staticTexts[title]
        // Neither present YET — hand back the one the caller should wait on. Buttons are the
        // house pattern now, so a genuinely missing row fails naming the button.
        return text.exists ? text : button
    }

    /// Taps a Menu-sheet row, scrolling the sheet until the row is on screen — the lower
    /// Job Records rows sit below the fold, and SwiftUI Lists don't materialize offscreen
    /// rows into the accessibility tree.
    func tapMenuRow(_ title: String) {
        guard let target = scrollUntilHittable(maxSwipes: 8, resolving: { row(title) }) else {
            XCTFail("Menu row \(title) should be reachable after scrolling. \(visibleSummary())")
            return
        }
        target.tap()
    }

    /// What is on screen right now, for a failure message: the first 40 button / static-text
    /// labels in tree order. The full tree is attached by `GLUITestCase.tearDown`; this is the
    /// glance that usually answers "which screen was it actually on?" without opening it.
    /// Failure-path only — each label is its own snapshot, so never call it on a green path.
    func visibleSummary() -> String {
        let rowsAndLabels = descendants(matching: .any).matching(
            NSPredicate(format: "elementType == %@ OR elementType == %@",
                        NSNumber(value: XCUIElement.ElementType.button.rawValue),
                        NSNumber(value: XCUIElement.ElementType.staticText.rawValue)))
        let labels = rowsAndLabels.allElementsBoundByIndex.prefix(40).map { "\"\($0.label)\"" }
        return "On screen now (first \(labels.count) buttons/texts): [\(labels.joined(separator: ", "))]"
    }
}

extension XCUIElement {
    /// Taps a text field and waits until it actually holds the keyboard; true once it does.
    /// `typeText` needs the field to be first responder, and the tap hands focus over
    /// asynchronously — so wait for it instead of trusting the tap.
    @discardableResult
    func tapForKeyboardFocus(timeout: TimeInterval = 5) -> Bool {
        tap()
        return rereads(until: timeout) { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }
    }

    /// Waits until a text field reads EXACTLY `expected`; true once it does.
    ///
    /// Read a field's value through this after `typeText`, never straight after it.
    /// `typeText` returns once XCUITest has SENT the keystrokes, not once the app has taken
    /// them: the keyboard hands them to the field afterwards, and XCUITest's "idle" check can
    /// pass between two of them. 2026-09-27: the phone test read "55", "555-123" and
    /// "555-123-456" from a field whose own screen recording and end-of-test tree showed all
    /// ten digits a moment later — the app had lost nothing; the test had read too early.
    ///
    /// Waiting for the exact string is as strict as the old read: a dropped or garbled
    /// digit never matches, so the wait runs out and the caller's XCTAssertEqual names the
    /// value the field really ended on.
    @discardableResult
    func waitForValue(_ expected: String, timeout: TimeInterval = 5) -> Bool {
        rereads(until: timeout) { $0.value as? String == expected }
    }

    /// Re-reads the element until `condition` holds or `timeout` runs out. Every read is a fresh
    /// snapshot that XCUITest takes only once the app is idle, so the loop paces itself — and it
    /// answers on the FIRST read when the condition already holds. (XCTNSPredicateExpectation
    /// was measured making its first check ~1 s late, every time: the one-digit-at-a-time test
    /// typed a digit every ~1.7 s with it, every ~0.8 s with this — a person's pace.)
    private func rereads(until timeout: TimeInterval, _ condition: (XCUIElement) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition(self) { return true }
        } while Date() < deadline
        return false
    }
}


/// Mirror of GLScript.padded for bar-title matching: every nav title carries
/// three trailing non-breaking spaces (the swash-ink room). UI tests matching
/// a TITLE must pad; LIST rows and buttons stay unpadded.
// GLScriptPad was DELETED 2026-08-31: it hardcoded a three-NBSP pad that no
// longer exists (padding is per-string now, and most titles get none). UI
// tests match bar titles by PREFIX so they never encode a pad width.

extension XCUIApplication {
    /// A navigation bar addressed by its VISIBLE title.
    ///
    /// Script bar titles carry an invisible trailing pad (`GLScript.padded` —
    /// no-break spaces anchored by a word joiner, the room Italianno's
    /// trailing swashes need), so an exact-string lookup misses. Tests must
    /// never encode that pad: match the visible text and let the padding
    /// change without touching 33 call sites.
    func glNavBar(_ title: String) -> XCUIElement {
        navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", title)).firstMatch
    }
}
