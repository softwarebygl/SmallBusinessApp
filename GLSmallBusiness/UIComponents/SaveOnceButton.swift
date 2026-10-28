//
//  SaveOnceButton.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A confirmation button that runs its action at most once. The create/record forms save
//  synchronously and then dismiss, but a fast double-tap can fire the action again during the
//  dismiss animation — which would insert a second record (a duplicate payment double-counts money).
//  This fires once, then stays disabled, so the screen that always dismisses on save can never
//  double-submit. (Forms that can stay open on a save error keep their own resettable guard instead.)
//
//  IT RE-ARMS WHEN THE SAVE DID NOT HAPPEN (2026-08-25, with the lapsed read-only rule). The action
//  returns whether it COMMITTED. A latch that fires unconditionally was correct while every tap
//  either saved or was already disabled — but a read-only refusal leaves the form open, and the
//  button would have stayed dead behind the alert: the person dismisses "your subscription ended",
//  reactivates, taps Save, and nothing happens ever again on that screen. Returning false re-arms
//  it, so the retry the alert invites is a retry the button can actually take.
//

import SwiftUI

struct SaveOnceButton: View {
    var title: LocalizedStringKey = "Save"
    var disabled: Bool = false
    /// Returns true when the save COMMITTED (the screen is dismissing); false when it did not, so
    /// the button re-arms and the person can try again.
    let action: () -> Bool

    @State private var latch = SaveOnceLatch()

    var body: some View {
        Button(title) { latch.fire(action) }
        .disabled(disabled || latch.fired)
    }
}

/// The duplicate-payment guard as a pure value (suite review 2026-09-02, so
/// the money-critical rule is pinned by a test): a committing action runs
/// once and every later fire is ignored; a REFUSING action (returns false —
/// the read-only gate said no) leaves the latch armed so the retry works.
struct SaveOnceLatch {
    private(set) var fired = false

    @discardableResult
    mutating func fire(_ action: () -> Bool) -> Bool {
        guard !fired else { return false }
        fired = true
        if !action() { fired = false; return false }
        return true
    }
}
