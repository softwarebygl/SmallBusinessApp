//
//  Customer.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import Foundation
import SwiftData

@Model
final class Customer {
    var firstName: String
    var lastName: String
    var email: String
    var phoneNumber: String
    var businessName: String?
    var address: Address
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var profileImageData: Data?

    init(
        firstName: String = "",
        lastName: String = "",
        email: String = "",
        phoneNumber: String = "",
        businessName: String? = nil,
        address: Address = Address(),
        createdAt: Date = .now
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phoneNumber = phoneNumber
        self.businessName = businessName
        self.address = address
        self.createdAt = createdAt
    }
}

nonisolated extension Customer {
    var listDisplayName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = (businessName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !last.isEmpty, !first.isEmpty { return "\(last), \(first)" }
        if !last.isEmpty { return last }
        if !first.isEmpty { return first }
        if !business.isEmpty { return business }
        return "No name"
    }

    var initials: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines).first
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines).first
        let combined = [first, last].compactMap { $0 }.map(String.init).joined().uppercased()
        if !combined.isEmpty { return combined }
        if let business = businessName?.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(business).uppercased()
        }
        return "?"
    }
}

nonisolated struct Address: Codable, Hashable, Sendable {
    var street1: String
    var street2: String?
    var city: String
    var state: String
    var postalCode: String
    var country: String

    init(
        street1: String = "",
        street2: String? = nil,
        city: String = "",
        state: String = "",
        postalCode: String = "",
        country: String = ""
    ) {
        self.street1 = street1
        self.street2 = street2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }
}
