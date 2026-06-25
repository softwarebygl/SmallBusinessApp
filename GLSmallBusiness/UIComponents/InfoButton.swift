//
//  InfoButton.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A small gold ⓘ that explains the thing next to it. Tapping shows the explanation in a small sheet
//  sized to its text; the grabber or a tap outside dismisses it. Replaces the standalone explanatory
//  footers/captions app-wide so the chrome stays clean and the help is one tap away. Short inline
//  placeholder hints stay inline — this is for the longer "what is this" explanations.
//
//  Why a sheet and not a popover: most ⓘ live on section headers INSIDE another presentation (the
//  Menu / Settings card). A popover nested in a sheet gets height-constrained by that sheet and clips
//  long text — on iPhone AND iPad. A sheet always has room and full padding. A `.height` detent sized
//  to the measured text hugs the content on both platforms, so it never looks empty or cut off.
//

import SwiftUI

struct InfoButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: LocalizedStringKey
    @State private var showing = false
    @State private var tipHeight: CGFloat = 132   // sensible start; corrected to the real text height

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
        .sheet(isPresented: $showing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)   // take full text height, never truncate
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .background {
                    // Measure the text's natural height and size the sheet's detent to it.
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { tipHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, newHeight in tipHeight = newHeight }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .presentationDetents([.height(max(tipHeight, 56))])
                .presentationDragIndicator(.visible)
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
