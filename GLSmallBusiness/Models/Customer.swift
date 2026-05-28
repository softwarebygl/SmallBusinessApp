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

    init(
        firstName: String = "",
        lastName: String = "",
        email: String = "",
        phoneNumber: String = "",
        businessName: String? = nil,
        address: Address = Address()
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phoneNumber = phoneNumber
        self.businessName = businessName
        self.address = address
    }
}

struct Address: Codable, Hashable, Sendable {
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
