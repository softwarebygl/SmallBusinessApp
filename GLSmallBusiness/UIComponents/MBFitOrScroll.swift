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
import GoldLifeUI

extension View {
    /// Fill the screen and pin to `alignment` when the content fits; scroll when
    /// it doesn't. Delegates to the canonical `GoldLifeUI.glFitOrScroll`.
    func mbFitOrScroll(alignment: Alignment = .center) -> some View {
        glFitOrScroll(alignment: alignment)
    }
}
