//
//  GLCard.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI

/// The single source of truth for the app's card/row surface: a rounded, gold-tinted fill.
/// Use `.glCardBackground()` on list rows (which manage their own padding), and `GLCard` for
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
        content.background(
            RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius)
                .fill(GLColor.gold.render(in: colorScheme).opacity(GLLayout.cardFillOpacity))
        )
    }
}

private struct GLSelectionStroke: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: GLLayout.cardCornerRadius)
                .stroke(GLColor.gold.render(in: colorScheme),
                        lineWidth: isSelected ? GLLayout.selectionStrokeWidth : 0)
        )
    }
}

/// A padded content card used on detail screens. Pass `title` for a headline above the content.
struct GLCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
    }
}
