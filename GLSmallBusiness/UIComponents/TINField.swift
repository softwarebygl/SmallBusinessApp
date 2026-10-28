//
//  TINField.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  A taxpayer-ID (SSN/EIN) entry field. A plain TextField let people type letters and symbols into an
//  identifier that is digits-only; this uses the number pad and filters + auto-formats every keystroke,
//  so the user can only ever produce a valid-looking SSN (XXX-XX-XXXX) or EIN (XX-XXXXXXX).
//
//  Formats atomically in the UITextField delegate (like PhoneTextField), so a digit can NEVER be dropped
//  under fast input/paste/autofill — critical for a tax ID, where a silently dropped digit produces a
//  wrong-but-valid-looking number on the 1099/W-9. (A SwiftUI TextField + .onChange reformat round-trips
//  through the binding and can race fast input — exactly the failure PhoneTextField was built to avoid.)
//

import SwiftUI

/// Pure formatting, kept out of the view so it can be unit-tested (and `nonisolated` so it runs anywhere).
nonisolated enum TINFormatter {
    /// Keep only digits (max 9) and group them with dashes for the given ID type.
    /// EIN → `XX-XXXXXXX`; SSN (and unknown) → `XXX-XX-XXXX`. Partial input formats as far as it goes.
    /// ASCII 0-9 only: `isNumber` alone would keep pasted Arabic-Indic/full-width numerals (the number
    /// pad blocks typing, not paste), which would sail through the count==9 checks and print an invalid
    /// TIN on the W-9/1099-NEC. Same restriction as AutoClearNumberField's parser.
    static func format(_ raw: String, kind: W9TINType?) -> String {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber }.prefix(9))
        guard !digits.isEmpty else { return "" }

        let groupSizes = (kind == .ein) ? [2, 7] : [3, 2, 4]
        var result = ""
        var index = digits.startIndex
        for (groupNumber, size) in groupSizes.enumerated() {
            guard index < digits.endIndex else { break }
            if groupNumber > 0 { result += "-" }
            let end = digits.index(index, offsetBy: size, limitedBy: digits.endIndex) ?? digits.endIndex
            result += digits[index..<end]
            index = end
        }
        return result
    }
}

#if canImport(UIKit)
import UIKit

struct TINField: UIViewRepresentable {
    let kind: W9TINType?
    @Binding var text: String

    private var placeholder: String { kind == .ein ? "12-3456789" : "123-45-6789" }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.keyboardType = .numberPad        // no alphabetic toggle, so letters/symbols can't be typed
        field.borderStyle = .none
        field.textAlignment = .right           // matches the prior .multilineTextAlignment(.trailing)
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.accessibilityIdentifier = "tinField"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.text = TINFormatter.format(text, kind: kind)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Keep the coordinator's kind current (SSN<->EIN grouping changes at runtime) and reflect external
        // changes (e.g. switching the ID type re-groups the same digits), reformatted.
        context.coordinator.kind = kind
        field.placeholder = placeholder
        let formatted = TINFormatter.format(text, kind: kind)
        if field.text != formatted { field.text = formatted }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, kind: kind) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var kind: W9TINType?
        init(text: Binding<String>, kind: W9TINType?) { _text = text; self.kind = kind }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let current = field.text ?? ""
            guard let r = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: r, with: string)
            let formatted = TINFormatter.format(proposed, kind: kind)
            field.text = formatted
            text = formatted
            // Digits-only, left-to-right, dashes only append → park the caret at the end.
            let end = field.endOfDocument
            field.selectedTextRange = field.textRange(from: end, to: end)
            return false   // we applied the (formatted) change ourselves
        }
    }
}
#else
struct TINField: View {
    let kind: W9TINType?
    @Binding var text: String
    private var placeholder: String { kind == .ein ? "12-3456789" : "123-45-6789" }
    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.trailing)
            .onChange(of: text) { _, newValue in
                let formatted = TINFormatter.format(newValue, kind: kind)
                if formatted != newValue { text = formatted }
            }
    }
}
#endif

extension View {
    /// Short alphanumeric identifiers (license #, W-9 exemption codes): upper-case, never autocorrected.
    func idCodeStyle() -> some View {
        self
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
    }
}
