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
        case .individual: return mbLoc("Individual / Sole Proprietor")
        case .cCorporation: return mbLoc("C Corporation")
        case .sCorporation: return mbLoc("S Corporation")
        case .partnership: return mbLoc("Partnership")
        case .trustEstate: return mbLoc("Trust / Estate")
        case .llc: return mbLoc("Limited Liability Company")
        case .other: return mbLoc("Other")
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
        case .ssn: return mbLoc("SSN")
        case .ein: return mbLoc("EIN")
        }
    }

    /// English-only surfaces (accountant CSVs) - see PaymentMethod.englishLabel.
    var englishLabel: String {
        switch self {
        case .ssn: return "SSN"
        case .ein: return "EIN"
        }
    }
}

/// The company's own details, shown as the header on estimates/invoices/receipts.
/// A single instance is expected; the Settings screen fetches-or-creates it.
@Model
final class BusinessProfile {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    var businessName: String = ""
    /// The business owner's name, kept as separate parts so it can be formatted however a given
    /// context needs ("First Last", "Last, First", first-only, …).
    var ownerFirstName: String = ""
    var ownerLastName: String = ""
    var phone: String = ""
    var email: String = ""
    /// Optional public website, and a "leave a review" link. The review link can be sent to a customer
    /// on its own from My Business Details, and (when `includeReviewLinkOnReceipts` is on) closes every
    /// payment receipt (PDF + email/text) so customers can rate the business in one tap. Additive/optional.
    var websiteURL: String = ""
    var reviewsURL: String = ""
    /// Whether payment receipts end with the review request. Off by default — receipts stay a pure
    /// acknowledgement unless the owner opts in. The standalone send-a-review-link flow ignores this.
    var includeReviewLinkOnReceipts: Bool = false
    var licenseNumber: String = ""
    /// ⚠️ DORMANT-LEGACY, WRITE-FORBIDDEN (2026-09-01, the build-62 SIGTRAP — same class
    /// as UserProfile.address, build 48). A history UPDATE row naming a composite
    /// sub-attribute whose keypath crosses ANY Optional (`Address.street2: String?`)
    /// fatals uncatchably inside `fetchHistory`. Kept only so old stores keep opening;
    /// `AddressFlatsBackfill` forward-copies it once at mount. Swift-renamed so the
    /// public name stays on the flats façade; `originalName` pins the stored column.
    /// Nothing may ever assign it — reads are safe, writes poison history.
    @Attribute(originalName: "address") var legacyAddress: Address = Address()
    /// The flattened columns behind the `address` façade (the write path since
    /// 2026-09-01). Primitive strings, so their history rows always resolve.
    var addressStreet1: String = ""
    var addressStreet2: String = ""
    var addressCity: String = ""
    var addressState: String = ""
    var addressPostalCode: String = ""
    /// The light/default logo. Used on estimates, emails, and the app's light appearance.
    @Attribute(.externalStorage) var logoData: Data?
    /// Optional dark-appearance logo. Falls back to `logoData` when not set.
    @Attribute(.externalStorage) var logoDataDark: Data?

    /// Whether the company logo prints on the documents sent to customers (estimates, invoices,
    /// receipts, change orders, completion packages). Independent of the in-app logo chrome
    /// (`useCompanyLogo`). Default true preserves the original behavior — logo always on documents.
    var showLogoOnDocuments: Bool = true

    /// The EMAIL signature block (owner feature, 2026-08-29): logo + business info appended to
    /// every customer email the app composes. Its own switch, independent of the documents
    /// toggle — an email is not a PDF. Default true: professional out of the box.
    var emailSignatureEnabled: Bool = true
    /// An optional extra line the owner writes ("Licensed & insured — free estimates"), shown
    /// under the standard block. Empty = no extra line.
    var emailSignatureText: String = ""
    /// Whether the business address prints on those same customer documents. Default true preserves
    /// the original behavior. Turning it off keeps the address in the app + on tax forms (the W-9
    /// still needs it) but omits it from customer-facing documents.
    var showAddressOnDocuments: Bool = true

    /// Highest invoice / estimate number ever issued. A monotonic counter so deleting the highest-
    /// numbered document doesn't reuse its number for a new one (which would collide with the already-
    /// sent original); it lives on the synced profile so it also stays consistent across devices.
    var lastInvoiceNumber: Int = 0
    var lastEstimateNumber: Int = 0

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

    /// Completion package share (text/email).
    var completionMessageSubject: String = ""
    var completionMessageIntro: String = ""
    var completionMessageClosing: String = ""

    /// The owner's work schedule (per-weekday workdays + hours, holidays, vacation, date overrides),
    /// encoded as a Codable `WorkSchedule` blob so it syncs across devices. Nil until first edited —
    /// read it via `workSchedule`, which falls back to a sensible default.
    var workScheduleData: Data?

    /// The business's standard warranty terms (free text). Blank until set — there's no canned default
    /// because warranty terms are legally specific. Snapshotted into each completion package.
    var warrantyText: String = ""

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

    /// Manually uploaded compliance certificates (PDFs) shared from the Business screen — the
    /// workers' comp exemption certificate (and the license below). Stored as-is and synced privately
    /// through CloudKit.
    ///
    /// `proofOfInsuranceData` AND `wcInsuranceData` are RETIRED: insurer-issued Certificates of
    /// Insurance (General Liability and Workers' Comp alike) name their certificate holder, so
    /// they're per-customer — see `Customer.coiData` and `Customer.wcCoiData`. The fields are kept
    /// only so any previously uploaded file isn't destroyed; they're no longer shown or used anywhere.
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

    /// When the workers' comp exemption and the contractor license lapse. Added 2026-09-01 for the
    /// same reason as the per-customer certificate dates: presence was the only thing modelled, so
    /// an expired document still read as good and still went out in a Contractor Package. A GC
    /// rejects an expired exemption or licence exactly as fast as an expired COI. Optional —
    /// unknown for every existing row. FLAT scalars per GLSchema rule 2c.
    var wcExemptionExpiresOn: Date?
    var licenseExpiresOn: Date?

    /// OPTIONAL, owner-only reference copy of a Certificate of Insurance — e.g. a blank/unfilled form the
    /// owner likes to keep on hand. Deliberately separate from anything customer-facing: the real,
    /// insurer-issued COI that names a customer as the holder still lives on `Customer.coiData` and is
    /// unaffected. This copy is never attached to a customer, pulled into the Contractor Package, or
    /// included in the "share all" bundle — it's purely a convenience for the owner's own records.
    @Attribute(.externalStorage) var ownerReferenceCOIData: Data?
    var ownerReferenceCOIName: String = ""

    // MARK: Retired — COI holder stamping

    // These remembered the placement of a stamped certificate-holder box on a single, business-level
    // COI. That approach is gone: a COI must name its holder on the policy itself, so each customer
    // now uploads their own insurer-issued certificate (see `Customer.coiData`) and it's sent as-is.
    // The stored properties are kept (unused) only to avoid a storage migration on existing installs.
    var coiHolderOffsetX: Double = 0
    var coiHolderOffsetY: Double = 0
    var coiHolderBoxWidth: Double = 0
    var coiCoverExistingHolder: Bool = false

    // MARK: Stripe payments (Connect)

    /// The business's Stripe Standard connected-account id ("acct_…"). Empty = not connected. Synced via
    /// CloudKit — this is the durable resume key for onboarding (NOT a volatile per-install id), so a
    /// reinstall or new device resumes the same account instead of creating a duplicate.
    var stripeConnectedAccountId: String = ""
    /// Cached "this account can accept charges" hint, so Settings can show Connected vs. Finish setup
    /// without a network round-trip on every render. May be stale across devices — the AUTHORITATIVE
    /// gate before minting a pay link is a fresh status call to the backend, never this flag.
    var stripeChargesEnabled: Bool = false
    /// Signed ownership claim (an HMAC of the connected-account id, issued by the backend at onboarding).
    /// Synced via CloudKit and presented when resuming onboarding on a new device, so the backend can
    /// prove this install actually owns the account before binding it — without it, anyone who learns an
    /// `acct_…` id could bind it to their own install. Empty until first connected.
    var stripeAccountClaim: String = ""
    /// RETIRED — the 3-way All/Custom/Off mode was replaced by `payLinkDefaultOn` + a per-invoice toggle.
    /// Kept (dormant) because the deployed CloudKit schema can't drop a field; no longer read by the app.
    var payLinkInclusionRaw: String = PayLinkInclusion.all.rawValue
    /// Whether NEW invoices include a Stripe "Pay" button by default. Each invoice's own
    /// `Invoice.includePayLink` is seeded from this and can be overridden per invoice.
    var payLinkDefaultOn: Bool = true

    // MARK: Zelle payments

    /// The business's Zelle tag or recipient name (e.g. "@mybusiness" or "John Doe").
    var zelleTag: String = ""
    /// The business's Zelle registered email.
    var zelleEmail: String = ""
    /// The business's Zelle registered phone number.
    var zellePhone: String = ""
    /// Uploaded QR code image for Zelle payments, shown on invoices so customers can scan and pay.
    @Attribute(.externalStorage) var zelleQRCodeData: Data?
    /// Whether NEW invoices include Zelle payment details by default.
    var zelleDefaultOn: Bool = false

    /// RETIRED — the manual processing-fee tracker was removed from the UI. Kept (dormant) because the app
    /// is live and a deployed CloudKit schema can't drop a relationship; existing users' fee data and
    /// year-end reports stay intact.
    @Relationship(deleteRule: .cascade, inverse: \PaymentProcessor.businessProfile)
    var paymentProcessors: [PaymentProcessor]?

    init() {}
}

extension BusinessProfile {
    /// True if at least one Zelle contact detail or QR code is configured.
    var zelleIsConfigured: Bool {
        !zelleTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !zelleEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !zellePhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        zelleQRCodeData != nil
    }

    /// The owner's work schedule, decoded from `workScheduleData`. Falls back to the standard Mon–Fri
    /// 8–5 + common-holidays schedule when nothing has been saved yet. Always exactly 7 weekdays:
    /// the blob syncs and the server doesn't check its length, and the screen and the assistant
    /// read all 7 days (QA F60).
    var workSchedule: WorkSchedule {
        get {
            guard let data = workScheduleData,
                  let decoded = try? JSONDecoder().decode(WorkSchedule.self, from: data) else {
                return .standard
            }
            return decoded.withSevenWeekdays
        }
        set { workScheduleData = try? JSONEncoder().encode(newValue) }
    }

    /// The owner's name as "First Last", trimmed; empty when no name is set.
    var ownerFullName: String {
        [ownerFirstName, ownerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A user-entered URL made click-ready: trimmed, with `https://` prepended when it has no scheme (so
    /// a pasted "g.page/…" still becomes a working link). Nil when blank or unparseable.
    static func clickableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let withScheme = (lower.hasPrefix("http://") || lower.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    var websiteLink: URL? { Self.clickableURL(websiteURL) }
    var reviewsLink: URL? { Self.clickableURL(reviewsURL) }
    /// The review link to place on payment receipts — nil unless one is set AND the owner turned the
    /// receipt inclusion on. Receipt generators read this instead of `reviewsLink` directly.
    var receiptReviewLink: URL? { includeReviewLinkOnReceipts ? reviewsLink : nil }

    // MARK: - Stripe payments

    /// Which invoices get a Stripe pay link, read from `payLinkInclusionRaw`.
    var payLinkInclusion: PayLinkInclusion {
        get { PayLinkInclusion(rawValue: payLinkInclusionRaw) ?? .all }
        set { payLinkInclusionRaw = newValue.rawValue }
    }

    /// True once a Stripe connected account has been linked (regardless of whether it can charge yet).
    var stripeIsConnected: Bool { !stripeConnectedAccountId.isEmpty }

    /// Has a business name and at least one way to be reached (phone OR email) — a phone-only sole
    /// proprietor who texts everything is a complete, valid setup.
    var isComplete: Bool {
        let hasName = !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContact = !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasContact
    }

    /// The logo to display for a given appearance, falling back to the other variant so a single
    /// uploaded logo shows in both modes: dark mode prefers the dark variant (falling back to the
    /// light/default), light mode prefers the light/default (falling back to the dark variant).
    func logo(for colorScheme: ColorScheme) -> Data? {
        colorScheme == .dark ? (logoDataDark ?? logoData) : (logoData ?? logoDataDark)
    }

    /// The logo to print on customer documents — nil when "show logo on documents" is off, so the
    /// document headers omit it. Document generators read this instead of `logoData` directly.
    var documentLogoData: Data? { showLogoOnDocuments ? logoData : nil }

    /// The logo an EMAIL signature uses: the LIGHT version by default (email grounds are
    /// white), falling back to the dark upload so a single-logo business still signs.
    /// Gated by the email-signature toggle, not the documents toggle.
    var emailLogoData: Data? { emailSignatureEnabled ? (logoData ?? logoDataDark) : nil }

    /// The address to print on customer documents — an empty `Address` when "show address on
    /// documents" is off, so the headers (which already skip an empty address) leave it out.
    var documentAddress: Address { showAddressOnDocuments ? address : Address() }

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
    /// Returns false if the secure write failed, so the caller can tell the user it wasn't saved.
    @discardableResult
    func updateTIN(_ value: String) -> Bool {
        let ok = SecureTINStore.write(value)
        // Only purge the legacy plaintext AFTER a confirmed Keychain write — otherwise a failed write
        // would wipe the last remaining copy of a legacy user's SSN/EIN (secureTIN falls back to it).
        if ok, !w9TIN.isEmpty { w9TIN = "" }
        return ok
    }

    /// Line 1 of the W-9 — the name as shown on the tax return, falling back to the business name.
    var w9LegalName: String {
        let trimmed = w9Name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? businessName : trimmed
    }

    // MARK: - Compliance documents

    // These are the general, reusable documents — the same for every customer, so they live on the
    // business and get pulled into each customer's Contractor Package. (The insurer-issued COIs are
    // NOT here: General Liability and Workers' Comp certificates name their holder, so they're
    // per-customer — see `Customer.coiData` / `Customer.wcCoiData`.)
    var hasWCExemption: Bool { wcExemptionData != nil }
    var hasLicenseDocument: Bool { licenseDocumentData != nil }
    /// At least one compliance/licensing document has been uploaded.
    var hasComplianceDocuments: Bool {
        hasWCExemption || hasLicenseDocument
    }

    // MARK: - W-9

    /// The minimum needed to produce a usable W-9: a name, a classification, and a TIN.
    var w9IsComplete: Bool { w9MissingRequirements.isEmpty }

    /// The W-9 requirements still missing after reusing the company info already on file (name falls
    /// back to the business name; the address comes from `address`). Empty means the W-9 is ready.
    var w9MissingRequirements: [String] {
        var missing: [String] = []
        if w9LegalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(mbLoc("Your name (as shown on your tax return)"))
        }
        if w9TaxClassification == nil {
            missing.append(mbLoc("Federal tax classification"))
        }
        if w9TINType == nil || secureTIN.filter({ $0.isASCII && $0.isNumber }).count != 9 {
            missing.append(mbLoc("Tax ID (SSN or EIN)"))   // needs a full 9 digits, like the 1099 path
        }
        return missing
    }
}

extension BusinessProfile {
    /// THE one door to `address`. Reads see the flat columns only; writes go to flats
    /// only — the legacy composite is write-forbidden (see its doc). Empty street2
    /// normalizes to nil, which renders identically.
    var address: Address {
        get {
            Address(street1: addressStreet1,
                    street2: addressStreet2.isEmpty ? nil : addressStreet2,
                    city: addressCity,
                    state: addressState,
                    postalCode: addressPostalCode)
        }
        set {
            addressStreet1 = newValue.street1
            addressStreet2 = newValue.street2 ?? ""
            addressCity = newValue.city
            addressState = newValue.state
            addressPostalCode = newValue.postalCode
        }
    }
}

nonisolated extension WorkSchedule {
    /// This schedule with exactly 7 weekdays (0 = Sunday … 6 = Saturday): the days it has are kept,
    /// a missing day is the standard one, and extra entries are dropped.
    var withSevenWeekdays: WorkSchedule {
        guard weekdayHours.count != 7 else { return self }
        var copy = self
        let standard = WorkSchedule.standard.weekdayHours
        copy.weekdayHours = standard.indices.map { weekdayHours.indices.contains($0) ? weekdayHours[$0] : standard[$0] }
        return copy
    }
}
