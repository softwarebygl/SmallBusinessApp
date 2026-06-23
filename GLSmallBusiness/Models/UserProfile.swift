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

    /// An optional profile photo of the account owner (square PNG, displayed in a circle). Synced
    /// privately through CloudKit.
    @Attribute(.externalStorage) var photoData: Data?

    /// The owner's saved signature as a transparent PNG, applied (after Face ID) to documents like
    /// the W-9. It's the person's signature, so it lives here rather than on the business. Synced
    /// privately through CloudKit.
    @Attribute(.externalStorage) var signatureData: Data?

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

    /// Up to two uppercase initials for the avatar monogram; "?" when no name is set.
    var initials: String {
        let parts = [firstName, lastName].compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).first
        }
        let combined = parts.map(String.init).joined().uppercased()
        return combined.isEmpty ? "?" : combined
    }

    var hasDetails: Bool {
        !fullName.isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a saved signature exists.
    var hasSignature: Bool { signatureData != nil }
}
