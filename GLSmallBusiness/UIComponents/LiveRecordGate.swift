//
//  LiveRecordGate.swift
//  GLSmallBusiness
//
//  THE deleted-parent fence for a screen that holds a customer, employee or subcontractor.
//
//  A person can be deleted while one of their screens is open: on iPad from the middle column
//  (the pushed screen stays in the detail column), or on any device by a synced delete from
//  another device. Reading a deleted @Model traps uncatchably (Models/LiveRows.swift), and a
//  screen that survives the delete keeps offering Save, +, Share and Generate for someone who
//  no longer exists (F24, 2026-10-03 QA). Every such screen draws through this gate: while the
//  person still exists it draws the screen; once they are gone it draws DeletedRecordView with
//  the screen's own title and a way back.
//
//  The rule is the one the detail screens already used (CustomerDetailScreen's `stillExists`):
//  the person is live while the store still lists them — an @Query, so the gate re-renders the
//  moment a delete is saved — plus the two checks that read nothing but identity and context
//  (`isDeleted` for a delete not yet saved, `isSavedDelete` for one that is), both safe on a
//  dead record (DeletedRowFenceTests). It is a BRANCH, not an overlay (CRUD audit 2026-09-02):
//  an overlay still evaluates the screen against the deleted record.
//
//  Only the record's identity is read before the gate decides, so a caller's `title` must
//  never read the record either (a constant, or `existing == nil`-style checks only).
//

import SwiftUI
import SwiftData

/// A record a screen can be opened for and then lose while it is open.
@MainActor
protocol LiveGatedRecord: PersistentModel {
    /// What DeletedRecordView calls it, with its article, as a catalog key ("this customer" →
    /// "This customer was removed" / "Se eliminó este cliente").
    static var removedNoun: String.LocalizationValue { get }
}

extension Customer: LiveGatedRecord {
    static var removedNoun: String.LocalizationValue { "this customer" }
}

extension Employee: LiveGatedRecord {
    static var removedNoun: String.LocalizationValue { "this employee" }
}

extension Subcontractor: LiveGatedRecord {
    static var removedNoun: String.LocalizationValue { "this subcontractor" }
}

struct LiveRecordGate<Record: LiveGatedRecord, Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    /// Every stored record of this type: the gate re-renders when a delete is saved.
    @Query private var stored: [Record]
    private let record: Record
    private let title: String.LocalizationValue
    private let content: () -> Content

    /// - Parameters:
    ///   - title: the screen's own title, shown on the removed state too (law 57: a pushed
    ///     screen is never untitled). It must not read `record`.
    ///   - content: the screen, built only while `record` still exists.
    init(_ record: Record, title: String.LocalizationValue, @ViewBuilder content: @escaping () -> Content) {
        self.record = record
        self.title = title
        self.content = content
        _stored = Query()
    }

    var body: some View {
        if Self.isLive(record, among: stored) {
            content()
        } else {
            DeletedRecordView(title: mbLoc(title), noun: Record.removedNoun) { dismiss() }
        }
    }

    /// True while `record` is neither deleted nor missing from the store's own list. Reads only
    /// the record's identity and context, so it is safe on a deleted record.
    static func isLive(_ record: Record, among stored: [Record]) -> Bool {
        if record.isSavedDelete || record.isDeleted { return false }
        let id = record.persistentModelID
        return stored.contains { $0.persistentModelID == id }
    }
}

// MARK: - Destinations whose screens live in other files

extension CustomerFormScreen {
    /// The Edit form for a customer, behind the gate: it closes into "This customer was removed"
    /// instead of keeping Save live for someone who was deleted.
    static func editingLive(_ customer: Customer) -> some View {
        LiveRecordGate(customer, title: "Edit Customer") { CustomerFormScreen(editing: customer) }
    }
}

extension EmployeeFormScreen {
    /// The Edit form for an employee, behind the gate.
    static func editingLive(_ employee: Employee) -> some View {
        LiveRecordGate(employee, title: "Edit Employee") { EmployeeFormScreen(editing: employee) }
    }
}

extension SubcontractorFormScreen {
    /// The Edit form for a subcontractor, behind the gate.
    static func editingLive(_ subcontractor: Subcontractor) -> some View {
        LiveRecordGate(subcontractor, title: "Edit Subcontractor") { SubcontractorFormScreen(editing: subcontractor) }
    }
}

extension AllChangeOrdersScreen {
    /// A customer's change orders, behind the gate, like their other record lists.
    static func forLiveCustomer(_ customer: Customer) -> some View {
        LiveRecordGate(customer, title: "All Change Orders") { AllChangeOrdersScreen(customer: customer) }
    }
}
