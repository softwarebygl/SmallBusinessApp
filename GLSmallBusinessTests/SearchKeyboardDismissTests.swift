//
//  SearchKeyboardDismissTests.swift
//  GLSmallBusinessTests
//
//  Law 9: every list with a typing field dismisses the keyboard on scroll and on a tap
//  outside the field. GoldLifeUI's in-list search (`GLInListSearchHeader`) is a plain
//  TextField in a List row, not a native `.searchable`, so its List needs the app's standard
//  dismissal wired explicitly: `.dismissesKeyboardOnInteraction()`, or the grouped skin
//  `.glFormBackground()`, which carries it (QA 2026-10-03 F130: ten lists had neither, so the
//  tap-outside half only worked once some form had happened to install the window recognizer).
//  The List is read the same way SearchGutterTests reads it (`SearchRowContainer`).
//

import Testing
import Foundation

@Suite struct SearchKeyboardDismissTests {

    /// Files whose search lists still lack the dismissal and are outside this fix's scope; each
    /// one is reported for its own fix. The second test fails once one is fixed, so the entry
    /// can't outlive the gap.
    static let knownGaps: Set<String> = ["Screens/IPadRootSplitView.swift"]

    /// The search rows in `text` whose List dismisses neither way, as 1-based line numbers.
    static func rowsMissingDismissal(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        var missing: [Int] = []
        for (index, line) in lines.enumerated()
        where line.contains("GLInListSearchHeader(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let chain = SearchRowContainer.listModifiers(forRowAt: index, in: lines) ?? []
            let dismisses = chain.contains {
                $0.contains(".dismissesKeyboardOnInteraction()") || $0.contains(".glFormBackground()")
            }
            if !dismisses { missing.append(index + 1) }
        }
        return missing
    }

    @Test func everyInListSearchListDismissesTheKeyboard() {
        var wrong: [String] = []
        var checked = 0
        for file in GLSource.files() where !Self.knownGaps.contains(file.path) {
            checked += file.text.components(separatedBy: "GLInListSearchHeader(").count - 1
            wrong += Self.rowsMissingDismissal(in: file.text).map { "\(file.path):\($0)" }
        }
        #expect(checked > 0, "the scan found no search rows at all, so it checked nothing")
        #expect(wrong.isEmpty, "search lists that leave the keyboard up on scroll / tap-outside: \(wrong)")
    }

    @Test func knownGapsAreStillGaps() {
        for path in Self.knownGaps {
            guard let text = GLSource.file(path) else {
                Issue.record("\(path) is gone: drop it from knownGaps")
                continue
            }
            #expect(!Self.rowsMissingDismissal(in: text).isEmpty,
                    "\(path) dismisses the keyboard now: drop it from knownGaps")
        }
    }

    /// The scan itself, on the shapes it has to tell apart.
    @Test func scanTellsDismissingListsFromOthers() {
        let bare = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
        }
        .listStyle(.plain)
        """
        let wired = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
        }
        .listStyle(.plain)
        .dismissesKeyboardOnInteraction()
        """
        let skinned = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asListRow
        }
        .glFormBackground()
        """
        let viaChrome = """
        var body: some View {
            List {
                GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
            }
            .modifier(Chrome())
        }
        private struct Chrome: ViewModifier {
            func body(content: Content) -> some View {
                content.listStyle(.plain)
                    .dismissesKeyboardOnInteraction()
            }
        }
        """
        let onTheParent = """
        VStack {
            List {
                GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
            }
            .listStyle(.plain)
        }
        .dismissesKeyboardOnInteraction()
        """
        // A modifier whose arguments wrap onto a second line doesn't end the chain early.
        let wrapped = """
        List {
            GLInListSearchHeader(text: $q, prompt: "Search").asPlainListRow
        }
        .swipeDeleteConfirmation($pending, title: "Delete?",
                                 message: "Gone for good.") {
            delete($0)
        }
        .listStyle(.plain)
        .dismissesKeyboardOnInteraction()
        """
        #expect(Self.rowsMissingDismissal(in: wrapped).isEmpty)
        #expect(Self.rowsMissingDismissal(in: bare) == [2])
        #expect(Self.rowsMissingDismissal(in: wired).isEmpty)
        #expect(Self.rowsMissingDismissal(in: skinned).isEmpty)
        #expect(Self.rowsMissingDismissal(in: viaChrome).isEmpty)
        // A modifier on an enclosing view doesn't count: the scan wants it on the List.
        #expect(Self.rowsMissingDismissal(in: onTheParent) == [3])
    }
}
