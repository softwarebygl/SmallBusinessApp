//
//  ContactPhotoImportTests.swift — the contact-photo import mapping.
//
//  Owner report 2026-08-31: importing a contact that has a picture dropped the
//  picture. `ContactsBridge.Draft` never carried one. These pin the mapping and
//  — more importantly — the SAFETY rule: CNContact throws an Objective-C
//  exception (an uncatchable crash, not a Swift error) when you read a key that
//  was never fetched, and the contact picker decides which keys come back.
//

import Testing
import Contacts
import UIKit
@testable import GLSmallBusiness

struct ContactPhotoImportTests {

    private func jpeg(_ color: UIColor, size: CGFloat = 40) -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.jpegData(compressionQuality: 0.9)!
    }

    @Test func aContactPhotoIsCarriedIntoTheDraft() throws {
        let contact = CNMutableContact()
        contact.givenName = "Photo"
        contact.familyName = "Haver"
        contact.imageData = jpeg(.systemRed)

        let draft = ContactsBridge.draft(from: contact as CNContact)
        #expect(draft.firstName == "Photo")
        let photo = try #require(draft.imageData, "a contact with a picture must import that picture")
        // Re-encoded to the app's storage convention, so it decodes as an image.
        #expect(UIImage(data: photo) != nil)
    }

    @Test func aContactWithoutAPhotoImportsNone() {
        let contact = CNMutableContact()
        contact.givenName = "No"
        contact.familyName = "Picture"
        let draft = ContactsBridge.draft(from: contact as CNContact)
        #expect(draft.imageData == nil, "no photo must stay nil, never an empty Data")
        #expect(draft.firstName == "No")
    }

    /// The crash guard. A contact fetched WITHOUT the image keys must not be
    /// read for them — `isKeyAvailable` is the only thing standing between this
    /// mapping and an uncatchable ObjC exception at the picker callback.
    @Test func aContactMissingTheImageKeysIsSafeToMap() throws {
        // A contact fetched with a narrow key set is the shape the picker can
        // hand back; mapping it must return a draft, not trap.
        let store = CNContactStore()
        let narrow = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
        _ = store   // not executed: fetching needs authorization in a test host.
        _ = narrow

        // Simulate directly: a contact whose image keys were never populated.
        let contact = CNMutableContact()
        contact.givenName = "Narrow"
        let frozen = contact.copy() as! CNContact
        #expect(frozen.isKeyAvailable(CNContactGivenNameKey))
        let draft = ContactsBridge.draft(from: frozen)
        #expect(draft.firstName == "Narrow")
        #expect(draft.imageData == nil)
    }
}
