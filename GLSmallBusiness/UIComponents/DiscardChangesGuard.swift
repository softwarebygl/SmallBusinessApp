//
//  DiscardChangesGuard.swift
//  GLSmallBusiness
//
//  Prevents accidental data loss on data-entry forms. A pushed form is dismissed by the system Back
//  button OR the interactive swipe-from-edge gesture — and a stray swipe was wiping a half-finished
//  invoice. When the form has UNSAVED edits this guard hides the system back button (which also disables
//  the swipe-back gesture) and substitutes a Back button that asks "Discard changes?" first. With no
//  unsaved edits it's a complete no-op, so navigation feels exactly as before.
//
//  Forms detect "dirty" by snapshotting their editable state on appear and comparing — see the
//  `isDirty` computed in each form. Saving uses its own toolbar button and dismisses directly, so it is
//  never blocked by this guard.
//

import SwiftUI

private struct DiscardChangesGuard: ViewModifier {
    let isDirty: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            confirming = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.backward")
                                Text("Back")
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("You have unsaved changes. If you go back now, nothing you entered will be saved.")
            }
    }
}

extension View {
    /// Guards a pushed data-entry form against accidental dismissal when `isDirty` is true. A no-op when
    /// `isDirty` is false, so the form behaves normally until the user actually changes something.
    func discardChangesGuard(isDirty: Bool) -> some View {
        modifier(DiscardChangesGuard(isDirty: isDirty))
    }
}
