//
//  SwipeDeleteConfirmation.swift
//  GLSmallBusiness
//
//  The confirm-before-delete pieces every list and detail screen shares. Our records are
//  permanent (deleting a subcontractor, invoice, etc. can't be undone and often cascades), so
//  every delete asks first, with an explicit "can't be undone" message (law 8a).
//
//  THE SWIPE ONLY ASKS (law 8, the 2026-09-26 crash). A confirm-first list never uses
//  `.onDelete`, a destructive-role swipe button or a full swipe: each of those takes the row out
//  of the list the moment it's tapped, while the data stays until the alert confirms. The list
//  then counts a row the data still has and crashes when the real delete lands ("Invalid number
//  of items in section"). The row's swipe is `confirmFirstDeleteSwipe`: a plain-role Delete that
//  only stages the row, so the row stays listed until the confirmed delete removes the data.
//  (`.onDelete` stays right for draft lines in an unsaved form, which go at once with no alert.)
//
//  IMPORTANT: the swipe stashes the actual OBJECTS, NOT an IndexSet. Confirmation is a
//  user-duration modal, and the list is `@Query`-backed — a sync (or filter change) can mutate it
//  while the alert is open. Re-indexing a stale offset on confirm would crash (out of range) or
//  delete the WRONG record. Capturing objects avoids both.
//
//  Usage:
//      @State private var pendingDelete: [Subcontractor]?
//      ...
//      ForEach(visibleSubs) { sub in
//          row(sub)
//              .confirmFirstDeleteSwipe { pendingDelete = [sub] }
//      }
//      ...
//      .swipeDeleteConfirmation($pendingDelete,
//                               title: "Delete this subcontractor?",
//                               message: "Their payment history is removed too. This can't be undone.") { subs in
//          delete(subs)
//      }
//

import SwiftUI

extension View {
    /// The row's swipe Delete for a list that confirms first: plain role, no full swipe, so the
    /// row stays put until the confirmed delete removes the data. `request` only stages it
    /// (a pending-delete state, or an explanation such as the paid lock).
    func confirmFirstDeleteSwipe(_ request: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: request) {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Presents the standard destructive confirmation for stashed swipe-to-delete items, and runs
    /// `perform` with the exact captured objects only if the user confirms. Pair with
    /// `confirmFirstDeleteSwipe { <pending>.wrappedValue = [item] }`.
    func swipeDeleteConfirmation<Item>(
        _ pending: Binding<[Item]?>,
        title: LocalizedStringKey,
        message: LocalizedStringKey = "This can’t be undone.",
        perform: @escaping ([Item]) -> Void
    ) -> some View {
        deleteConfirmation(
            Binding(get: { pending.wrappedValue != nil },
                    set: { if !$0 { pending.wrappedValue = nil } }),
            title: title,
            message: message
        ) {
            if let items = pending.wrappedValue { perform(items) }
            pending.wrappedValue = nil
        }
    }

    /// The standard delete alert for one thing that isn't a list row (a photo, a saved
    /// signature): `confirm` (destructive) runs `perform`; Cancel does nothing.
    func deleteConfirmation(
        _ isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey = "This can’t be undone.",
        confirm: LocalizedStringKey = "Delete",
        perform: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(confirm, role: .destructive) { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
