//
//  Copyable.swift
//  GLSmallBusiness
//
//  Long-press-to-copy with the system's native feel. `.textSelection(.enabled)` shows the edit
//  bubble eventually, but gives no press feedback while you wait — and doesn't cover every layout
//  (multiline addresses). A context menu lifts the content into the standard preview with the
//  system spring + haptic the instant the press registers, exactly like Contacts.
//

import SwiftUI
import UIKit

extension View {
    /// Adds a native long-press Copy menu for `value`. No-op when there's nothing to copy.
    @ViewBuilder
    func copyable(_ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "—" {
            self
        } else {
            contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = trimmed
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        }
    }
}
