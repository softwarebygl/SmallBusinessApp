//
//  GLHubRow.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  The card-style navigation row used on every hub (the "More Info" row, etc.): a gold leading icon,
//  a title, and a chevron, on a `.glCardBackground()`. Extracted so all hubs share one definition
//  instead of each reimplementing the same HStack — keeps them pixel-identical.
//

import SwiftUI
import GoldLifeUI

struct GLHubRow<Destination: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    var systemImage: String = "list.bullet.rectangle"
    @ViewBuilder var destination: () -> Destination

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(gold)
                    .accessibilityHidden(true)   // decoration: the title names the row
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(GLLayout.rowContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
        }
        .buttonStyle(.plain)
    }
}
