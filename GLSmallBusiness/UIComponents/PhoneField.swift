//
//  PhoneField.swift
//  GLSmallBusiness
//
//  Live US phone-number formatting — auto-inserts dashes as the user types (5551234567 → 555-123-4567)
//  and ignores any dashes/spaces the user types themselves.
//
//  `PhoneFormatter` is the pure formatting function (unit-tested). `PhoneTextField` is the field to use
//  in forms: it formats at the UIKit level (UITextField delegate), so each edit is applied atomically and
//  a character can NEVER be dropped — even under paste, autofill, a third-party keyboard, or
//  faster-than-human input. (A plain SwiftUI TextField + `.onChange` reformat round-trips through the
//  binding, which can race fast input and lose a digit — which is exactly what the XCUITest caught.)
//

import SwiftUI

enum PhoneFormatter {
    /// Formats a phone number with dashes for display/storage. Non-digits are stripped first, so dashes
    /// the user types are absorbed rather than duplicated. US 10-digit numbers become ###-###-####; a
    /// leading US country code (11 digits starting with 1) becomes 1-###-###-####; any digits beyond
    /// that are appended unformatted so nothing the user entered is ever lost.
    static func format(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        let d = Array(digits)

        // US country code: "+1 (555) 123-4567" → keep the 1 visible, format the rest.
        if d.count == 11, d.first == "1" {
            return "1-" + format(String(d.dropFirst()))
        }

        func part(_ lo: Int, _ hi: Int) -> String { String(d[lo..<min(hi, d.count)]) }
        switch d.count {
        case 0...3:
            return part(0, 3)
        case 4...6:
            return "\(part(0, 3))-\(part(3, 6))"
        case 7...10:
            return "\(part(0, 3))-\(part(3, 6))-\(part(6, 10))"
        default:
            // More than 10 digits and not a plain US country code — format the first 10, keep the rest.
            return "\(part(0, 3))-\(part(3, 6))-\(part(6, 10))\(part(10, d.count))"
        }
    }
}

#if canImport(UIKit)
import UIKit

/// A phone field that formats live and never drops a character. Formats inside the UITextField delegate,
/// so input and formatting can't get out of sync the way a SwiftUI `.onChange` reformat can.
struct PhoneTextField: UIViewRepresentable {
    /// A catalog key ("Phone"), shown in the app's language — a UIKit field never reads the
    /// SwiftUI locale, so it is resolved here through mbLoc.
    let placeholder: String.LocalizationValue
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = mbLoc(placeholder)
        field.keyboardType = .phonePad
        field.textContentType = .telephoneNumber
        field.borderStyle = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        // Fill the row width (and leave room for a trailing marker, e.g. the required-field asterisk).
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.text = PhoneFormatter.format(text)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Follows a language switch made while the form is open.
        let placeholder = mbLoc(placeholder)
        if field.placeholder != placeholder { field.placeholder = placeholder }
        // Reflect external changes (e.g. the contact picker filling the number), formatted.
        let formatted = PhoneFormatter.format(text)
        if field.text != formatted { field.text = formatted }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let current = field.text ?? ""
            guard let r = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: r, with: string)
            let formatted = PhoneFormatter.format(proposed)
            field.text = formatted
            text = formatted
            // Phone entry runs left-to-right and dashes only get appended, so park the caret at the end.
            let end = field.endOfDocument
            field.selectedTextRange = field.textRange(from: end, to: end)
            return false   // we applied the (formatted) change ourselves
        }
    }
}
#else
/// Non-UIKit fallback — keeps call sites identical on platforms without UITextField.
struct PhoneTextField: View {
    let placeholder: String.LocalizationValue
    @Binding var text: String
    var body: some View {
        TextField(mbLoc(placeholder), text: $text)
            .onChange(of: text) { _, newValue in
                let formatted = PhoneFormatter.format(newValue)
                if formatted != newValue { text = formatted }
            }
    }
}
#endif
