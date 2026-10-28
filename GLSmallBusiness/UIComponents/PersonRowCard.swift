//
//  PersonRowCard.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The single list row shared by all three people lists — Customers, Employees, Subcontractors —
//  on iPhone AND iPad, so they're indistinguishable. The avatar (a saved photo, or a gold monogram)
//  sits inline at the leading edge of the card, then the name + optional subtitle, an optional
//  trailing value, and a chevron. `selectionMark` powers the customers' multi-select mode.
//

import SwiftUI
import GoldLifeUI

/// A circular profile avatar: the saved photo when present, otherwise a gold initials monogram —
/// the one avatar used by every people row and hub (customers, employees, subcontractors), so they
/// look identical. The camera badge appears only where the avatar is tappable to set a photo.
struct ProfileAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    var imageData: Data? = nil
    let initials: String
    var size: CGFloat = 48
    var showsCameraBadge: Bool = false

    /// The photo, decoded small and off the main thread (never a full-size `UIImage(data:)` per
    /// row while scrolling — law 62).
    @State private var decoded: Decoded?

    private var gold: Color { GLTheme.accentFill }

    /// A decoded avatar and the bytes it came from, so a changed photo never shows the old one.
    struct Decoded {
        let source: Data
        let image: UIImage
    }

    /// The pixel size an avatar of `size` points is decoded at: crisp on a 3x screen, no bigger.
    nonisolated static func pixelSide(for size: CGFloat) -> CGFloat { (size * 3).rounded(.up) }

    /// `data` decoded as a thumbnail no larger than `pixelSide(for: size)`, upright, off the main
    /// thread (ImageIO thumbnailing: a large stored photo is never fully decoded).
    nonisolated static func thumbnail(from data: Data, size: CGFloat) async -> UIImage? {
        let side = pixelSide(for: size)
        return await Task.detached(priority: .utility) {
            ImageDownsampler.thumbnail(from: data, maxPixelSize: side)
        }.value
    }

    private var shownImage: UIImage? {
        guard let imageData else { return nil }
        guard let decoded, decoded.source == imageData else { return nil }
        return decoded.image
    }

    var body: some View {
        let uiImage = shownImage
        // The monogram (empty) state uses a ring half as thick as the photo state.
        let strokeWidth = size * (uiImage == nil ? 0.01 : 0.02)
        return ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                GLTheme.background
                gold.opacity(0.2)
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(gold)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(gold.opacity(0.4), lineWidth: strokeWidth))
        .overlay(alignment: .bottomTrailing) {
            if showsCameraBadge {
                Image(systemName: "camera.fill")
                    .font(.system(size: size * 0.12))
                    .foregroundStyle(GLTheme.onAccent)
                    .padding(size * 0.07)
                    .background(Circle().fill(gold))
            }
        }
        // What VoiceOver hears (audit 2026-10-03 F55). Where the avatar is the photo
        // picker (the camera badge), it names the action — "Add photo" / "Change photo",
        // never the monogram's letters. Everywhere else it sits beside the person's name,
        // so it is decoration and stays silent.
        .modifier(AvatarAccessibility(isPhotoPicker: showsCameraBadge, hasPhoto: imageData != nil))
        // Decoded off the main thread, like ScanThumbnail; the monogram shows until it lands.
        .task(id: imageData) {
            guard let imageData else { decoded = nil; return }
            guard let image = await Self.thumbnail(from: imageData, size: size), !Task.isCancelled else { return }
            decoded = Decoded(source: imageData, image: image)
        }
    }
}

/// `ProfileAvatar`'s VoiceOver treatment: the photo picker's name, or silence.
private struct AvatarAccessibility: ViewModifier {
    let isPhotoPicker: Bool
    let hasPhoto: Bool

    func body(content: Content) -> some View {
        if isPhotoPicker {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hasPhoto ? Text("Change photo") : Text("Add photo"))
        } else {
            content.accessibilityHidden(true)
        }
    }
}

struct PersonRowCard<Avatar: View>: View {
    let name: String
    var subtitle: String = ""
    var subtitleColor: Color = GLTheme.textSecondary
    /// An optional custom subtitle view (e.g. the customers' two-value owed/paid subrow). Overrides `subtitle`.
    var subtitleView: AnyView? = nil
    var trailing: String = ""
    var trailingTint: Color? = nil
    var showsChevron: Bool = true
    var isSelected: Bool = false
    /// nil = no multi-select; true/false draws a filled/empty leading checkmark (customers' Edit mode).
    var selectionMark: Bool? = nil
    @ViewBuilder var avatar: Avatar

    @Environment(\.colorScheme) private var colorScheme
    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        HStack(spacing: 12) {
            if let selectionMark {
                // The mark is drawn; the state is spoken through the Selected trait below.
                Image(systemName: selectionMark ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionMark ? gold : GLTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1).truncationMode(.tail)
                    if let subtitleView {
                        subtitleView
                    } else if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(subtitleColor).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).font(.subheadline.weight(.medium)).foregroundStyle(trailingTint ?? GLTheme.textPrimary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.glCaption.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, GLLayout.rowContentVerticalPadding)
            .padding(.leading, 8)
            .padding(.trailing, GLLayout.rowContentPadding)
            .frame(maxWidth: .infinity)
            .glCardBackground()
            .glSelectionStroke(isSelected)
        }
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        // A ticked multi-select mark, or the iPad's open row, is read as "Selected".
        .accessibilityAddTraits(selectionMark == true || isSelected ? .isSelected : [])
    }
}
