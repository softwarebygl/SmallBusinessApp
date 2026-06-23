//
//  RecordSearch.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Free-text search predicates for the record lists ("View All" hours / paychecks / sub-activity).
//  Kept together and pure so they're easy to find and unit-test. An empty query matches everything,
//  so callers can pass the raw search text straight through.
//

import Foundation

extension SubPayment {
    /// Matches the query against the entry's detail, the tagged customer, the method, and the amount.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [detail, customer?.listDisplayName ?? "", method.label, String(amount)]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension TimeEntry {
    /// Matches the query against the tagged customer, the note, and the hours.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [customer?.listDisplayName ?? "", note, String(hours)]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension Paycheck {
    /// Matches the query against the method, the note, and the gross amount.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [method.label, note, String(grossAmount)]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - People directories (name / business / email / phone)

extension Customer {
    /// Matches the query against the customer's name, business, email, and phone.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [firstName, lastName, businessName ?? "", email, phoneNumber]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension Employee {
    /// Matches the query against the employee's name, email, and phone.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [firstName, lastName, email, phone]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension Subcontractor {
    /// Matches the query against the subcontractor's name, business, email, and phone.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [firstName, lastName, businessName, email, phone]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - Documents (job title / number / customer / status)

extension Estimate {
    /// Matches the query against the job title, estimate number, customer, and status.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [jobTitle, number, customerDisplayName, status.label]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension Invoice {
    /// Matches the query against the job title, invoice number, customer, and status.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [jobTitle, number, customerDisplayName, status.label]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension ChangeOrder {
    /// Matches the query against the title, change-order number, the parent invoice number, and status.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [title, number, invoice?.number ?? "", status.label]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}
