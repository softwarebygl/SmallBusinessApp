//
//  ThemeTokenScanTests.swift
//  GLSmallBusinessTests
//
//  App chrome takes its colours and its horizontal insets from the shared tokens, never
//  from the system or a typed number (2026-10-03 QA audit, F108 and F119).
//
//  - Law 19: system semantic styles (`.secondary`, `.primary`, `Color(.tertiarySystemFill)`)
//    are banned in app chrome; GLTheme text and surface tokens only.
//  - Law 32: raw `.red` / `.green` / `.orange` / `.blue` / `.purple` literals are the
//    violation; GLTheme status tokens replace them.
//  - Law 55: hardcoded horizontal insets on cards, lists and headers are prohibited;
//    `GLLayout.rowContentPadding` (18) inside a card, `GLLayout.rowCardInset` (8) outside.
//
//  The scan reads CODE (comments stripped), so a comment that names a banned pattern is
//  never an offender. Every file under Screens/ and UIComponents/ is held to zero, except:
//  - printed documents (a PDF is drawn on white paper, not on the app's palette), and
//  - `knownDebt`: files outside this fix's scope that still carry the pattern, each held
//    to the count it has today so the debt can only shrink. A new file starts at zero.
//

import Testing
import Foundation

struct ThemeTokenScanTests {

    /// The folders that hold app chrome.
    private static let chromeFolders = ["Screens/", "UIComponents/"]

    /// Printed documents: drawn for white paper with paper colours and print margins.
    private static let printedDocuments: Set<String> = [
        "UIComponents/ChangeOrderPDFDocument.swift",
        "UIComponents/CompletionPackagePDF.swift",
        "UIComponents/ContractPDFDocument.swift",
        "UIComponents/EstimatePDFDocument.swift",
        "UIComponents/InvoicePDFDocument.swift",
        "UIComponents/PaymentReceiptDocument.swift",
    ]

    /// System or raw colours in a style position.
    private static let colorPatterns = [
        #"\.(foregroundStyle|foregroundColor|tint|fill|stroke|background)\(\s*(Color)?\.(primary|secondary|tertiary|quaternary|red|green|blue|orange|purple|yellow|gray|pink|mint|teal|cyan|indigo|brown)\b"#,
        #"Color\(\s*(uiColor:\s*)?\.(\w*[sS]ystem\w*|label|secondaryLabel|tertiaryLabel|placeholderText|separator)\s*\)"#,
        #"\?\s*(Color)?\.(primary|secondary|tertiary|red|green|blue|orange|purple|yellow|gray)\s*:"#,
        #":\s*(Color)?\.(primary|secondary|tertiary|red|green|blue|orange|purple|yellow|gray)\s*\)"#,
        #"Color\.(primary|secondary|red|green|blue|orange|purple|yellow|gray|pink)\b"#,
    ]

    /// A typed number as a horizontal inset (`.padding()` is the system's 16).
    private static let paddingPatterns = [
        #"\.padding\(\s*\.(horizontal|leading|trailing)\s*,\s*-?[0-9]"#,
        #"\.padding\(\s*\[[^\]]*\b(horizontal|leading|trailing)\b[^\]]*\]\s*,\s*-?[0-9]"#,
        #"\.padding\(\s*-?[0-9]"#,
        #"\.padding\(\s*\)"#,
        #"EdgeInsets\([^)]*\b(leading|trailing):\s*-?[0-9]"#,
    ]

    /// Files that still carry the pattern, held to today's count (colours, paddings).
    /// Each is outside the 2026-10-03 F108/F119 fix list or is a capsule chip's own inner
    /// inset (law 55 names cards, lists, grids, pickers and headers, not a badge's text).
    private static let knownDebt: [String: (colors: Int, paddings: Int)] = [
        // Outside the F108 / F119 lists (follow-up, reported to the lead).
        "Screens/ContractorPackage.swift": (0, 3),
        "Screens/CompanyDocuments.swift": (0, 1),
        "Screens/CustomersScreen.swift": (2, 0),
        "Screens/DocumentDetailScreen.swift": (2, 0),
        "Screens/EstimateDetailScreen.swift": (0, 1),
        "Screens/EstimatesListScreen.swift": (1, 0),
        "Screens/InvoiceDetailScreen.swift": (0, 2),
        "Screens/InvoiceFormScreen.swift": (14, 0),
        "Screens/JobDetailScreen.swift": (1, 0),
        "Screens/JobsListScreen.swift": (0, 1),
        "Screens/ReceiptDetailScreen.swift": (3, 0),
        "Screens/SignatureEditorSheet.swift": (0, 1),
        "Screens/StatsScreen.swift": (0, 1),
        "Screens/SubcontractorDetails.swift": (4, 0),
        "Screens/SubcontractorFormScreen.swift": (2, 0),
        "Screens/WorkScheduleScreen.swift": (1, 0),
        "UIComponents/GLHubRow.swift": (1, 0),
        "UIComponents/PersonRowCard.swift": (0, 1),
        "UIComponents/SignatureKit.swift": (0, 1),
        "UIComponents/SwipeDeleteConfirmation.swift": (1, 0),
        // Capsule chips' own text inset, a glyph badge, and a 2 pt optical nudge (not a
        // card, list or header inset); the Price Sheet's empty state is outside the F119 list.
        "Screens/ChangeOrderScreens.swift": (0, 1),
        "Screens/EmployeeDetailScreen.swift": (0, 1),
        "Screens/IPadRootSplitView.swift": (0, 1),
        "Screens/MenuScreen.swift": (0, 2),
        "Screens/PriceSheetScreen.swift": (0, 4),
        "Screens/ReceiptsListScreen.swift": (0, 1),
        "Screens/SubcontractorDetailScreen.swift": (0, 3),
    ]

    private struct Offender: CustomStringConvertible {
        let path: String
        let line: Int
        let snippet: String
        var description: String { "\(path):\(line): \(snippet)" }
    }

    private static func offenders(_ patterns: [String],
                                  in files: [(path: String, text: String)]) -> [String: [Offender]] {
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var out: [String: [Offender]] = [:]
        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    out[file.path, default: []].append(
                        Offender(path: file.path, line: index + 1,
                                 snippet: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return out
    }

    private static var chromeFiles: [(path: String, text: String)] {
        GLSource.codeFiles().filter { file in
            chromeFolders.contains(where: { file.path.hasPrefix($0) })
                && !printedDocuments.contains(file.path)
        }
    }

    /// Every file over its allowance, with each offending line.
    private static func overBudget(_ found: [String: [Offender]],
                                   allowance: (String) -> Int) -> [String] {
        found.keys.sorted().compactMap { path in
            let hits = found[path] ?? []
            guard hits.count > allowance(path) else { return nil }
            return "\(path) has \(hits.count), allowed \(allowance(path)):\n  "
                + hits.map(\.description).joined(separator: "\n  ")
        }
    }

    @Test func appChromeUsesThemeColorTokens() {
        let found = Self.offenders(Self.colorPatterns, in: Self.chromeFiles)
        let over = Self.overBudget(found) { Self.knownDebt[$0]?.colors ?? 0 }
        #expect(over.isEmpty,
                "System or raw colours in app chrome (use GLTheme.textPrimary/textSecondary, surface tokens, statusGood/statusAttention/statusCritical):\n\(over.joined(separator: "\n"))")
    }

    @Test func appChromeUsesLayoutTokensForHorizontalInsets() {
        let found = Self.offenders(Self.paddingPatterns, in: Self.chromeFiles)
        let over = Self.overBudget(found) { Self.knownDebt[$0]?.paddings ?? 0 }
        #expect(over.isEmpty,
                "Typed horizontal insets in app chrome (use GLLayout.rowContentPadding inside a card, GLLayout.rowCardInset outside):\n\(over.joined(separator: "\n"))")
    }

    /// The instrument: the scan reads the real chrome, and each pattern family fires on
    /// the shapes it is meant to catch and stays quiet on the token forms.
    @Test func theScanReadsChromeAndMatchesTheBannedShapes() {
        #expect(Self.chromeFiles.count > 40, "expected the app's Screens/ and UIComponents/ sources")
        let bad: [(path: String, text: String)] = [("x", """
            Text("a").foregroundStyle(.secondary)
            .tint(.red)
            .fill(Color(.tertiarySystemFill))
            .foregroundStyle(empty ? .secondary : .primary)
            badge("b", color: item.isLabor ? .blue : .purple)
            .padding(.leading, 16)
            .padding()
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
            """)]
        let good: [(path: String, text: String)] = [("y", """
            Text("a").foregroundStyle(GLTheme.textSecondary)
            .tint(GLTheme.statusCritical)
            .padding(.leading, GLLayout.rowContentPadding)
            .padding(.vertical, 12)
            ToolbarItem(placement: .primaryAction) { }
            """)]
        #expect((Self.offenders(Self.colorPatterns, in: bad)["x"] ?? []).count == 5)
        #expect((Self.offenders(Self.paddingPatterns, in: bad)["x"] ?? []).count == 3)
        #expect(Self.offenders(Self.colorPatterns, in: good).isEmpty)
        #expect(Self.offenders(Self.paddingPatterns, in: good).isEmpty)
    }
}
