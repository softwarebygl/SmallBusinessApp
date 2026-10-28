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
//  The substitute button is a BARE CHEVRON, matching the system back button it replaces
//  (GoldLifeUI ruling S6): the swap has to be invisible, or going dirty flips the corner of the
//  screen for the user.
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
                            // A BARE chevron, semibold to match the system back
                            // indicator it stands in for (GoldLifeUI ruling S6).
                            // It used to read "‹ Back", so the corner of the screen
                            // visibly changed the moment a form went dirty — and the
                            // word was hardcoded English while the rest of the app
                            // localizes. The label is now VoiceOver-only.
                            Image(systemName: "chevron.backward")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel(mbLoc("Back"))
                        .accessibilityIdentifier("discardBackButton")
                    }
                }
            }
            .alert("Discard changes?", isPresented: $confirming) {
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
