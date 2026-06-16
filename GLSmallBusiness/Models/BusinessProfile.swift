//
//  BusinessProfile.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - W-9 enums

/// The federal tax classification checked on line 3a of IRS Form W-9.
enum W9TaxClassification: String, CaseIterable, Identifiable, Sendable {
    case individual
    case cCorporation
    case sCorporation
    case partnership
    case trustEstate
    case llc
    case other

    var id: String { rawValue }

    /// Plain label used in the My Company picker.
    var label: String {
        switch self {
        case .individual: return String(localized: "Individual / Sole Proprietor")
        case .cCorporation: return String(localized: "C Corporation")
        case .sCorporation: return String(localized: "S Corporation")
        case .partnership: return String(localized: "Partnership")
        case .trustEstate: return String(localized: "Trust / Estate")
        case .llc: return String(localized: "Limited Liability Company")
        case .other: return String(localized: "Other")
        }
    }

    /// The exact wording printed next to the checkbox on the W-9.
    var formLabel: String {
        switch self {
        case .individual: return "Individual/sole proprietor"
        case .cCorporation: return "C corporation"
        case .sCorporation: return "S corporation"
        case .partnership: return "Partnership"
        case .trustEstate: return "Trust/estate"
        case .llc: return "Limited liability company"
        case .other: return "Other"
        }
    }
}

/// Whether the W-9 taxpayer ID is a Social Security Number or an Employer ID Number.
enum W9TINType: String, CaseIterable, Identifiable, Sendable {
    case ssn
    case ein

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ssn: return String(localized: "SSN")
        case .ein: return String(localized: "EIN")
        }
    }
}

/// The company's own details, shown as the header on estimates/invoices/receipts.
/// A single instance is expected; the Settings screen fetches-or-creates it.
@Model
final class BusinessProfile {
    var businessName: String = ""
    /// The business owner's name, kept as separate parts so it can be formatted however a given
    /// context needs ("First Last", "Last, First", first-only, …).
    var ownerFirstName: String = ""
    var ownerLastName: String = ""
    var phone: String = ""
    var email: String = ""
    var licenseNumber: String = ""
    var address: Address = Address()
    /// The light/default logo. Used on estimates, emails, and the app's light appearance.
    @Attribute(.externalStorage) var logoData: Data?
    /// Optional dark-appearance logo. Falls back to `logoData` when not set.
    @Attribute(.externalStorage) var logoDataDark: Data?

    // Optional custom wording for each document's email/text — subject, intro, and closing. Empty =
    // use the prepared default, so future default-wording improvements reach anyone who hasn't
    // customized. Estimate intro/closing kept their original names (`messageIntro`/`messageClosing`)
    // to avoid a storage migration; everything added since is namespaced per document.

    /// Estimate email/text.
    var estimateMessageSubject: String = ""
    var messageIntro: String = ""
    var messageClosing: String = ""

    /// Invoice email/text.
    var invoiceMessageSubject: String = ""
    var invoiceMessageIntro: String = ""
    var invoiceMessageClosing: String = ""

    /// Payment-receipt email/text.
    var receiptMessageSubject: String = ""
    var receiptMessageIntro: String = ""
    var receiptMessageClosing: String = ""

    /// Change-order email/text.
    var changeOrderMessageSubject: String = ""
    var changeOrderMessageIntro: String = ""
    var changeOrderMessageClosing: String = ""

    /// Contractor Package share (text/email).
    var packageMessageSubject: String = ""
    var packageMessageIntro: String = ""
    var packageMessageClosing: String = ""

    // MARK: W-9 details (used to generate a W-9 PDF; all optional)

    /// Line 1 — name as shown on the income tax return. Falls back to `businessName` when blank.
    var w9Name: String = ""
    /// `W9TaxClassification.rawValue`; "" = not set.
    var w9TaxClassificationRaw: String = ""
    /// For LLCs, the tax classification letter entered on line 3a (C, S, or P).
    var w9LLCClassification: String = ""
    /// Free-text description when the classification is "Other".
    var w9OtherClassification: String = ""
    /// `W9TINType.rawValue`; "" = not set.
    var w9TINTypeRaw: String = ""
    /// Legacy plaintext taxpayer ID. No longer the source of truth — the TIN now lives in the
    /// Keychain (see `secureTIN`). Kept only so existing values can migrate; cleared on first save.
    var w9TIN: String = ""
    /// Line 4 — exempt payee code (optional; most filers leave blank).
    var w9ExemptPayeeCode: String = ""
    /// Line 4 — exemption from FATCA reporting code (optional; most filers leave blank).
    var w9FATCACode: String = ""

    /// Manually uploaded compliance certificates (PDFs) shared from the Business screen — general
    /// liability insurance, workers' comp insurance, and a workers' comp exemption certificate.
    /// (`proofOfInsuranceData` predates the "General Liability Insurance" rename; kept to avoid a
    /// storage migration.) Stored as-is and synced privately through CloudKit.
    @Attribute(.externalStorage) var proofOfInsuranceData: Data?
    var proofOfInsuranceName: String = ""
    @Attribute(.externalStorage) var wcInsuranceData: Data?
    var wcInsuranceName: String = ""
    @Attribute(.externalStorage) var wcExemptionData: Data?
    var wcExemptionName: String = ""

    /// The contractor/business license document (PDF or image), uploaded alongside the insurance
    /// certificates and bundled into the Contractor Package when present.
    @Attribute(.externalStorage) var licenseDocumentData: Data?
    var licenseDocumentName: String = ""

    // MARK: Contractor Package — placement memory only

    // The certificate holder itself is intentionally NOT stored: the holder fields start blank for
    // every package, so a stale holder can never be sent to the wrong GC by mistake. Only the
    // placement of the box on the user's own COI form is remembered (that's a property of their
    // insurer's layout, not of any holder).

    /// A one-time manual nudge (in PDF points, origin bottom-left) applied to the auto-detected
    /// holder-box position, so the box only has to be lined up once per COI.
    var coiHolderOffsetX: Double = 0
    var coiHolderOffsetY: Double = 0
    /// Lays a white box over any certificate-holder text already printed on the uploaded COI before
    /// stamping the new holder — for COIs that arrive with a prior holder filled in.
    var coiCoverExistingHolder: Bool = false

    init() {}
}

extension BusinessProfile {
    /// The owner's name as "First Last", trimmed; empty when no name is set.
    var ownerFullName: String {
        [ownerFirstName, ownerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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

    // MARK: - W-9 helpers

    var w9TaxClassification: W9TaxClassification? {
        get { W9TaxClassification(rawValue: w9TaxClassificationRaw) }
        set { w9TaxClassificationRaw = newValue?.rawValue ?? "" }
    }

    var w9TINType: W9TINType? {
        get { W9TINType(rawValue: w9TINTypeRaw) }
        set { w9TINTypeRaw = newValue?.rawValue ?? "" }
    }

    /// The taxpayer ID (SSN/EIN), read from the Keychain. Falls back to the legacy plaintext value
    /// until the owner next saves the form, which migrates it into the Keychain and clears the copy.
    var secureTIN: String {
        let stored = SecureTINStore.read()
        return stored.isEmpty ? w9TIN : stored
    }

    /// Writes the taxpayer ID to the Keychain and purges any legacy plaintext copy from the store.
    func updateTIN(_ value: String) {
        SecureTINStore.write(value)
        if !w9TIN.isEmpty { w9TIN = "" }
    }

    /// Line 1 of the W-9 — the name as shown on the tax return, falling back to the business name.
    var w9LegalName: String {
        let trimmed = w9Name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? businessName : trimmed
    }

    // MARK: - Compliance documents

    var hasProofOfInsurance: Bool { proofOfInsuranceData != nil }
    var hasWCInsurance: Bool { wcInsuranceData != nil }
    var hasWCExemption: Bool { wcExemptionData != nil }
    var hasLicenseDocument: Bool { licenseDocumentData != nil }
    /// At least one compliance/licensing document has been uploaded.
    var hasComplianceDocuments: Bool {
        hasProofOfInsurance || hasWCInsurance || hasWCExemption || hasLicenseDocument
    }

    // MARK: - Contractor Package

    /// The Certificate of Liability Insurance used by the Contractor Package — the General Liability
    /// certificate on file (a COI *is* the GL certificate). A package can't be built without one.
    var coiData: Data? { proofOfInsuranceData }
    var hasCOI: Bool { proofOfInsuranceData != nil }

    /// The persisted holder placement nudge as a CGSize (PDF points, origin bottom-left).
    var coiHolderOffset: CGSize {
        get { CGSize(width: coiHolderOffsetX, height: coiHolderOffsetY) }
        set { coiHolderOffsetX = newValue.width; coiHolderOffsetY = newValue.height }
    }

    /// True once there's enough on file to build a package: a COI plus a complete W-9.
    var contractorPackageReady: Bool { hasCOI && w9IsComplete }

    /// The minimum needed to produce a usable W-9: a name, a classification, and a TIN.
    var w9IsComplete: Bool { w9MissingRequirements.isEmpty }

    /// The W-9 requirements still missing after reusing the company info already on file (name falls
    /// back to the business name; the address comes from `address`). Empty means the W-9 is ready.
    var w9MissingRequirements: [String] {
        var missing: [String] = []
        if w9LegalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(String(localized: "Your name (as shown on your tax return)"))
        }
        if w9TaxClassification == nil {
            missing.append(String(localized: "Federal tax classification"))
        }
        if w9TINType == nil || secureTIN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(String(localized: "Tax ID (SSN or EIN)"))
        }
        return missing
    }
}
