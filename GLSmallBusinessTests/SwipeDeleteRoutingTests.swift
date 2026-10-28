//
//  SwipeDeleteRoutingTests.swift
//  GLSmallBusinessTests
//
//  REQUIREMENTS law 8, "The swipe only asks" (2026-09-26 crash): a confirm-first swipe Delete is
//  a plain-role `.swipeActions` button with no full swipe — never `.onDelete` and never
//  `role: .destructive`. Both of those pull the row out of the list the moment they're tapped,
//  while the data stays until the alert (or the typed name) confirms; the list then counts a
//  row the data still has, and crashes when the real delete lands ("Invalid number of items in
//  section"). Law 8a: every other delete keeps the standard alert.
//
//  These are facts about call sites, so they are scans (Harness/SourceScan.swift) — of the
//  CODE, comments stripped, so a comment that names a pattern can neither fail nor pass them.
//

import Testing
import Foundation

@Suite struct SwipeDeleteRoutingTests {

    /// The only `.onDelete`s the app may keep: line editing in forms that are not saved yet.
    /// They take a draft line out of the form's own array on the spot — no record, no alert —
    /// which is exactly what `.onDelete` is for. Counted per file, so a new `.onDelete` in one
    /// of these files is caught too.
    static let draftLineEditing: [String: Int] = [
        "Screens/EstimateFormScreen.swift": 1,
        "Screens/InvoiceFormScreen.swift": 1,
        "Screens/ChangeOrderScreens.swift": 1,
        "Screens/WorkScheduleScreen.swift": 3,
    ]

    /// Each `.onDelete` in the app's code, as (file, line, closure body).
    static func onDeleteSites() -> [(path: String, line: Int, body: String)] {
        var sites: [(path: String, line: Int, body: String)] = []
        for file in GLSource.codeFiles() {
            var from = file.text.startIndex
            while let hit = file.text.range(of: ".onDelete", range: from..<file.text.endIndex) {
                let body = GLSource.balanced("{", "}", from: hit.upperBound, in: file.text)
                sites.append((file.path, GLSource.line(of: hit.lowerBound, in: file.text), body?.inner ?? ""))
                from = hit.upperBound
            }
        }
        return sites
    }

    /// Each `swipeActions(…) { … }` call in the app's code — with or without the leading dot,
    /// so the shared button's own call inside its `View` extension counts — as (file, line,
    /// arguments, body).
    static func swipeActionSites() -> [(path: String, line: Int, args: String, body: String)] {
        var sites: [(path: String, line: Int, args: String, body: String)] = []
        for file in GLSource.codeFiles() {
            var from = file.text.startIndex
            while let hit = file.text.range(of: "swipeActions(", range: from..<file.text.endIndex) {
                let line = GLSource.line(of: hit.lowerBound, in: file.text)
                if let args = GLSource.balanced("(", ")", from: hit.lowerBound, in: file.text),
                   let body = GLSource.balanced("{", "}", from: args.end, in: file.text) {
                    sites.append((file.path, line, args.inner, body.inner))
                } else {
                    sites.append((file.path, line, "", ""))
                }
                from = hit.upperBound
            }
        }
        return sites
    }

    // MARK: - No confirm-first list uses .onDelete

    /// Every `.onDelete` is one of the draft-line sites, and none of them stages a delete for
    /// a confirmation. Failed at 7693741 on 14 lists (the iPad Customers column among them).
    @Test func noConfirmFirstListUsesOnDelete() {
        let sites = Self.onDeleteSites()
        let staged = sites.filter { site in
            ["pendingDelete", "deleteQueue", "showingPaidLock", "requestDelete"].contains { site.body.contains($0) }
        }.map { "\($0.path):\($0.line)" }
        #expect(staged.isEmpty, "\(staged.count) list(s) stage a confirmed delete from .onDelete (law 8)")

        let outside = sites.filter { Self.draftLineEditing[$0.path] == nil }.map { "\($0.path):\($0.line)" }
        #expect(outside.isEmpty, ".onDelete outside the draft-line forms (law 8)")

        for (path, expected) in Self.draftLineEditing {
            let here = sites.filter { $0.path == path }
            #expect(here.count == expected, "\(path) has \(here.count) .onDelete, expected \(expected)")
            for site in here {
                #expect(site.body.contains("remove(atOffsets:"),
                        "\(path):\(site.line) is allowlisted as draft-line editing but does not remove a draft line")
            }
        }
    }

    // MARK: - Every delete swipe is plain and never a full swipe

    /// Any swipe action that deletes is plain-role and asks for `allowsFullSwipe: false`. A
    /// full swipe or a destructive role pulls the row before the alert; a full swipe also
    /// deletes with no alert when nothing confirms (the Price Sheet, F71).
    @Test func everyDeleteSwipeIsPlainAndNeverFullSwipe() {
        let sites = Self.swipeActionSites()
        #expect(sites.allSatisfy { !$0.body.isEmpty }, "a .swipeActions the scan could not read")
        // "delete" in any case: a Delete label, a destructive role, or a helper that builds the
        // button (CustomersScreen's `deleteSwipeButton`).
        let deleting = sites.filter { $0.body.lowercased().contains("delete") || $0.body.contains("role: .destructive") }
        #expect(deleting.contains { $0.path == "UIComponents/SwipeDeleteConfirmation.swift" },
                "the scan did not see the shared swipe Delete — it proves nothing")
        for site in deleting {
            #expect(site.args.contains("allowsFullSwipe: false"),
                    "\(site.path):\(site.line) lets a full swipe delete (law 8)")
            #expect(!site.body.contains("role: .destructive"),
                    "\(site.path):\(site.line) uses a destructive swipe role (law 8)")
        }
    }

    /// Every list that confirms a delete (the alert or the typed name) gets its swipe from the
    /// one shared button, so the next list cannot drift back to `.onDelete`. Failed at
    /// 7693741: none of the 13 files with an alert-confirmed list had a swipe button.
    @Test func everyConfirmFirstListUsesTheSharedSwipeButton() {
        let confirmFirst = GLSource.codeFiles(excluding: ["UIComponents/"]).filter {
            $0.text.contains(".swipeDeleteConfirmation(") || $0.text.contains(".customerDeleteConfirmation(")
        }
        #expect(confirmFirst.count >= 13, "the confirm-first lists moved — this scan proves nothing")
        let shared = "func confirmFirstDeleteSwipe("
        let missing = confirmFirst.filter {
            // CustomersScreen's own button predates the shared one and is held to the same
            // shape by `everyDeleteSwipeIsPlainAndNeverFullSwipe`.
            !$0.text.contains(".confirmFirstDeleteSwipe") && $0.path != "Screens/CustomersScreen.swift"
        }.map(\.path)
        #expect(missing.isEmpty, "confirm-first lists without the shared swipe Delete: \(missing)")
        let component = GLSource.code("UIComponents/SwipeDeleteConfirmation.swift") ?? ""
        #expect(component.contains(shared), "the shared swipe Delete is missing")
    }

    /// The shared swipe's closure only STAGES the delete (a pending-delete state, the typed-name
    /// queue, or a `requestDelete` that explains a lock first). A `confirmFirstDeleteSwipe {
    /// delete(x) }` would pass every other scan and delete with no alert.
    @Test func everySharedSwipeOnlyStagesTheDelete() {
        var sites: [(path: String, line: Int, body: String)] = []
        for file in GLSource.codeFiles(excluding: ["UIComponents/"]) {
            var from = file.text.startIndex
            while let hit = file.text.range(of: ".confirmFirstDeleteSwipe", range: from..<file.text.endIndex) {
                let body = GLSource.balanced("{", "}", from: hit.upperBound, in: file.text)
                sites.append((file.path, GLSource.line(of: hit.lowerBound, in: file.text), body?.inner ?? ""))
                from = hit.upperBound
            }
        }
        #expect(sites.count >= 14, "the shared swipe sites moved — this scan proves nothing")
        let stagers = ["pendingDelete =", "deleteQueue =", "requestDelete("]
        let unstaged = sites.filter { site in
            !stagers.contains { site.body.contains($0) }
                || site.body.contains("DeletionService") || site.body.contains(".delete(")
        }.map { "\($0.path):\($0.line)" }
        #expect(unstaged.isEmpty, "swipe closures that do more than stage the delete: \(unstaged)")
    }

    // MARK: - F71: the deletes that never asked

    /// The Price Sheet swipe stages the item for the standard alert instead of deleting it.
    @Test func priceSheetDeleteAsksFirst() throws {
        let code = try #require(GLSource.code("Screens/PriceSheetScreen.swift"))
        #expect(code.contains(".confirmFirstDeleteSwipe"), "the Price Sheet swipe is not the shared plain one")
        #expect(code.contains(".swipeDeleteConfirmation("), "the Price Sheet delete has no alert")
    }

    /// "Remove Photo" (customer, subcontractor) and "Delete saved signature" only ask; the
    /// write happens in the alert's confirm, never in the button's own action.
    @Test func photoAndSignatureRemovalAskFirst() throws {
        let cases: [(file: String, button: String, write: String)] = [
            ("Screens/CustomerDetailScreen.swift", "Button(\"Remove Photo\"", "setPhoto(nil)"),
            ("Screens/SubcontractorDetailScreen.swift", "Button(\"Remove Photo\"", "setPhoto(nil)"),
            ("Screens/SignatureEditorSheet.swift", "Button(\"Delete saved signature\"", "store(nil)"),
        ]
        for item in cases {
            let code = try #require(GLSource.code(item.file))
            let button = try #require(code.range(of: item.button), "\(item.file): \(item.button) is gone")
            let action = try #require(GLSource.balanced("{", "}", from: button.upperBound, in: code))
            #expect(!action.inner.contains(item.write),
                    "\(item.file): the button removes at once, with no alert (law 8a)")
            let confirm = try #require(code.range(of: ".deleteConfirmation("),
                                       "\(item.file): no confirm alert for \(item.button)")
            let args = try #require(GLSource.balanced("(", ")", from: confirm.lowerBound, in: code))
            let perform = try #require(GLSource.balanced("{", "}", from: args.end, in: code))
            #expect(perform.inner.contains(item.write),
                    "\(item.file): the confirm alert does not do the removal")
        }
    }
}
