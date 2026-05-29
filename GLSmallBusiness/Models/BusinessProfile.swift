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

    /// The logo to display for a given appearance: the dark variant in dark mode (falling back
    /// to the light/default logo), and the light/default logo otherwise.
    func logo(for colorScheme: ColorScheme) -> Data? {
        colorScheme == .dark ? (logoDataDark ?? logoData) : logoData
    }
}
