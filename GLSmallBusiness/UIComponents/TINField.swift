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

import SwiftUI

/// Pure formatting, kept out of the view so it can be unit-tested (and `nonisolated` so it runs anywhere).
nonisolated enum TINFormatter {
    /// Keep only digits (max 9) and group them with dashes for the given ID type.
    /// EIN → `XX-XXXXXXX`; SSN (and unknown) → `XXX-XX-XXXX`. Partial input formats as far as it goes.
    static func format(_ raw: String, kind: W9TINType?) -> String {
        let digits = String(raw.filter(\.isNumber).prefix(9))
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

struct TINField: View {
    let kind: W9TINType?
    @Binding var text: String

    private var placeholder: String { kind == .ein ? "12-3456789" : "123-45-6789" }

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.trailing)
            #if !os(macOS)
            .keyboardType(.numberPad)   // no alphabetic toggle, so letters/symbols can't be typed
            #endif
            .onChange(of: text) { _, newValue in
                // Re-format on every change (also sanitizes anything pasted in).
                let formatted = TINFormatter.format(newValue, kind: kind)
                if formatted != newValue { text = formatted }
            }
    }
}

extension View {
    /// Short alphanumeric identifiers (license #, W-9 exemption codes): upper-case, never autocorrected.
    func idCodeStyle() -> some View {
        self
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
    }
}
