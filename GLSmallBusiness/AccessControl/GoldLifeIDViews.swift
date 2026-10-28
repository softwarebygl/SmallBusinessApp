//
//  GoldLifeIDViews.swift — My Business's Gold Life ID glue. The Gold Life ID screens themselves
//  (card, Edit, Sign-in methods, deletion) are the GoldLifeID package's own (law 48a); the
//  eraser behind My Business's row on its deletion screen is `MBHostDataErase`
//  (GLSmallBusinessApp.swift).
//

import SwiftUI
import GoldLifeUI
@_exported import GoldLifeID
import Accessibility

// MARK: - Saying a change out loud

/// Speak a change VoiceOver has no other way to learn about. A no-op when VoiceOver is off.
func mbAnnounce(_ sentence: String) {
    AccessibilityNotification.Announcement(sentence).post()
}
