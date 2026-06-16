//
//  UserProfile.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/15/26.
//
//  The account owner's personal details (distinct from the business). A single instance is
//  expected; screens fetch-or-create it. Synced privately through CloudKit like BusinessProfile.

import Foundation
import SwiftData

@Model
final class UserProfile {
    var firstName: String = ""
    var lastName: String = ""
    var email: String = ""
    var phone: String = ""

    init() {}
}

extension UserProfile {
    /// "First Last", trimmed; empty when no name is set.
    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var hasDetails: Bool {
        !fullName.isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
