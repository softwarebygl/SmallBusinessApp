//
//  GLGoldLifeIDSyncTests.swift — Gold Life ID signature saving and email-signature name
//  resolution (owner ruling 2026-09-19; audit 2026-10-03 F19 / F70, law 48a).
//

import Testing
import Foundation
import SwiftData
import GoldLifeID
@testable import GLSmallBusiness

@Suite("GLGoldLifeIDSync", .serialized)
@MainActor
struct GLGoldLifeIDSyncTests {

    @Test("A signature saved from My Business lands in the Gold Life ID")
    func savedSignatureGoesToTheGoldLifeID() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let identity = MBIdentity.shared
        identity.standIn = .demo
        defer { identity.standIn = nil }

        try await identity.saveSignature(Data([0x09]), legacyIn: context)
        #expect(identity.signatureData == Data([0x09]))

        try await identity.saveSignature(nil, legacyIn: context)
        #expect(identity.signatureData == nil)
    }

    @Test("Change the first name in the Gold Life ID and the next customer email signs with it")
    func emailSignatureShowsTheNewName() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let business = BusinessProfile()
        business.businessName = "Gold Life Tile"
        business.ownerFirstName = "Owner"
        business.ownerLastName = "Person"
        context.insert(business)
        UserProfile.setUseMyNameInEmails(true, in: context)
        let identity = MBIdentity.shared
        identity.standIn = .demo
        defer { identity.standIn = nil }

        identity.standIn?.firstName = "Taylor"
        #expect(EmailSignature.block(business: business, context: context).contains("Taylor Ellis"))
        identity.standIn?.firstName = "Morgan"
        let after = EmailSignature.block(business: business, context: context)
        #expect(after.contains("Morgan Ellis") && !after.contains("Taylor"))

        UserProfile.setUseMyNameInEmails(false, in: context)
        #expect(EmailSignature.block(business: business, context: context).contains("Owner Person"))
    }

    @Test("The email signature's name follows the Gold Life ID")
    func emailSenderNameFollowsTheGoldLifeID() {
        #expect(EmailSignature.senderName(owner: "Owner Name", useMyName: true, myName: "Taylor Ellis") == "Taylor Ellis")
        #expect(EmailSignature.senderName(owner: "Owner Name", useMyName: false, myName: "Taylor Ellis") == "Owner Name")
        #expect(EmailSignature.senderName(owner: "Owner Name", useMyName: true, myName: "  ") == "Owner Name",
                "a blank Gold Life ID name never blanks the name line")
    }
}

@Suite("Name in emails setting", .serialized)
@MainActor
struct EmailNameSettingTests {

    @Test("Choosing My name on a new account creates the one row and saves it")
    func createsTheRowOnFirstWrite() throws {
        let container = try TestStore.makeContainer()
        UserProfile.setUseMyNameInEmails(true, in: container.mainContext)
        let rows = try ModelContext(container).fetch(FetchDescriptor<UserProfile>())
        #expect(rows.count == 1)
        #expect(rows.first?.useMyNameInEmails == true)
    }

    @Test("An existing row is reused, never duplicated")
    func reusesTheExistingRow() throws {
        let container = try TestStore.makeContainer()
        container.mainContext.insert(UserProfile())
        container.mainContext.saveChanges()
        UserProfile.setUseMyNameInEmails(true, in: container.mainContext)
        UserProfile.setUseMyNameInEmails(false, in: container.mainContext)
        let rows = try ModelContext(container).fetch(FetchDescriptor<UserProfile>())
        #expect(rows.count == 1)
        #expect(rows.first?.useMyNameInEmails == false)
    }

    @Test("Settings writes through the find-or-create")
    func settingsUsesTheFindOrCreate() throws {
        let code = try #require(GLSource.code("Screens/SettingsScreen.swift"))
        #expect(code.contains("UserProfile.setUseMyNameInEmails("),
                "Settings ▸ Name in emails writes to a row a new account never has")
        #expect(!code.contains("userProfiles.first?.useMyNameInEmails = "))
    }
}
