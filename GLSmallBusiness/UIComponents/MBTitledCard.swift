//
//  MBTitledCard.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI
import GoldLifeUI

/// The single source of truth for the app's card/row surface: a rounded, gold-tinted fill.
/// Use `.glCardBackground()` on list rows (which manage their own padding), and `MBTitledCard` for
/// the padded content cards on detail screens.
extension View {
    func glCardBackground() -> some View {
        modifier(GLCardBackground())
    }

    /// The gold outline marking a selected list row in an iPad master-detail sidebar. Pairs with
    /// `.glCardBackground()` so a row's fill and its selected state share one definition.
    func glSelectionStroke(_ isSelected: Bool) -> some View {
        modifier(GLSelectionStroke(isSelected: isSelected))
    }
}

private struct GLCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // Decision D1: hierarchy is SHADE, not hue — the card is a neutral tonal step
        // (white over the ground), matching the #141416-on-black ramp, and gold
        // is reserved as THE accent. Decision D4: it stays TRANSLUCENT rather than an
        // opaque surface so the white-label company watermark still reads through it.
        content.background(
            RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius, style: .continuous)
                .fill(GLTheme.cardFill)
        )
    }
}

private struct GLSelectionStroke: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius, style: .continuous)
                .stroke(GLTheme.accentFill,
                        lineWidth: isSelected ? GLLayout.selectionStrokeWidth : 0)
        )
    }
}

/// A padded content card used on detail screens. Pass `title` for a headline above the content.
struct MBTitledCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }
}
