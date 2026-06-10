//
//  BusinessProfile.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData
import SwiftUI

/// The company's own details, shown as the header on estimates/invoices/receipts.
/// A single instance is expected; the Settings screen fetches-or-creates it.
@Model
final class BusinessProfile {
    var businessName: String = ""
    var phone: String = ""
    var email: String = ""
    var licenseNumber: String = ""
    var address: Address = Address()
    /// The light/default logo. Used on estimates, emails, and the app's light appearance.
    @Attribute(.externalStorage) var logoData: Data?
    /// Optional dark-appearance logo. Falls back to `logoData` when not set.
    @Attribute(.externalStorage) var logoDataDark: Data?

    /// Optional custom wording for the estimate email/text. Empty = use the prepared default,
    /// so future default-wording improvements reach anyone who hasn't customized.
    var messageIntro: String = ""
    var messageClosing: String = ""

    /// Same, for the invoice email/text.
    var invoiceMessageIntro: String = ""
    var invoiceMessageClosing: String = ""

    init() {}
}

extension BusinessProfile {
    /// The required fields (business name, phone, email) are all filled —
    /// gates sending an estimate.
    var isComplete: Bool {
        !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The logo to display for a given appearance, falling back to the other variant so a single
    /// uploaded logo shows in both modes: dark mode prefers the dark variant (falling back to the
    /// light/default), light mode prefers the light/default (falling back to the dark variant).
    func logo(for colorScheme: ColorScheme) -> Data? {
        colorScheme == .dark ? (logoDataDark ?? logoData) : (logoData ?? logoDataDark)
    }
}
