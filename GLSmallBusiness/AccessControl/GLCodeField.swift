//
//  GLCodeField.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI

/// Branded access-code entry that reads  `GL - [ ____ ] - [ ____ ]`.
///
/// The user types only the two 4-character groups; the "GL" and the dashes are fixed decoration
/// so it's obvious where the code goes. Input is forced to uppercase letters/numbers, capped at
/// 4 characters per group, and focus auto-advances (then fires `onComplete`).
struct GLCodeField: View {
    @Binding var group1: String
    @Binding var group2: String
    var onComplete: () -> Void = {}

    private enum Field: Hashable { case one, two }
    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 8) {
            decoration("GL")
            decoration("-")
            groupBox($group1, field: .one)
            decoration("-")
            groupBox($group2, field: .two)
        }
        .onChange(of: group1) { _, newValue in
            let clean = Self.clamp(newValue)
            if clean != group1 { group1 = clean }
            if clean.count == 4 { focus = .two }
        }
        .onChange(of: group2) { _, newValue in
            let clean = Self.clamp(newValue)
            if clean != group2 { group2 = clean }
            if clean.count == 4 {
                focus = nil
                if group1.count == 4 { onComplete() }
            }
        }
    }

    private func decoration(_ text: String) -> some View {
        Text(text)
            .font(.system(.title2, design: .monospaced).weight(.bold))
            .foregroundStyle(.secondary)
    }

    private func groupBox(_ text: Binding<String>, field: Field) -> some View {
        TextField("", text: text, prompt: Text("____"))
            .focused($focus, equals: field)
            .font(.system(.title2, design: .monospaced).weight(.bold))
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .frame(width: 92, height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focus == field ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }

    /// Uppercase, ASCII letters/numbers only, max 4 characters.
    private static func clamp(_ s: String) -> String {
        String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(4))
    }
}

#Preview {
    @Previewable @State var a = ""
    @Previewable @State var b = ""
    GLCodeField(group1: $a, group2: $b).padding()
}
