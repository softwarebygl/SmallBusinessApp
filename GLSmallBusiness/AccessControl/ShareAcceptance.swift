//
//  ShareAcceptance.swift
//  GLSmallBusiness
//
//  The participant side of CloudKit Sharing: when the SECOND Apple ID taps the invite link, iOS hands
//  the app a `CKShare.Metadata`. A pure-SwiftUI `App` has no delegate, so we install a minimal app +
//  scene delegate purely to receive that callback and forward it to the sync engine. SwiftUI keeps
//  driving the UI (we never touch window setup).
//
//  Kept tightly gated: the delegate adaptor is DEBUG-only (the sharing engine is too), and even in DEBUG
//  the custom scene delegate is attached only when the engine flag is on — so a normal Release build has
//  no app delegate at all and its scene lifecycle is byte-for-byte unchanged.
//

import SwiftUI
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

/// Device-local record of "this device accepted a share", so the SwiftData UI knows to read the shared
/// store (a pure participant has no private data of its own). Set once acceptance succeeds.
enum SharingState {
    private static let participantKey = "glIsShareParticipant"

    static var isParticipant: Bool { UserDefaults.standard.bool(forKey: participantKey) }
    static func markParticipant() { UserDefaults.standard.set(true, forKey: participantKey) }

    #if DEBUG
    /// Test/forget helper — clears the participant flag (e.g. to go back to owner mode on a test device).
    static func reset() { UserDefaults.standard.removeObject(forKey: participantKey) }
    #endif
}

#if canImport(UIKit)
final class ShareAppDelegate: NSObject, UIApplicationDelegate {
    #if DEBUG
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        // Only intercept scene events when sharing is on; otherwise this returns the default SwiftUI scene.
        if CloudKitSyncEngine.isEnabled {
            config.delegateClass = ShareSceneDelegate.self
        }
        return config
    }
    #endif
}

/// Receives the share-acceptance callback. A SwiftUI app is scene-based, so the callback arrives here
/// (not on the app delegate). We only implement the share hooks — SwiftUI still owns the window.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Warm launch: the app is already running when the invite is tapped.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        CloudKitSyncEngine.acceptShare(cloudKitShareMetadata)
    }

    /// Cold launch: the invite tap launched the app; the metadata rides in on the connection options.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudKitSyncEngine.acceptShare(metadata)
        }
    }
}
#endif
