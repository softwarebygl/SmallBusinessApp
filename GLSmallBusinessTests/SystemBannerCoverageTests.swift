//
//  SystemBannerCoverageTests.swift
//  GLSmallBusinessTests
//
//  QA audit 2026-10-03 F34: the standing notices (sample data, offline, lapsed) ride under the
//  bar of every screen and sheet, in one slot. A screen that sets a large title and its title
//  clearance (`.contentMargins(.top, GLScript.titleClearance…`) must mount the slot too,
//  directly after it or through `glFormBackground()`. Source scan, comments stripped.
//

import Testing
import Foundation

struct SystemBannerCoverageTests {

    private static let screens = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness/Screens")

    /// Titled views that deliberately mount no slot, with the reason. Shrink-only.
    private static let exempt: [String: String] = [
        "IPadRootSplitView": "the sidebar column; the notices ride the list column beside it (one card, not two)",
        "JobPhotoViewer": "a full-screen photo canvas",
        "MBAssistantTitle": "the assistant screen mounts the one slot by hand, with its own offline sentence (law 5)",
        "BusinessProfileHost": "a placeholder shown for a moment; the content it waits for mounts the slot",
    ]

    private static func code(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }

    /// The declaration name of a top-level type line (`struct X`, `private struct X<T>`), if it is one.
    private static func typeName(_ line: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(where: { $0 == "struct" || $0 == "final" || $0 == "class" }),
              !line.hasPrefix(" ") else { return nil }
        let name = words[(words[i] == "final" ? i + 2 : i + 1)...].first ?? ""
        return String(name.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    @Test func everyTitledScreenMountsTheNoticeSlot() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.screens, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        let mounts = ["mbSystemBanners", "glFormBackground", "MBSystemBannerInset"]
        var missing: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map { Self.code(String($0)) }
            // Cut the file into its top-level types; a titled view must mount the slot in ITS type.
            var segments: [(name: String, start: Int, end: Int)] = []
            for (i, line) in lines.enumerated() {
                if let name = Self.typeName(line) {
                    if var last = segments.popLast() { last.end = i; segments.append(last) }
                    segments.append((name, i, lines.count))
                }
            }
            for segment in segments where Self.exempt[segment.name] == nil {
                let body = lines[segment.start..<segment.end]
                guard body.contains(where: { $0.contains(".contentMargins(.top, GLScript.titleClearance") }) else { continue }
                if !body.contains(where: { line in mounts.contains { line.contains($0) } }) {
                    missing.append("\(file.lastPathComponent): \(segment.name)")
                }
            }
        }
        #expect(missing.isEmpty, "titled screens without the notice slot:\n\(missing.joined(separator: "\n"))")
    }
}
