//
//  PrivacyManifestTests.swift
//  GLSmallBusinessTests
//
//  QA audit F39 / F122: the privacy manifest names every kind of data the app collects, and the
//  entitlements and background modes name nothing the build does not use (no push code exists).
//

import Testing
import Foundation

struct PrivacyManifestTests {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GLSmallBusiness")

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent(name))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theManifestNamesPhotosOtherContentAndPurchaseData() throws {
        let manifest = try Self.plist("PrivacyInfo.xcprivacy")
        let collected = (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        for type in ["NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypeOtherUserContent",
                     "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeEmailAddress",
                     "NSPrivacyCollectedDataTypeName", "NSPrivacyCollectedDataTypeUserID"] {
            #expect(collected.contains(type), "\(type) is missing from the privacy manifest")
        }
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let linked = (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
        #expect(linked.allSatisfy { ($0["NSPrivacyCollectedDataTypeTracking"] as? Bool) == false })
    }

    @Test func noPushEntitlementOrBackgroundModeWithoutPushCode() throws {
        let entitlements = try Self.plist("GLSmallBusiness.entitlements")
        #expect(entitlements["aps-environment"] == nil)
        #expect(entitlements["com.apple.developer.aps-environment"] == nil)
        let info = try Self.plist("Info.plist")
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        #expect(!modes.contains("remote-notification"))
    }
}
