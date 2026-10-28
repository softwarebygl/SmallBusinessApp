//
//  MBFeatureFlags.swift
//  GLSmallBusiness
//
//  Switches for features that are built but not shown yet.
//

import Foundation

enum MBFeatureFlags {
    /// The assistant (Beta) and its Pro + AI subscription. Off (owner, 2026-10-03): no Assistant
    /// tab or iPad section, no sparkles button on detail screens, no Pro + AI plans on any
    /// paywall, and no assistant items in What's New. Existing Pro + AI subscribers still open
    /// the app as Pro. Flip to true to bring all of it back.
    nonisolated static let assistantEnabled = true
}
