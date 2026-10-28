//
//  FreeTier.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  The free-tier ceilings. Everyone uses My Business free up to these counts of each record type;
//  creating one more opens the paywall (PaywallSheet). A subscription lifts every cap.
//
//  These caps bind NEVER-SUBSCRIBED users only. A LAPSED subscriber is a different state
//  entirely (owner ruling 2026-08-25): 100% read-only — nothing added, changed or exported —
//  which AccessGate checks FIRST, before any count, so the two rules can never blur. Under the
//  caps, viewing/editing/exporting existing records is always free; only creating past the cap
//  opens the paywall.
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
