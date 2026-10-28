//
//  RecordSearch.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Free-text search predicates for every record list, the line-item name autocomplete and the
//  assistant's `find`. Kept together and pure so they're easy to find and unit-test. All of them
//  go through `RecordSearch.matches`, which is the FLEET's one matcher (GoldLifeUI's
//  `GLSearchMatch`): every word of the query has to
//  appear in some field of the record, so "John Smith" finds John Smith even though first and
//  last names are separate fields. An empty query matches everything, so callers can pass the
//  raw search text straight through. This file owns only WHICH fields each record searches.
//

import Foundation
import GoldLifeUI
import GoldLifeDocuments

/// The app's door to the fleet's one free-text matcher — the lists' in-list search, the Jobs,
/// Receipts and Price Sheet searches, the line-item autocomplete and the assistant's `find` all
/// answer through it, so they can't drift apart (nor from the other Gold Life apps).
nonisolated enum RecordSearch {
    /// True when EVERY word of `query` appears in at least one of `fields` — case- and
    /// accent-insensitive (José = jose), in any order ("smith john"); a word never spans two
    /// fields. Words are split on whitespace; a blank query matches everything.
    /// (`GLSearchMatch.matches` — the rules live, and are tested, in GoldLifeUI.)
    static func matches(_ query: String, in fields: [String]) -> Bool {
        GLSearchMatch.matches(query: query, fields: fields)
    }
}

/// The type-ahead under group and line name fields is provided by GLDocNameSuggestions in GoldLifeDocuments.
public typealias LineItemNameSuggestions = GoldLifeDocuments.GLDocNameSuggestions

extension SubPayment {
    /// Matches the query against the entry's detail, the tagged customer, the method, and the amount.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [detail, customer?.listDisplayName ?? "", method.label, String(amount)])
    }
}

extension TimeEntry {
    /// Matches the query against the tagged customer, the note, and the hours.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [customer?.listDisplayName ?? "", note, String(hours)])
    }
}

extension Paycheck {
    /// Matches the query against the method, the note, and the gross amount.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [method.label, note, String(grossAmount)])
    }
}

// MARK: - People directories (name / business / email / phone)

extension Customer {
    /// What the Customers list searches: name, business, email, and phone.
    @MainActor
    var searchFields: [String] { [firstName, lastName, businessName ?? "", email, phoneNumber] }

    /// Matches the query against the customer's name, business, email, and phone.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: searchFields)
    }
}

extension Employee {
    /// Matches the query against the employee's name, email, and phone.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [firstName, lastName, email, phone])
    }
}

extension Subcontractor {
    /// Matches the query against the subcontractor's name, business, email, and phone.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [firstName, lastName, businessName, email, phone])
    }
}

// MARK: - Documents (job title / number / customer / status)

extension Estimate {
    /// Matches the query against the job title, estimate number, customer, and status.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [jobTitle, number, customerDisplayName, status.label])
    }
}

extension Invoice {
    /// Matches the query against the job title, invoice number, customer, and status.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [jobTitle, number, customerDisplayName, status.label])
    }
}

extension ChangeOrder {
    /// Matches the query against the title, change-order number, parent invoice/contract number, customer, and status.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [title, number, invoice?.number ?? contract?.number ?? "", customerDisplayName, status.label])
    }
}

// MARK: - Jobs, receipts, price sheet

extension ScheduledJob {
    /// The Jobs screen's search: the job's title and the customer's name.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [displayTitle, customerName])
    }
}

extension Receipt {
    /// The Receipts screen's search: vendor, category, notes, and the tagged customer.
    /// `untaggedLabel` stands in for the customer on a receipt that has none (the list passes the
    /// word it has always matched there; the assistant passes nothing).
    @MainActor
    func matchesSearch(_ query: String, untaggedLabel: String = "") -> Bool {
        RecordSearch.matches(query, in: [vendor, category, notes, customer?.listDisplayName ?? untaggedLabel])
    }
}

extension PriceSheetItem {
    /// The Price Sheet's search: name, category, and details.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [name, category, details])
    }
}

extension Contract {
    /// The Contracts screen's search: title, number, customer, email, phone, and status.
    @MainActor
    func matchesSearch(_ query: String) -> Bool {
        RecordSearch.matches(query, in: [title, number, customerName, customerEmail, customerPhone, status.label])
    }
}

