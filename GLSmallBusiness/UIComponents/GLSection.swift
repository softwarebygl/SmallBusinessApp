//
//  GLSection.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  A labeled group of action rows on the card-based hub screens — the same "section title above a
//  group of rows" idea the Menu gets for free from List `Section(...)`. Use GLSection to wrap a
//  group of `.glCardBackground()` rows under a gray header so every hub reads as clearly-titled
//  sections instead of one flat stack of cards. (Data cards keep using `MBTitledCard(title:)`.)
//

import SwiftUI
import GoldLifeUI

/// A gray section header that matches the Menu's `Section` headers, aligned with the row content.
struct GLSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(GLTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, GLLayout.rowContentPadding)   // aligns with the row icons inside the cards
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section header followed by its group of rows. Drop `.glCardBackground()` action rows inside.
struct GLSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GLSectionHeader(title: title)
            VStack(spacing: 12) { content }
        }
    }
}
