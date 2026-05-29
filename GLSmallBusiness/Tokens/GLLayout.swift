//
//  GLLayout.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// Shared layout constants so every list row in the app uses the same spacing.
enum GLLayout {
    /// Horizontal space between a row card's edge and the content inside it.
    static let rowContentPadding: CGFloat = 16

    /// Vertical space between a row card's edge and the content inside it.
    static let rowContentVerticalPadding: CGFloat = 12

    /// Inset of a row card from the screen's leading/trailing edges.
    static let rowCardInset: CGFloat = 16

    /// Corner radius shared by every card and row surface.
    static let cardCornerRadius: CGFloat = 12

    /// Gold-tint opacity for every card and row surface.
    static let cardFillOpacity: Double = 0.12

    /// Width of the gold outline marking a selected row in an iPad master-detail sidebar.
    static let selectionStrokeWidth: CGFloat = 2
}
