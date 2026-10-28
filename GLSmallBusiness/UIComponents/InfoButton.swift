//
//  InfoButton.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A small gold ⓘ that explains the thing next to it. Tapping shows the explanation in a small sheet
//  sized to its text; the grabber or a tap outside dismisses it. Replaces the standalone explanatory
//  footers/captions app-wide so the chrome stays clean and the help is one tap away. Short inline
//  placeholder hints stay inline — this is for the longer "what is this" explanations.
//
//  Why a sheet and not a popover: most ⓘ live on section headers INSIDE another presentation (the
//  Menu / Settings card). A popover nested in a sheet gets height-constrained by that sheet and clips
//  long text — on iPhone AND iPad. A sheet always has room and full padding. A `.height` detent sized
//  to the measured text hugs the content on both platforms, so it never looks empty or cut off.
//

import SwiftUI
import GoldLifeUI

struct InfoButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: LocalizedStringKey

    /// What this ⓘ explains — "Backup", "Appearance". VoiceOver reads "About Backup".
    ///
    /// WHY it exists: the label used to be a hardcoded "What is this?" on every ⓘ, so the
    /// VoiceOver rotor listed eight identical entries on Settings alone (six on Document
    /// Messages) and a blind user had no way to tell which one explained what. Optional
    /// with a nil default so an ⓘ that somehow misses a topic still announces the old
    /// string rather than going unlabeled — an unlabeled button is worse than a vague one.
    let topic: String.LocalizationValue?

    init(text: LocalizedStringKey, topic: String.LocalizationValue? = nil) {
        self.text = text
        self.topic = topic
    }

    /// Built with `mbLoc`, not `String(localized:)`, so it follows the IN-APP language
    /// choice; reading it in `body` also registers Observation, so the label re-localizes
    /// live when the picker changes (same rule as every other code-built string here).
    private var voiceOverLabel: String {
        guard let topic else { return mbLoc("What is this?") }
        return mbLoc("About \(mbLoc(topic))")
    }

    var body: some View {
        // The chrome and behavior live in the package merge (GLInfoButton:
        // 44pt target, AX overflow scrolling, token background); this wrapper
        // only resolves the localized VoiceOver label.
        GLInfoButton(text: text, voiceOverLabel: voiceOverLabel)
    }
}

/// A section header (or any label) with a trailing ⓘ that explains it. Use in place of a `Section`
/// `header:` whose `footer:` was a standalone explanation.
struct InfoLabel: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey
    /// Passed straight to the ⓘ — see `InfoButton.topic`. Kept a separate argument rather
    /// than derived from `title` because a `LocalizedStringKey` cannot be read back out to
    /// build another key; the call sites repeat the words on purpose.
    let topic: String.LocalizationValue?

    init(_ title: LocalizedStringKey, info: LocalizedStringKey, topic: String.LocalizationValue? = nil) {
        self.title = title
        self.info = info
        self.topic = topic
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(text: info, topic: topic)
        }
    }
}
