//
//  GLColor.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI

enum GLColor: ShapeStyle {
    
    case gold
    case backgroundPrimary

    /// Returns the concrete `Color` value for this brand color in the given color scheme.
    ///
    /// Each case maps to a pair of hex values — one tuned for dark mode and one for light.
    /// Any color scheme other than `.dark` (including future modes) resolves to the light variant.
    ///
    /// - Parameter colorScheme: The color scheme to resolve against, typically read from
    ///   `@Environment(\.colorScheme)`.
    /// - Returns: The `Color` to use for this case in the supplied color scheme.
    func render(in colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        return switch self {
        case .gold: isDark ?
            Color(hex: "E8C87A") : Color(hex: "9C7A2E")
        case .backgroundPrimary:isDark ?
            Color(hex: "0B0B0D") : Color(hex: "F9F6EF")
        }
    }

    /// A legible foreground for glyphs/text drawn directly ON a gold fill. Light mode uses white on
    /// the darker light-gold; dark mode uses near-black on the pale dark-gold — keeping the contrast
    /// above the WCAG UI minimum in both (white-on-pale-gold would be ~1.6:1 and fail).
    static func onGold(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? GLColor.backgroundPrimary.render(in: .dark) : .white
    }
}
