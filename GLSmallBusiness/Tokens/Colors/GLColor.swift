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
}
