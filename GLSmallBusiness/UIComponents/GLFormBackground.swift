//
//  GLFormBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI

extension View {
    /// The standard background for sheet forms and the Menu list: a plain cream fill with the
    /// default scroll background hidden, plus keyboard dismissal on scroll or tap-outside.
    /// (Detail/list screens in the main tabs use the branded monogram via
    /// `.containerBackground(.navigation) { PrimaryBackground() }` instead.)
    func glFormBackground() -> some View {
        modifier(GLFormBackground())
    }

    /// Dismisses the software keyboard when the user scrolls the form or taps outside a text field.
    /// Tap-to-dismiss is a non-cancelling window gesture (`KeyboardDismissInstaller`) rather than a
    /// SwiftUI `simultaneousGesture`, which interferes with menu Pickers (they'd need a long-press).
    func dismissesKeyboardOnInteraction() -> some View {
        scrollDismissesKeyboard(.immediately)
            .background {
                #if canImport(UIKit)
                KeyboardDismissInstaller().allowsHitTesting(false)
                #endif
            }
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
            .dismissesKeyboardOnInteraction()
    }
}
