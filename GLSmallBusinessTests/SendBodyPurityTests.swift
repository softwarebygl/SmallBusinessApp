//
//  SendBodyPurityTests.swift
//  GLSmallBusinessTests
//
//  Call-site facts about sending and sharing (audit 2026-10-03 F89, F30), read from the app's
//  code with comments stripped:
//    - share and send files are written when Share, Email or Text is tapped, never while a
//      screen draws (a body pass re-wrote every invoice photo on each re-render);
//    - the change order toolbar has no empty "…" menu (law 4: no placeholder controls).
//

import Foundation
import Testing
@testable import GLSmallBusiness

@MainActor
struct SendBodyPurityTests {

    /// The body of every `func <name>` in `code`, braces matched.
    private func functionBodies(named name: String, in code: String) -> [String] {
        var bodies: [String] = []
        var search = code.startIndex..<code.endIndex
        while let found = code.range(of: "func \(name)", range: search) {
            guard let open = code[found.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1; if depth == 0 { break } }
                index = code.index(after: index)
            }
            let end = index < code.endIndex ? code.index(after: index) : code.endIndex
            bodies.append(String(code[open..<end]))
            search = end..<code.endIndex
        }
        return bodies
    }

    @Test func noShareFileIsWrittenWhileAScreenDraws() throws {
        // The invoice's files are built only by SendPreparer, at the tap.
        for file in GLSource.codeFiles() where file.path != "Services/Domain/SendPreparer.swift" {
            #expect(!file.text.contains("invoiceFileURLs"), "\(file.path) builds invoice files outside SendPreparer")
        }
        let invoice = try #require(GLSource.code("Screens/InvoiceDetailScreen.swift"))
        #expect(!invoice.contains("shareableURLs()"), "the Share button wrote every photo on each render")

        // The compose sheets show content prepared at the tap; they never write it themselves.
        for path in ["Screens/InvoiceDetailScreen.swift", "Screens/EstimateDetailScreen.swift"] {
            let code = try #require(GLSource.code(path))
            let sheets = functionBodies(named: "sendSheet", in: code)
            #expect(!sheets.isEmpty, "\(path) has a sendSheet")
            for sheet in sheets {
                #expect(!sheet.contains("SendPreparer.invoice(") && !sheet.contains("SendPreparer.estimate("),
                        "\(path): sendSheet builds (and writes) its files on every render")
            }
        }

        // Certificates are written for sharing at the tap, not from a computed property the
        // toolbar reads on every render.
        for path in ["Screens/DocumentDetailScreen.swift", "Screens/InsuranceDocuments.swift"] {
            let code = try #require(GLSource.code(path))
            #expect(code.range(of: #"var\s+shareURLs?\s*:"#, options: .regularExpression) == nil,
                    "\(path) writes its share files from a computed property")
        }
    }

    @Test func changeOrderToolbarHasNoEmptyMenu() throws {
        let code = try #require(GLSource.code("Screens/ChangeOrderScreens.swift"))
        #expect(code.range(of: #"Menu\s*\{\s*\}"#, options: .regularExpression) == nil,
                "an empty \"…\" menu is a button that does nothing (law 4)")
    }
}
