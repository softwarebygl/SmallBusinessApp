//
//  ReviewLinkBackfill.swift
//  GLSmallBusiness
//
//  One-time grandfathering for the receipt review-link toggle. Before
//  `includeReviewLinkOnReceipts` existed, a set reviews link ALWAYS closed every
//  payment receipt. The new toggle defaults OFF, so without this an existing user
//  who had set a reviews link would silently lose the receipt CTA on update. This
//  runs once on first launch of the build that introduced the toggle and turns it
//  ON for any profile that already has a reviews link — preserving their old
//  behavior. New users (no link) stay off; there is nothing to grandfather.
//
//  It runs BEFORE the user can touch the toggle, so it never overrides a choice.
//

import Foundation
import SwiftData

enum ReviewLinkBackfill {
    private static let didGrandfatherKey = "mb.didGrandfatherReceiptReviewLink_v1"

    @MainActor
    static func runIfNeeded(_ context: ModelContext) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didGrandfatherKey) {
            if backfill(context) { defaults.set(true, forKey: didGrandfatherKey) }
        }
    }

    /// Turns receipt inclusion ON for any profile that already has a reviews link.
    /// Returns true when a profile existed (so the run-once flag can be set).
    @MainActor
    @discardableResult
    static func backfill(_ context: ModelContext) -> Bool {
        guard let profiles = try? context.fetch(FetchDescriptor<BusinessProfile>()),
              !profiles.isEmpty else { return false }
        var changed = false
        for p in profiles where !p.reviewsURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !p.includeReviewLinkOnReceipts {
            p.includeReviewLinkOnReceipts = true
            changed = true
        }
        if changed { context.saveChanges() }
        return true
    }
}
