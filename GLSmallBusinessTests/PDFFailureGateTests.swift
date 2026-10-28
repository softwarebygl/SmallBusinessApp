//
//  PDFFailureGateTests.swift
//  GLSmallBusinessTests
//
//  Call-site facts about a PDF or export that couldn't be made (audit 2026-10-03 F123), read
//  from the app's code with comments stripped:
//    - Estimate, Invoice and Change Order sends re-render the PDF at the tap and stop with the
//      "Couldn't create the PDF" alert when that fails — never sending a missing PDF or the
//      last one made;
//    - a failed change order render clears the old PDF, so it is never previewed or sent as
//      if it were current;
//    - a change order whose invoice is gone has its Email and Text buttons disabled AND
//      guarded (the sheet behind them would be empty);
//    - the 1099 export says so when it wrote no files, instead of doing nothing.
//
//  These are facts about what a tap handler does with a render result inside a SwiftUI view,
//  which no unit test of the renderer can see, so a scan is the honest instrument (see
//  Harness/SourceScan.swift).
//

import Foundation
import Testing
@testable import GLSmallBusiness

@MainActor
struct PDFFailureGateTests {

    /// Every `func <name>(…)` in `code` as (signature, body), braces matched.
    static func functions(named name: String, in code: String) -> [(signature: String, body: String)] {
        var found: [(String, String)] = []
        var search = code.startIndex..<code.endIndex
        while let match = code.range(of: "func \(name)(", range: search) {
            guard let open = code[match.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1; if depth == 0 { break } }
                index = code.index(after: index)
            }
            let end = index < code.endIndex ? code.index(after: index) : code.endIndex
            found.append((String(code[match.lowerBound..<open]), String(code[open..<end])))
            search = end..<code.endIndex
        }
        return found
    }

    /// The tap action that ends in `call`: the text from the nearest `Button {` before it.
    static func buttonAction(endingIn call: String, in code: String) -> String? {
        guard let callRange = code.range(of: call),
              let button = code.range(of: "Button {", options: .backwards,
                                       range: code.startIndex..<callRange.lowerBound)
        else { return nil }
        return String(code[button.lowerBound..<callRange.upperBound])
    }

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Every broken rule, as a plain sentence; empty when the gates hold. `root` is the app
    /// target (a copy of an older revision's files can be pointed at to see this go red).
    static func violations(under root: URL) -> [String] {
        var out: [String] = []
        func code(_ path: String) -> String {
            guard let text = GLSource.code(path, under: root) else {
                out.append("\(path) is missing")
                return ""
            }
            return text
        }

        // (a) Estimate: the send taps go through one gate that checks the render result.
        let estimate = code("Screens/EstimateDetailScreen.swift")
        if !functions(named: "regeneratePDF", in: estimate).contains(where: { $0.signature.contains("-> Bool") }) {
            out.append("Estimate: regeneratePDF doesn't report whether the PDF was made")
        }
        if !functions(named: "openComposer", in: estimate).contains(where: {
            has(#"guard\s+regeneratePDF\(\)\s+else\s*\{\s*pdfFailed\s*=\s*true"#, $0.body)
        }) {
            out.append("Estimate: the send doesn't stop with pdfFailed when the PDF can't be made")
        }
        if has(#"sendAction\s*=\s*\.(email|text)"#, estimate) {
            out.append("Estimate: a send tap opens the composer without checking the PDF")
        }
        if !estimate.contains(".pdfFailureAlert($pdfFailed)") {
            out.append("Estimate: no 'Couldn't create the PDF' alert")
        }

        // (a) Invoice: prepareSend checks the render result before anything else is built.
        let invoice = code("Screens/InvoiceDetailScreen.swift")
        if !functions(named: "regeneratePDF", in: invoice).contains(where: { $0.signature.contains("-> Bool") }) {
            out.append("Invoice: regeneratePDF doesn't report whether the PDF was made")
        }
        if !functions(named: "prepareSend", in: invoice).contains(where: {
            has(#"guard\s+regeneratePDF\(\)\s+else\s*\{\s*pdfFailed\s*=\s*true"#, $0.body)
        }) {
            out.append("Invoice: the send doesn't stop with pdfFailed when the PDF can't be made")
        }
        if !invoice.contains(".pdfFailureAlert($pdfFailed)") {
            out.append("Invoice: no 'Couldn't create the PDF' alert")
        }

        // (a) Change order: same gate.
        let changeOrder = code("Screens/ChangeOrderScreens.swift")
        if !functions(named: "send", in: changeOrder).contains(where: {
            has(#"guard\s+regenerate\(\)\s+else\s*\{\s*pdfFailed\s*=\s*true"#, $0.body)
        }) {
            out.append("Change order: the send doesn't stop with pdfFailed when the PDF can't be made")
        }
        if has(#"sendAction\s*=\s*\.(email|text)"#, changeOrder) {
            out.append("Change order: a send tap opens the composer without checking the PDF")
        }
        if !changeOrder.contains(".pdfFailureAlert($pdfFailed)") {
            out.append("Change order: no 'Couldn't create the PDF' alert")
        }

        // (b) Change order: a failed render clears the last PDF.
        let regenerate = functions(named: "regenerate", in: changeOrder)
        if regenerate.isEmpty || !regenerate.allSatisfy({
            $0.signature.contains("-> Bool")
                && has(#"else\s*\{[^{}]*pdfURL\s*=\s*nil"#, $0.body)
                && has(#"else\s*\{[^{}]*pdfData\s*=\s*nil"#, $0.body)
        }) {
            out.append("Change order: a failed render keeps the old PDF (pdfURL/pdfData not cleared)")
        }

        // (c) Change order: no invoice/contract = Email and Text disabled and refused at the tap.
        if !has(#"\.disabled\(\s*(recipientEmail\.isEmpty|invoice\?\.recipientEmail\.isEmpty\s*\?\?\s*true)"#, changeOrder) {
            out.append("Change order: Email stays enabled when the invoice or contract is gone")
        }
        if !has(#"\.disabled\(\s*(recipientPhone\.isEmpty|invoice\?\.recipientPhone\.isEmpty\s*\?\?\s*true)"#, changeOrder) {
            out.append("Change order: Text stays enabled when the invoice or contract is gone")
        }
        for call in ["send(.email)", "send(.text)"]
        where !has(#"guard\s+(hasRecipient|invoice\s*!=\s*nil)"#, buttonAction(endingIn: call, in: changeOrder) ?? "") {
            out.append("Change order: the \(call) tap isn't refused when the invoice or contract is gone")
        }

        // (d) 1099 export: an allowed export that wrote nothing raises the alert.
        let subs = code("Screens/SubcontractorsScreen.swift")
        if !has(#"exportFiles\.isEmpty\s*\{\s*exportFailed\s*=\s*true"#, subs) {
            out.append("1099 export: an export that wrote no files does nothing")
        }
        if !has(#"\.alert\([^)]*isPresented:\s*\$exportFailed"#, subs) {
            out.append("1099 export: no alert bound to exportFailed")
        }
        return out
    }

    @Test func aPDFOrExportThatCouldNotBeMadeIsNeverSentSilently() {
        let broken = Self.violations(under: GLSource.appRoot)
        #expect(broken.isEmpty, "\(broken.joined(separator: "\n"))")
    }

    /// The scan itself works: it finds what it looks for, and an unguarded tap reads as one.
    @Test func scanHelpersFindTheirTargets() {
        let sample = """
        private func regenerate() -> Bool { guard ok else { pdfURL = nil; return false }; return true }
        Button { guard invoice != nil else { return }; send(.email) }
        Button { send(.text) }
        """
        #expect(Self.functions(named: "regenerate", in: sample).first?.signature.contains("-> Bool") == true)
        #expect(Self.buttonAction(endingIn: "send(.email)", in: sample)?.contains("invoice != nil") == true)
        #expect(Self.buttonAction(endingIn: "send(.text)", in: sample)?.contains("invoice != nil") == false)
    }
}
