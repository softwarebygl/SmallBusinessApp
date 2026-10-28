//
//  CustomerDeleteConfirmation.swift
//  GLSmallBusiness
//
//  Owner ruling 2026-09-25 (7): a customer (a client) is deleted ONLY when the person asks, after
//  an alert that shows the client's name, says that everything tied to them goes too, and needs
//  the name TYPED before Delete turns on. Clients only — every other delete keeps the standard
//  alert — and the app never deletes one on its own.
//
//  The gate itself is GoldLifeUI's `.glTypedNameConfirmation` (the same one the assistant's
//  delete tool raises through GoldLifeAI), so the screens and the assistant ask the same question
//  in the same words. This file is only My Business's wrapper: which name is typed, the title,
//  and a queue so a multi-select delete asks for each client in turn.
//
//  The alert holds a VALUE snapshot (id + name), never the model: the alert keeps its item for
//  its dismissal animation, and reading a customer that was just deleted is a SwiftData trap.
//

import SwiftUI
import SwiftData
import GoldLifeUI

enum CustomerDeleteConfirmation {
    /// The name the person types: first and last (a middle name would only be more typing),
    /// else the business name. Nil for a record with no name at all — the gate could never be
    /// satisfied, so that one gets the standard alert instead of becoming undeletable.
    nonisolated static func typedName(first: String, last: String, business: String?) -> String? {
        let person = [first, last]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !person.isEmpty { return person }
        let company = (business ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return company.isEmpty ? nil : company
    }

    static func typedName(for customer: Customer) -> String? {
        typedName(first: customer.firstName, last: customer.lastName, business: customer.businessName)
    }

    /// The alert's title: who goes, and that everything tied to them goes too. GoldLifeUI's
    /// message under it says it can't be undone and prints the name to type.
    static func title(name: String) -> String {
        mbLoc("Delete \(name)? Their estimates, invoices, change orders, receipts, and documents are removed too.")
    }

    /// One pending question, as values (see the header).
    struct Pending: Identifiable, Equatable {
        let id: PersistentIdentifier
        /// Nil: the record has no name, so the standard alert asks instead.
        let typedName: String?
    }

    static func pending(for customer: Customer) -> Pending {
        Pending(id: customer.persistentModelID, typedName: typedName(for: customer))
    }
}

extension View {
    /// Asks before deleting each customer in `queue`, one at a time, in order: the typed-name
    /// gate (the standard alert for a nameless record). Delete runs `perform` for that customer
    /// and moves on to the next; `perform` answering false (the delete was refused and the screen
    /// is explaining why) or Cancel ends the run and keeps the rest.
    func customerDeleteConfirmation(_ queue: Binding<[Customer]>,
                                    perform: @escaping (Customer) -> Bool) -> some View {
        modifier(CustomerDeleteConfirmationModifier(queue: queue, perform: perform))
    }
}

private struct CustomerDeleteConfirmationModifier: ViewModifier {
    @Binding var queue: [Customer]
    let perform: (Customer) -> Bool

    /// The question on screen.
    @State private var shown: CustomerDeleteConfirmation.Pending?
    /// Between two questions: the last alert is still animating away, and presenting the next
    /// one in the same beat would be dropped.
    @State private var advancing = false

    func body(content: Content) -> some View {
        content
            // Writes are ignored: a dismissal that isn't a button tap is not a Cancel, and the
            // buttons below settle the queue themselves.
            .glTypedNameConfirmation(
                isPresented: Binding(get: { shown?.typedName != nil }, set: { _ in }),
                presenting: shown,
                title: { CustomerDeleteConfirmation.title(name: $0.typedName ?? "") },
                name: { $0.typedName ?? "" },
                onConfirm: { confirm($0) },
                onCancel: { _ in cancel() })
            .alert(mbLoc("Delete this customer?"),
                   isPresented: Binding(get: { shown != nil && shown?.typedName == nil }, set: { _ in }),
                   presenting: shown) { pending in
                Button(mbLoc("Delete"), role: .destructive) { confirm(pending) }
                Button(mbLoc("Cancel"), role: .cancel) { cancel() }
            } message: { _ in
                Text("Their estimates, invoices, change orders, receipts, and documents are removed too. This can’t be undone.")
            }
            .onChange(of: queue.map(\.persistentModelID), initial: true) { _, _ in showNextIfIdle() }
    }

    private func showNextIfIdle() {
        guard shown == nil, !advancing else { return }
        // A customer a sync removed while they waited is skipped, never asked about.
        queue.removeAll { $0.modelContext == nil || $0.isDeleted }
        shown = queue.first.map { CustomerDeleteConfirmation.pending(for: $0) }
    }

    private func confirm(_ pending: CustomerDeleteConfirmation.Pending) {
        shown = nil
        // Held BEFORE the queue moves: its change must not raise the next question while this
        // alert is still going away.
        advancing = true
        guard let customer = queue.first(where: { $0.persistentModelID == pending.id }) else {
            endRun()
            return
        }
        queue.removeAll { $0.persistentModelID == pending.id }
        guard perform(customer) else {
            endRun()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            advancing = false
            showNextIfIdle()
        }
    }

    private func cancel() {
        shown = nil
        endRun()
    }

    private func endRun() {
        advancing = false
        queue = []
    }
}
