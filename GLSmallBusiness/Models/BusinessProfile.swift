//
//  BusinessProfile.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData

/// The company's own details, shown as the header on estimates/invoices/receipts.
/// A single instance is expected; the Settings screen fetches-or-creates it.
@Model
final class BusinessProfile {
    var businessName: String = ""
    var phone: String = ""
    var email: String = ""
    var licenseNumber: String = ""
    var address: Address = Address()
    @Attribute(.externalStorage) var logoData: Data?

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
}
