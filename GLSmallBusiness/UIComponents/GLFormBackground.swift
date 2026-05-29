//
//  GLFormBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI

extension View {
    /// The standard background for sheet forms and the Menu list: a plain cream fill with the
    /// default scroll background hidden. (Detail/list screens in the main tabs use the branded
    /// monogram via `.containerBackground(.navigation) { PrimaryBackground() }` instead.)
    func glFormBackground() -> some View {
        modifier(GLFormBackground())
    }
}

private struct GLFormBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
            }
    }
}
