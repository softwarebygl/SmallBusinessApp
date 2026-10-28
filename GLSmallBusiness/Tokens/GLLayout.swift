//
//  GLLayout.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI
import GoldLifeUI

/// Shared layout constants so every list row in the app uses the same spacing.
enum GLLayout {
    /// Horizontal space between a row card's edge and the content inside it.
    /// Delegates to the shared token so a change in GoldLifeUI moves every app.
    static let rowContentPadding: CGFloat = GLTheme.cardPadding          // 18

    /// Vertical space between a row card's edge and the content inside it.
    static let rowContentVerticalPadding: CGFloat = 12

    /// Inset of a row card from the screen's leading/trailing edges. THE screen gutter:
    /// 8pt (moved 16 -> 8 on 2026-08-16). Never hardcode a
    /// horizontal inset - take this, so the whole app moves together.
    static let rowCardInset: CGFloat = GLTheme.gutter                    // 8

    /// Corner radius shared by every card and row surface, drawn `.continuous`.
    /// The shared card radius.
    static let cardCornerRadius: CGFloat = GLTheme.cornerRadius          // 22

    /// DEPRECATED as a gold tint. Cards are a NEUTRAL tonal step now (decision D1:
    /// hierarchy is shade, not hue; gold becomes THE accent only). Kept because the
    /// white-label watermark still shows through a translucent card (decision D4) and
    /// this is the opacity that step uses.
    static let cardFillOpacity: Double = 0.08

    /// Width of the gold outline marking a selected row in an iPad master-detail sidebar.
    static let selectionStrokeWidth: CGFloat = 2
}
