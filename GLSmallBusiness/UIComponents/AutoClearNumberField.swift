//
//  AutoClearNumberField.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// A numeric entry field that clears its default the moment it's tapped, so you can type a
/// fresh number instead of deleting the prefilled value first.
///
/// - Tapping in while the value still equals `clearsAt` (its default) empties the field.
/// - Tapping in on a value you've already entered keeps it, shown as a plain editable number.
/// - Tapping away without typing restores the previous value (nothing is lost).
struct AutoClearNumberField: View {
    enum Style { case number, currency }

    let placeholder: String
    @Binding var value: Double
    var style: Style = .number
    /// The default value that should auto-clear on tap (0 for prices/rates, 1 for quantities).
    var clearsAt: Double = 0

    @FocusState private var focused: Bool
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            #if !os(macOS)
            .keyboardType(.decimalPad)
            #endif
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in
                // Stay in sync if the value is changed elsewhere while we're not editing.
                if !focused { text = display(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    text = (value == clearsAt) ? "" : editable(value)
                } else {
                    let trimmed = normalized(text)
                    if !trimmed.isEmpty, let parsed = Double(trimmed) {
                        value = parsed
                    }
                    // Empty or unparseable on blur → keep the existing value.
                    text = display(value)
                }
            }
            .onChange(of: text) { _, newText in
                guard focused else { return }
                let trimmed = normalized(newText)
                if let parsed = Double(trimmed) { value = parsed }
            }
    }

    /// Strips currency/grouping symbols so a typed or formatted string parses as a Double.
    private func normalized(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
    }

    /// The value as the user reads it when not editing.
    private func display(_ value: Double) -> String {
        switch style {
        case .number: value.formatted(.number)
        case .currency: value.formatted(.currency(code: "USD"))
        }
    }

    /// A plain, editable number (no symbols or grouping) shown when tapping an existing value.
    private func editable(_ value: Double) -> String {
        value.formatted(.number.grouping(.never))
    }
}
