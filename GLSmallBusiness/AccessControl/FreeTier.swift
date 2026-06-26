//
//  FreeTier.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The free-tier ceilings. Everyone uses My Business free up to these counts of each record type;
//  creating one more opens the paywall (PaywallSheet). A subscription lifts every cap.
//
//  Only *creating new* records past the cap is ever blocked — viewing, editing, exporting, and
//  deleting existing records is always free. Because the rule is "subscribed OR under cap"
//  (see AccessGate), a lapsed subscriber keeps full read/edit access to everything they already
//  created and is simply stopped from adding more, so no separate read-only mode is needed.
//
//  Counts are global (across all customers), so a cap measures total usage of the app, not usage
//  per customer. Tune these numbers freely — they are the single knob for how generous the free
//  tier feels.
//

enum FreeTier {
    static let customers      = 10
    static let employees      = 2
    static let subcontractors = 2
    static let estimates      = 15
    static let invoices       = 15
    static let jobs           = 15
    static let receipts       = 15
}
