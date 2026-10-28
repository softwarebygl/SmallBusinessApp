//
//  SharedComponentsMoveTests.swift
//
//  Audit 2026-10-03 F158 (Zero Duplication): the pieces shared across the fleet
//  now live ONCE in GoldLifeUI — the relock cover window and its bookkeeping, the
//  warm-relock decision and the app-wide warm lock, the system-banner stack and the sample-data
//  card, the keyboard tap-to-dismiss, the appearance store's core, the subscription status
//  sentences and the paywall's store-problem copy. My Business keeps only what is its own: its
//  keys, its state and its words. These scans read the app's CODE (comments stripped), so a
//  comment naming an old type does not count, and fail if a copy comes back.
//

import Testing
import Foundation

@Suite struct SharedComponentsMoveTests {

    /// Declarations of the moved copies, as `kind Name`.
    static let retiredDeclarations: [String] = [
        "enum MBLockWindow", "struct MBLockCoverLedger", "enum RelockPolicy", "class MBWarmLock",
        "struct MBSystemBannersModifier", "struct MBSampleDataBanner",
        "class KeyboardDismissController", "class KeyboardDismissTapRecognizer",
        "struct KeyboardDismissInstaller", "enum AppearancePref",
    ]

    /// Every `kind Name` in `retiredDeclarations` that `code` still declares.
    static func declarations(in code: String) -> [String] {
        retiredDeclarations.filter { declaration in
            let name = declaration.split(separator: " ").last.map(String.init) ?? declaration
            let kind = declaration.split(separator: " ").first.map(String.init) ?? ""
            let pattern = "\\b\(kind)\\s+\(name)\\b"
            return code.range(of: pattern, options: .regularExpression) != nil
        }
    }

    @Test func noMovedCopyIsDeclaredInTheApp() {
        var found: [String] = []
        for file in GLSource.codeFiles() {
            for declaration in Self.declarations(in: file.text) {
                found.append("\(file.path): \(declaration)")
            }
        }
        #expect(found.isEmpty, "a copy of a GoldLifeUI component is back in My Business: \(found)")
    }

    /// The old lock window's name is gone from the code entirely: every caller uses the package's.
    @Test func noCodeNamesTheOldLockWindow() {
        let callers = GLSource.codeFiles()
            .filter { $0.text.range(of: "\\bMBLockWindow\\b", options: .regularExpression) != nil }
            .map(\.path)
        #expect(callers.isEmpty, "still calling MBLockWindow: \(callers)")
    }

    /// The banner slot hands its state to the package stack and draws nothing of its own:
    /// no card, no padding, no order of its own.
    @Test func theBannerSlotUsesThePackageStack() throws {
        let code = try #require(GLSource.code("UIComponents/MBSystemBanners.swift"))
        #expect(code.contains("GLSystemBannerStack("))
        #expect(!code.contains("VStack"), "the stack's layout belongs to GLSystemBannerStack")
        #expect(!code.contains(".padding("), "the stack's chrome belongs to GLSystemBannerStack")
        #expect(!code.contains("GLOfflineBanner("), "the stack picks its own cards")
    }

    /// The subscription screen's renewal and price sentences, and the paywall's store-problem
    /// words, come from the package (one string, one truth, fleet-wide).
    @Test func subscriptionSentencesComeFromThePackage() throws {
        let screen = try #require(GLSource.code("Screens/SubscriptionScreen.swift"))
        #expect(screen.contains("GLSubscriptionStatusCopy."))
        #expect(!screen.contains("Transaction.currentEntitlements"),
                "the renewal facts are read by GLSubscriptionRenewalFacts")
        for sentence in ["Renews \\(", "Expires \\(", "Active through \\(", "per year", "per month"] {
            #expect(!screen.contains(sentence), "the screen spells out \(sentence) itself")
        }
        let paywall = try #require(GLSource.code("AccessControl/PaywallSheet.swift"))
        #expect(paywall.contains("GLStoreProblem"))
        #expect(!paywall.contains("Couldn’t reach the App Store"))
        #expect(!paywall.contains("Subscriptions aren’t available right now"))
    }

    /// The scan itself: it sees a declaration in code and ignores one named only in a comment.
    @Test func theScanReadsCodeNotComments() {
        #expect(Self.declarations(in: "@MainActor\nenum MBLockWindow {\n}") == ["enum MBLockWindow"])
        let commented = GLSource.strippingComments("// enum MBLockWindow, transplanted\nlet x = 1")
        #expect(Self.declarations(in: commented).isEmpty)
        #expect(Self.declarations(in: "final class MBWarmLock {}") == ["class MBWarmLock"])
        #expect(Self.declarations(in: "enum MBWarmLockConfig {}").isEmpty)
    }
}
