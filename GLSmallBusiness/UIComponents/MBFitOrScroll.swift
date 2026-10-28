//
//  MBFitOrScroll.swift — a full-screen surface that looks pinned when it fits,
//  and scrolls the moment it can't (the 2026-08-09 accessibility fix), mb-prefixed — the gate
//  needed the same belt (hardening item 6): at accessibility text sizes the
//  pinned door stack grew past the screen with no way to reach the top doors.
//
//  The fix is the standard SwiftUI idiom: put the content in a ScrollView, but
//  give it a minimum height equal to the visible area and keep the alignment.
//  When the content is short, that minHeight fills the screen and it pins to the
//  edge exactly as before — indistinguishable from a plain frame. When the
//  content is tall, the content's own height wins, the ScrollView has something
//  to scroll, and nothing clips. `scrollBounceBehavior(.basedOnSize)` means it
//  doesn't rubber-band when everything already fits.
//

import SwiftUI

private struct MBFitOrScroll: ViewModifier {
    var alignment: Alignment

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                content
                    // minWidth/minHeight, not fixed: short content fills the
                    // screen and pins to `alignment` (both axes); tall content
                    // overflows and the ScrollView takes over.
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: alignment)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    /// Fill the screen and pin to `alignment` when the content fits; scroll when
    /// it doesn't. The preventative replacement for a bare
    /// `.frame(maxHeight: .infinity, alignment:)` on any surface whose content
    /// can grow at large Dynamic Type sizes.
    func mbFitOrScroll(alignment: Alignment = .center) -> some View {
        modifier(MBFitOrScroll(alignment: alignment))
    }
}
