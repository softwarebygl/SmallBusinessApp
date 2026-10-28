//
//  PrivacyShieldPolicyTests.swift — law 38, pinned in source.
//
//  The app-switcher cover shipped broken in 3.0.0 (61) and stayed broken through
//  a day of fixes, because the failure is invisible to every ordinary test: the
//  code ran, the preference was ON, the window was created — and iOS had already
//  taken the picture. The only ground truth is the snapshot iOS writes to
//  <container>/Library/SplashBoard/Snapshots, which no unit test can reach.
//
//  So this suite pins the STRUCTURE the fix depends on, which is the part a
//  future edit would quietly undo:
//    1. the cover is registered with UIKit's own background notification, and
//    2. nothing raises it from a SwiftUI scenePhase handler again.
//
//  Re-verify the behaviour by hand after touching any of it: background the app
//  with a sheet open and read the newest .ktx out of SplashBoard/Snapshots. Both
//  states matter — ON must cover, OFF must not.
//
//  The walk is the shared scanner (Harness/SourceScan.swift).
//

import Testing
import Foundation
@testable import GLSmallBusiness

struct PrivacyShieldPolicyTests {

    /// The registration exists. Without it there is no cover at all — and the
    /// app looks completely normal while the switcher stores a Tax ID.
    @Test func theCoverIsRegisteredWithUIKitAtLaunch() {
        let found = GLSource.files().contains { $0.text.contains("GLPrivacyShield.installAutoCover(") }
        #expect(found, """
            Nothing calls GLPrivacyShield.installAutoCover. The app-switcher cover \
            is not registered, so backgrounding the app snapshots whatever is on \
            screen. See GoldLifeUI/REQUIREMENTS.md law 38.
            """)
    }

    /// The regression this suite exists for: raising the cover from a scenePhase
    /// change is TOO LATE, and it is the natural thing for the next person to
    /// write because it reads correctly and the app still compiles.
    @Test func nothingRaisesTheCoverFromASwiftUIScenePhaseHandler() {
        var offenders: [String] = []
        for file in GLSource.files() {
            guard file.text.contains("scenePhase") else { continue }
            // A raise is setShown(true, …). hideNow() on becoming active is fine
            // and deliberately not matched: dropping the cover late is harmless.
            for line in file.text.split(separator: "\n") where line.contains("GLPrivacyShield.setShown(true") {
                offenders.append("\((file.path as NSString).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, """
            The app-switcher cover is being raised from a file that observes \
            scenePhase. SwiftUI's .onChange can run after the scene delegate has \
            returned — which is after iOS has taken the snapshot — so the cover \
            never makes the picture. Register it with UIKit's \
            didEnterBackground notification instead (GLPrivacyShield.installAutoCover). \
            See GoldLifeUI/REQUIREMENTS.md law 38.
            Offenders: \(offenders.joined(separator: " | "))
            """)
    }

    /// The cover must stay a window above `.alert`, never a root overlay: a
    /// `.sheet` presents in a context a root overlay sits UNDER, which is what
    /// put the Settings sheet in the 3.0.0 (61) snapshot in full.
    @Test func thereIsNoSecondSwiftUIOverlayCover() {
        let offenders = GLSource.files()
            .filter { $0.text.contains("struct PrivacyScreen") }
            .map { ($0.path as NSString).lastPathComponent }
        #expect(offenders.isEmpty, """
            A SwiftUI PrivacyScreen overlay is back. It sits UNDER presented \
            sheets, so it cannot cover a detail sheet in the switcher snapshot, \
            and a second cover implementation is how one of them ends up never \
            coming down. GLPrivacyShield is the one cover. Offenders: \(offenders)
            """)
    }
}
