//
//  AccessibilityNamingScanTests.swift — what VoiceOver hears, pinned at the call sites
//  (audit 2026-10-03 F55).
//
//  A hosted unit test can't read SwiftUI's accessibility tree (GLTestHost header), so the
//  facts that are about CALL SITES are scanned here, and AccessibilityAuditUITests reads the
//  live tree:
//  - a switch or picker never goes without a name: `Toggle("")` / `Picker("")` read
//    "Switch button, on" with nothing to say what it switches;
//  - a row's trailing chevron is never read aloud (VoiceOver says "Forward" on every row);
//  - the lapse announcement is spoken in the app's language, not the device's.
//
//  Files the fix did not reach are listed by name in `stillToFix`, and the list must stay
//  true: a file on it that no longer offends fails, so the list only ever shrinks.
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct AccessibilityNamingScanTests {

    /// Every `Toggle("")` / `Picker("")` in the app, as "file:line".
    nonisolated static func unnamedControls(in files: [(path: String, text: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated()
            where line.contains("Toggle(\"\"") || line.contains("Picker(\"\"") {
                out.append("\(file.path):\(index + 1)")
            }
        }
        return out
    }

    /// Every `Image(systemName: "chevron.right")` whose own modifier chain (the rest of its
    /// line and the `.modifier` lines under it) doesn't hide it from VoiceOver, as "file:line".
    nonisolated static func announcedChevrons(in files: [(path: String, text: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let start = line.range(of: "Image(systemName: \"chevron.right\")") else { continue }
                var chain = String(line[start.upperBound...])
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                    chain += lines[next]
                    next += 1
                }
                // A chevron that IS a button's whole label (the calendar's "Next month") is named by
                // the button's own `.accessibilityLabel`, which replaces the glyph's name.
                let after = lines[next..<min(next + 4, lines.count)].joined(separator: "\n")
                let namedByItsButton = after.contains(".accessibilityLabel(")
                if !chain.contains(".accessibilityHidden(true)") && !namedByItsButton {
                    out.append("\(file.path):\(index + 1)")
                }
            }
        }
        return out
    }

    /// Files F55 named that this fix (cluster C63) was not allowed to edit. Each still carries
    /// the defect; fixing one means taking it off this list.
    nonisolated static let stillToFix: Set<String> = [
        "Screens/SubcontractorDetailScreen.swift",   // Picker("") for the entry mode
        "Screens/ProjectScreens.swift",               // chevrons read aloud
        "Screens/AllChangeOrdersScreen.swift",
        "Screens/AllDocumentsScreen.swift",
        "Screens/AllEstimatesScreen.swift",
        "Screens/AllInvoicesScreen.swift",
        "Screens/CompanyDocuments.swift",
        "Screens/EstimatesListScreen.swift",
        "Screens/InsuranceDocuments.swift",
        "Screens/InvoicesListScreen.swift",
        "Screens/JobsListScreen.swift",
    ]

    nonisolated private static func file(of site: String) -> String {
        String(site.split(separator: ":").first ?? "")
    }

    @Test func switchesAndPickersAlwaysHaveAName() {
        let sites = Self.unnamedControls(in: GLSource.codeFiles())
        let strays = sites.filter { !Self.stillToFix.contains(Self.file(of: $0)) }
        #expect(strays.isEmpty, "unnamed controls (VoiceOver reads no name): \(strays)")
    }

    @Test func rowChevronsAreNeverReadAloud() {
        let sites = Self.announcedChevrons(in: GLSource.codeFiles())
        let strays = sites.filter { !Self.stillToFix.contains(Self.file(of: $0)) }
        #expect(strays.isEmpty, "chevrons VoiceOver reads as \"Forward\": \(strays)")
    }

    /// The exceptions list is honest: every file on it still offends.
    @Test func theStillToFixListIsCurrent() {
        let files = GLSource.codeFiles()
        let offending = Set((Self.unnamedControls(in: files) + Self.announcedChevrons(in: files)).map(Self.file(of:)))
        let fixed = Self.stillToFix.subtracting(offending)
        #expect(fixed.isEmpty, "these files no longer offend; take them off stillToFix: \(fixed.sorted())")
    }

    /// The scanners find what they look for (a scan that finds nothing proves nothing).
    @Test func theScannersCatchTheDefects() {
        let sample: [(path: String, text: String)] = [("X.swift", """
            Toggle("", isOn: $on).labelsHidden()
            Image(systemName: "chevron.right")
                .font(.footnote)
            Image(systemName: "chevron.right")
                .font(.footnote)
                .accessibilityHidden(true)
            Picker("Unit", selection: $unit) { }
            Button { next() } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Next month")
            """)]
        #expect(Self.unnamedControls(in: sample) == ["X.swift:1"])
        #expect(Self.announcedChevrons(in: sample) == ["X.swift:2"])
    }

    /// The lapse announcement is built in the app's chosen language (MBLocalization), never the
    /// package's `.current` default, which is the DEVICE language.
    @Test func theLapseAnnouncementUsesTheAppLanguage() throws {
        let code = try #require(GLSource.code("UIComponents/MBSystemBanners.swift"))
        #expect(code.contains("announcementLocale: MBLocalization.currentLocale"),
                "MBSystemBanners does not pass the app's locale for the lapse announcement")
    }
}
