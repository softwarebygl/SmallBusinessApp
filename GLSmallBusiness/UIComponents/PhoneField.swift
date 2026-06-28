//
//  PhoneField.swift
//  GLSmallBusiness
//
//  Live US phone-number formatting — auto-inserts dashes as the user types (5551234567 → 555-123-4567)
//  and ignores any dashes/spaces the user types themselves. Mirrors the TINField/TINFormatter approach
//  (sanitize to digits, reformat on every keystroke). Apply `.phoneNumberFormatted($binding)` to any
//  phone TextField; keep `.keyboardType(.phonePad)` alongside it.
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

extension View {
    /// Live US phone formatting on a text binding — inserts dashes as the user types. Pairs with
    /// `.keyboardType(.phonePad)`. Reformats only on change, so an existing stored value isn't disturbed
    /// until the user edits it.
    func phoneNumberFormatted(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            let formatted = PhoneFormatter.format(newValue)
            if formatted != newValue { text.wrappedValue = formatted }
        }
    }
}
