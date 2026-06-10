//
//  KeyboardDismiss.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI
#if canImport(UIKit)
import UIKit

/// Subclass purely so the window-installed instance is identifiable (to avoid duplicates).
private final class KeyboardDismissTapRecognizer: UITapGestureRecognizer {}

/// App-lifetime owner of the window tap gesture, so the recognizer's target/delegate never
/// deallocate as form views come and go.
private final class KeyboardDismissController: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissController()

    func installIfNeeded(on window: UIWindow) {
        let alreadyInstalled = window.gestureRecognizers?.contains { $0 is KeyboardDismissTapRecognizer } ?? false
        guard !alreadyInstalled else { return }
        let tap = KeyboardDismissTapRecognizer(target: self, action: #selector(dismissKeyboard))
        // Critically: only *observe* the tap, never consume it — so buttons, pickers, toggles,
        // and links still receive their own taps normally.
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Only fire for taps that aren't on a control or text input — i.e. genuine "tap outside" —
    /// so the recognizer never competes with a field/Picker the user is actually tapping.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let candidate = view {
            if candidate is UIControl || candidate is UITextField || candidate is UITextView {
                return false
            }
            view = candidate.superview
        }
        return true
    }
}

/// A zero-size, non-interactive view that installs the keyboard-dismiss gesture on its window
/// when it appears. Drop it in a `.background` of any form.
struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { InstallerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class InstallerView: UIView {
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                KeyboardDismissController.shared.installIfNeeded(on: window)
            }
        }
    }
}
#endif
