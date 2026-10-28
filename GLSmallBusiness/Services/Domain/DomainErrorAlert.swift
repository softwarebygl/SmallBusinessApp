//
//  DomainErrorAlert.swift
//  GLSmallBusiness
//
//  How a screen shows a refusal a domain service threw. Screens gate with
//  `ReadOnlyGate.allows(_:into:)` and validate in the form BEFORE they call a service, so in
//  practice this alert never appears from a tap — it exists so that a refusal the form did not
//  predict (a record deleted mid-save, a cap reached from another path) is said out loud instead
//  of the Save button silently re-arming (law 6, the person's half).
//

import SwiftUI

extension DomainError {
    /// Sends a thrown error to the right alert: read-only goes to the screen's existing
    /// read-only alert (same copy, same Reactivate button as every other refusal); anything else
    /// goes to `domainError`.
    @MainActor
    static func present(_ error: any Error,
                        readOnly: Binding<MBWriteOperation?>,
                        domainError: Binding<DomainError?>) {
        let domain = (error as? DomainError) ?? .recordNotFound
        if case .readOnly(let raw, _) = domain, let operation = MBWriteOperation(rawValue: raw) {
            ReadOnlyGate.refuse(operation, into: readOnly)
        } else {
            domainError.wrappedValue = domain
        }
    }
}

extension View {
    /// The domain-refusal alert for one screen or sheet, bound to that screen's own state
    /// (per screen for the same reason as `readOnlyRefusalAlert`: an alert presents from the
    /// context the person is looking at).
    func domainErrorAlert(_ error: Binding<DomainError?>) -> some View {
        alert(error.wrappedValue?.errorDescription ?? "",
              isPresented: Binding(get: { error.wrappedValue != nil },
                                   set: { if !$0 { error.wrappedValue = nil } })) {
            Button(mbLoc("OK"), role: .cancel) { error.wrappedValue = nil }
        }
    }
}
