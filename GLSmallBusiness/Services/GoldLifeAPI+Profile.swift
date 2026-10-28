//
//  GoldLifeAPI+Profile.swift — what is left of the app's own profile networking: the
//  one-time legacy upload GLProfileMigrator sends. The profile READ and its per-app cache
//  (GLProfileManager, UserDefaults 'gl_profile_cache') are gone (audit 2026-10-03 F38/F93,
//  law 48): GoldLifeID owns the identity record, its cache and its refresh.
//

import Foundation

enum GLAvatarField: Sendable {
    case unchanged
    case set(String?) // nil to clear
}

struct GLProfileContact: Sendable {
    var firstName: String?
    var middleName: String?
    var lastName: String?
    var phone: String?
    var addressNumber: String?
    var addressStreet: String?
    var addressCity: String?
    var addressState: String?
    var addressZip: String?

    nonisolated init(
        firstName: String? = nil,
        middleName: String? = nil,
        lastName: String? = nil,
        phone: String? = nil,
        addressNumber: String? = nil,
        addressStreet: String? = nil,
        addressCity: String? = nil,
        addressState: String? = nil,
        addressZip: String? = nil
    ) {
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.phone = phone
        self.addressNumber = addressNumber
        self.addressStreet = addressStreet
        self.addressCity = addressCity
        self.addressState = addressState
        self.addressZip = addressZip
    }

    nonisolated var wireFields: [String: String] {
        var out: [String: String] = [:]
        if let firstName { out["first_name"] = firstName }
        if let middleName { out["middle_name"] = middleName }
        if let lastName { out["last_name"] = lastName }
        if let phone { out["phone"] = phone }
        if let addressNumber { out["address_number"] = addressNumber }
        if let addressStreet { out["address_street"] = addressStreet }
        if let addressCity { out["address_city"] = addressCity }
        if let addressState { out["address_state"] = addressState }
        if let addressZip { out["address_zip"] = addressZip }
        return out
    }
}

extension GoldLifeAPI {
    nonisolated func putProfile(displayName: String?, avatar: GLAvatarField,
                                contact: GLProfileContact = GLProfileContact(),
                                ifAbsent: Bool = false) async throws {
        var fields: [String: Any] = ["if_absent": ifAbsent]
        if let displayName { fields["display_name"] = displayName }
        if case .set(let base64) = avatar { fields["avatar_png"] = base64 ?? NSNull() }
        for (key, value) in contact.wireFields { fields[key] = value }
        
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await send("profile", method: "PUT", body: body)
    }
}
