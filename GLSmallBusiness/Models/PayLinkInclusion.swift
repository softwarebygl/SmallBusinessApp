//
//  PayLinkInclusion.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/30/26.
//

import Foundation

// MARK: - Stripe payment-link enums
//
// `nonisolated` so their Codable conformances aren't main-actor isolated (matches the model-enum
// pattern in Invoice.swift). Stored as raw strings on the synced models, read via typed accessors.

/// Which invoices get a Stripe "Pay this invoice" link injected at send time. Set per business in
/// Settings; only meaningful once a Stripe account is connected.
nonisolated enum PayLinkInclusion: String, Codable, CaseIterable, Identifiable {
    /// Every invoice sent gets a pay link.
    case all
    /// Only invoices the user explicitly toggles on (per-invoice `Invoice.includePayLink`).
    case customSelect
    /// Never include a pay link.
    case none

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .all: mbLoc("All invoices")
        case .customSelect: mbLoc("Choose per invoice")
        case .none: mbLoc("Off")
        }
    }

    /// One-line explanation shown under the Settings picker.
    @MainActor
    var detail: String {
        switch self {
        case .all: mbLoc("Add a Pay button to every invoice you send.")
        case .customSelect: mbLoc("Turn the Pay button on for each invoice yourself.")
        case .none: mbLoc("Don't add a Pay button to invoices.")
        }
    }
}

/// Backend-reported status of an invoice's Stripe payment link. A display/reconciliation hint only —
/// recorded `InvoicePayment`s remain the money source of truth.
nonisolated enum StripePayLinkStatus: String, Codable, CaseIterable, Identifiable {
    /// No link minted yet, or status not yet known.
    case none
    /// Link minted; not yet reported paid.
    case open
    /// Stripe reported the link paid.
    case paid

    var id: String { rawValue }
}
