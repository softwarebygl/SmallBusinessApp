//
//  GLFormBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI
import GoldLifeUI

extension View {
    /// The standard background for sheet forms and the Menu list: a plain cream fill with the
    /// default scroll background hidden, plus keyboard dismissal on scroll or tap-outside.
    /// (Detail/list screens in the main tabs use the branded monogram via
    /// `.containerBackground(.navigation) { PrimaryBackground() }` instead.)
    func glFormBackground() -> some View {
        modifier(GLFormBackground())
    }

    /// Dismisses the software keyboard when the user scrolls the form or taps outside a text field.
    /// Tap-to-dismiss is a non-cancelling window gesture (`GLKeyboardDismissInstaller`) rather than a
    /// SwiftUI `simultaneousGesture`, which interferes with menu Pickers (they'd need a long-press).
    func dismissesKeyboardOnInteraction() -> some View {
        scrollDismissesKeyboard(.immediately)
            .background {
                #if canImport(UIKit)
                GLKeyboardDismissInstaller().allowsHitTesting(false)
                #endif
            }
    }
}

private struct GLFormBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Decision D6: data-entry screens KEEP Form (Apple's own control for typing)
            // and take the shared system's SKIN. The skin itself moved into GoldLifeUI
            // (glGroupedFormSkin — owner ruling 2026-08-22, both apps' menus draw from
            // one visual source); what stays app-side is the BEHAVIOR: keyboard
            // dismissal on scroll or tap-outside.
            // The system-banner stack rides with the skin so it reaches every form and the Menu
            // in one place — and so a form added tomorrow inherits it rather than being
            // remembered. It renders nothing unless a notice applies (sample data, offline, or
            // lapsed — MBSystemBanners owns the order and suppressions).
            // FIRST, on the bare Form, because that is GoldLifeUI's stated contract — "attach it to
            // the screen's ScrollView/List". (Tried both ways on device: the pixels are identical,
            // so this is the documented order rather than a fix for anything.)
            .mbSystemBanners()
            .glGroupedFormSkin()
            .dismissesKeyboardOnInteraction()
    }
}
