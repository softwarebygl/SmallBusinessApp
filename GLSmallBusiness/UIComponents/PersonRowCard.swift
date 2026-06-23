//
//  PersonRowCard.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The single list row shared by all three people lists — Customers, Employees, Subcontractors —
//  on iPhone AND iPad, so they're indistinguishable. A 60-pt avatar overlaid on the leading edge of
//  a gold card (a photo for customers, a monogram for employees/subs), the name + optional subtitle,
//  an optional trailing value, and a chevron. `selectionMark` powers the customers' multi-select mode.
//

import SwiftUI

/// A gold initials monogram in a circle — the same look as `CustomerAvatar`'s placeholder, for
/// records that don't carry a photo (employees, subcontractors).
struct MonogramAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    let initials: String
    var size: CGFloat = 60

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ZStack {
            GLColor.backgroundPrimary.render(in: colorScheme)
            gold.opacity(0.2)
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(gold)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(gold.opacity(0.4), lineWidth: size * 0.02))
    }
}

struct PersonRowCard<Avatar: View>: View {
    let name: String
    var subtitle: String = ""
    var trailing: String = ""
    var trailingTint: Color? = nil
    var showsChevron: Bool = true
    var isSelected: Bool = false
    /// nil = no multi-select; true/false draws a filled/empty leading checkmark (customers' Edit mode).
    var selectionMark: Bool? = nil
    @ViewBuilder var avatar: Avatar

    @Environment(\.colorScheme) private var colorScheme
    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        HStack(spacing: 12) {
            if let selectionMark {
                Image(systemName: selectionMark ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionMark ? gold : Color.secondary)
            }
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(1).truncationMode(.tail)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if !trailing.isEmpty {
                        Text(trailing).font(.subheadline.weight(.medium)).foregroundStyle(trailingTint ?? .primary)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, GLLayout.rowContentVerticalPadding)
                .padding(.leading, 74)
                .padding(.trailing, GLLayout.rowContentPadding)
                .frame(maxWidth: .infinity)
                .glCardBackground()
                .glSelectionStroke(isSelected)

                avatar.padding(.leading, 6)
            }
        }
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }
}
