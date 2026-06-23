//
//  InfoButton.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A small gold ⓘ that explains the thing next to it. Tapping shows a popover with the explanation;
//  tapping anywhere else or scrolling dismisses it (standard popover behavior). Replaces the
//  standalone explanatory footers/captions app-wide so the chrome stays clean and the help is one
//  tap away. Short inline placeholder hints stay inline — this is for the longer "what is this"
//  explanations.
//

import SwiftUI

struct InfoButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: LocalizedStringKey
    @State private var showing = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(gold)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What is this?")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)   // a real popover on iPhone, not a sheet
        }
    }
}

/// A section header (or any label) with a trailing ⓘ that explains it. Use in place of a `Section`
/// `header:` whose `footer:` was a standalone explanation.
struct InfoLabel: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey

    init(_ title: LocalizedStringKey, info: LocalizedStringKey) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(text: info)
        }
    }
}
