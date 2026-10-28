//
//  BusinessProfileService.swift
//  GLSmallBusiness
//
//  Every write to the business profile singleton: My Business Details (everything but the Tax ID,
//  which stays in the form behind Face ID and the Keychain), the logos, Document Messages (message
//  wording, warranty, review link) and the Settings screen's "What customers see" switches (the
//  insurance and license documents are `DocumentService`'s). Shared by those screens and (later) the assistant's tools.
//
//  The singleton is found or created here, never by a caller. A screen may hand in the transient
//  stand-in `BusinessProfileHost` renders when the bootstrap was refused (lapsed or offline); a
//  write that is allowed now adopts it into the store, as My Business Details always has.
//  New here: every write ends in `saveChanges()` — these screens used to rely on autosave.
//

import Foundation
import SwiftData

/// My Business Details, minus the Tax ID and the logos.
struct BusinessDetailsDraft: Equatable {
    var businessName = ""
    var ownerFirstName = ""
    var ownerLastName = ""
    var licenseNumber = ""
    var email = ""
    var phone = ""
    var websiteURL = ""
    var reviewsURL = ""
    /// Street, city, state and ZIP. The details form has no Apt/Suite line, so street2 is left as
    /// it is.
    var address = Address()
    var w9Name = ""
    var w9TaxClassification: W9TaxClassification?
    var w9LLCClassification = ""
    var w9OtherClassification = ""
    var w9TINType: W9TINType?
    var w9ExemptPayeeCode = ""
    var w9FATCACode = ""

    init() {}

    /// The profile's current values — the starting point for a partial edit.
    init(_ profile: BusinessProfile) {
        businessName = profile.businessName
        ownerFirstName = profile.ownerFirstName
        ownerLastName = profile.ownerLastName
        licenseNumber = profile.licenseNumber
        email = profile.email
        phone = profile.phone
        websiteURL = profile.websiteURL
        reviewsURL = profile.reviewsURL
        address = profile.address
        w9Name = profile.w9Name
        w9TaxClassification = profile.w9TaxClassification
        w9LLCClassification = profile.w9LLCClassification
        w9OtherClassification = profile.w9OtherClassification
        w9TINType = profile.w9TINType
        w9ExemptPayeeCode = profile.w9ExemptPayeeCode
        w9FATCACode = profile.w9FATCACode
    }

    /// A business name, plus an email or a phone — what sending a document needs (the Save itself
    /// needs only the name).
    var isComplete: Bool {
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filled(businessName) && (filled(email) || filled(phone))
    }
}

/// The light and dark logos (PNG), nil for none.
struct BusinessLogos: Equatable {
    var light: Data?
    var dark: Data?
}

/// Document Messages: per-document subject/intro/closing, the warranty, and the receipt review
/// link. Blank wording means "use the suggested wording".
struct DocumentMessagesDraft: Equatable {
    var includeReviewLinkOnReceipts = false
    var reviewsURL = ""
    var estimateSubject = "", estimateIntro = "", estimateClosing = ""
    var invoiceSubject = "", invoiceIntro = "", invoiceClosing = ""
    var receiptSubject = "", receiptIntro = "", receiptClosing = ""
    var changeOrderSubject = "", changeOrderIntro = "", changeOrderClosing = ""
    var packageSubject = "", packageIntro = "", packageClosing = ""
    var completionSubject = "", completionIntro = "", completionClosing = ""
    var warrantyText = ""

    init() {}

    init(_ profile: BusinessProfile) {
        includeReviewLinkOnReceipts = profile.includeReviewLinkOnReceipts
        reviewsURL = profile.reviewsURL
        estimateSubject = profile.estimateMessageSubject
        estimateIntro = profile.messageIntro
        estimateClosing = profile.messageClosing
        invoiceSubject = profile.invoiceMessageSubject
        invoiceIntro = profile.invoiceMessageIntro
        invoiceClosing = profile.invoiceMessageClosing
        receiptSubject = profile.receiptMessageSubject
        receiptIntro = profile.receiptMessageIntro
        receiptClosing = profile.receiptMessageClosing
        changeOrderSubject = profile.changeOrderMessageSubject
        changeOrderIntro = profile.changeOrderMessageIntro
        changeOrderClosing = profile.changeOrderMessageClosing
        packageSubject = profile.packageMessageSubject
        packageIntro = profile.packageMessageIntro
        packageClosing = profile.packageMessageClosing
        completionSubject = profile.completionMessageSubject
        completionIntro = profile.completionMessageIntro
        completionClosing = profile.completionMessageClosing
        warrantyText = profile.warrantyText
    }
}

/// The Settings screen's "What customers see" switches.
enum BusinessDisplaySetting: CaseIterable {
    /// Logo on documents and texts.
    case logoOnDocuments
    /// Logo and signature in emails.
    case emailSignature
    /// Business address on documents.
    case addressOnDocuments

    var keyPath: ReferenceWritableKeyPath<BusinessProfile, Bool> {
        switch self {
        case .logoOnDocuments: \.showLogoOnDocuments
        case .emailSignature: \.emailSignatureEnabled
        case .addressOnDocuments: \.showAddressOnDocuments
        }
    }
}

@MainActor
enum BusinessProfileService {

    // MARK: Details

    /// My Business Details (not the Tax ID). `logos`, when given, replaces both logos. Returns the
    /// profile written — the stored one, which is not the screen's stand-in when a stored profile
    /// appeared meanwhile — so the caller writes the Tax ID onto the same record.
    @discardableResult
    static func updateDetails(_ draft: BusinessDetailsDraft, logos: BusinessLogos? = nil,
                              for profile: BusinessProfile? = nil, in context: ModelContext,
                              subscription: SubscriptionManager? = nil) throws -> BusinessProfile {
        try DomainGate.requireWritable(.saveBusinessProfile, subscription)
        guard !draft.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainGate.refusal(.businessNameRequired, .saveBusinessProfile)
        }
        // A name alone saves (found 2026-09-29: a name-only first save on an empty profile was
        // refused with contact_required). Contact details are needed to SEND documents — that is
        // the send gate (`BusinessProfile.isComplete`), not a reason to lose what was typed.
        let target = try context.writableBusinessProfile(profile, .saveBusinessProfile)
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        setIfChanged(target, \.businessName, trim(draft.businessName))
        setIfChanged(target, \.ownerFirstName, trim(draft.ownerFirstName))
        setIfChanged(target, \.ownerLastName, trim(draft.ownerLastName))
        setIfChanged(target, \.licenseNumber, trim(draft.licenseNumber))
        setIfChanged(target, \.email, trim(draft.email))
        setIfChanged(target, \.phone, trim(draft.phone))
        setIfChanged(target, \.websiteURL, trim(draft.websiteURL))
        setIfChanged(target, \.reviewsURL, trim(draft.reviewsURL))
        setIfChanged(target, \.addressStreet1, trim(draft.address.street1))
        setIfChanged(target, \.addressCity, trim(draft.address.city))
        setIfChanged(target, \.addressState, trim(draft.address.state))
        setIfChanged(target, \.addressPostalCode, trim(draft.address.postalCode))
        setIfChanged(target, \.w9Name, trim(draft.w9Name))
        setIfChanged(target, \.w9TaxClassificationRaw, draft.w9TaxClassification?.rawValue ?? "")
        setIfChanged(target, \.w9LLCClassification, trim(draft.w9LLCClassification).uppercased())
        setIfChanged(target, \.w9OtherClassification, trim(draft.w9OtherClassification))
        setIfChanged(target, \.w9TINTypeRaw, draft.w9TINType?.rawValue ?? "")
        setIfChanged(target, \.w9ExemptPayeeCode, trim(draft.w9ExemptPayeeCode))
        setIfChanged(target, \.w9FATCACode, trim(draft.w9FATCACode))
        if let logos {
            setIfChanged(target, \.logoData, logos.light)
            setIfChanged(target, \.logoDataDark, logos.dark)
        }
        context.saveChanges()
        return target
    }

    /// Sets one logo (PNG), or removes it with `nil`.
    static func setLogo(_ data: Data?, dark: Bool, for profile: BusinessProfile? = nil,
                        in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveBusinessProfile, subscription)
        let target = try context.writableBusinessProfile(profile, .saveBusinessProfile)
        setIfChanged(target, dark ? \.logoDataDark : \.logoData, data)
        context.saveChanges()
    }

    // MARK: Document Messages

    /// Message wording, warranty and the receipt review link, all trimmed.
    static func updateDocumentMessages(_ draft: DocumentMessagesDraft, for profile: BusinessProfile? = nil,
                                       in context: ModelContext,
                                       subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveDocumentSettings, subscription)
        let target = try context.writableBusinessProfile(profile, .saveDocumentSettings)
        func put(_ keyPath: ReferenceWritableKeyPath<BusinessProfile, String>, _ value: String) {
            setIfChanged(target, keyPath, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        setIfChanged(target, \.includeReviewLinkOnReceipts, draft.includeReviewLinkOnReceipts)
        put(\.reviewsURL, draft.reviewsURL)
        put(\.estimateMessageSubject, draft.estimateSubject)
        put(\.messageIntro, draft.estimateIntro)
        put(\.messageClosing, draft.estimateClosing)
        put(\.invoiceMessageSubject, draft.invoiceSubject)
        put(\.invoiceMessageIntro, draft.invoiceIntro)
        put(\.invoiceMessageClosing, draft.invoiceClosing)
        put(\.receiptMessageSubject, draft.receiptSubject)
        put(\.receiptMessageIntro, draft.receiptIntro)
        put(\.receiptMessageClosing, draft.receiptClosing)
        put(\.changeOrderMessageSubject, draft.changeOrderSubject)
        put(\.changeOrderMessageIntro, draft.changeOrderIntro)
        put(\.changeOrderMessageClosing, draft.changeOrderClosing)
        put(\.packageMessageSubject, draft.packageSubject)
        put(\.packageMessageIntro, draft.packageIntro)
        put(\.packageMessageClosing, draft.packageClosing)
        put(\.completionMessageSubject, draft.completionSubject)
        put(\.completionMessageIntro, draft.completionIntro)
        put(\.completionMessageClosing, draft.completionClosing)
        put(\.warrantyText, draft.warrantyText)
        context.saveChanges()
    }

    // MARK: Settings switches

    /// One of the "What customers see" switches (a Settings write, `.saveAppSettings`).
    static func setDisplay(_ setting: BusinessDisplaySetting, _ on: Bool, in context: ModelContext,
                           subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveAppSettings, subscription)
        let target = try context.writableBusinessProfile(nil, .saveAppSettings)
        setIfChanged(target, setting.keyPath, on)
        context.saveChanges()
    }

    /// Get Paid's "Pay button on new invoices" default (a Settings write, `.saveAppSettings`).
    static func setPayLinkDefault(_ on: Bool, in context: ModelContext,
                                  subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveAppSettings, subscription)
        let target = try context.writableBusinessProfile(nil, .saveAppSettings)
        setIfChanged(target, \.payLinkDefaultOn, on)
        context.saveChanges()
    }

    /// Zelle's "Include Zelle details on new invoices" default.
    static func setZelleDefault(_ on: Bool, in context: ModelContext,
                                subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveAppSettings, subscription)
        let target = try context.writableBusinessProfile(nil, .saveAppSettings)
        setIfChanged(target, \.zelleDefaultOn, on)
        context.saveChanges()
    }

    /// Updates Zelle contact details (tag, email, phone, QR code).
    static func updateZelleDetails(tag: String, email: String, phone: String, qrCodeData: Data?,
                                   in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveAppSettings, subscription)
        let target = try context.writableBusinessProfile(nil, .saveAppSettings)
        setIfChanged(target, \.zelleTag, tag.trimmingCharacters(in: .whitespacesAndNewlines))
        setIfChanged(target, \.zelleEmail, email.trimmingCharacters(in: .whitespacesAndNewlines))
        setIfChanged(target, \.zellePhone, phone.trimmingCharacters(in: .whitespacesAndNewlines))
        if target.zelleQRCodeData != qrCodeData {
            target.zelleQRCodeData = qrCodeData
        }
        context.saveChanges()
    }

    /// The extra line in emails. Stored exactly as typed (the field writes on every keystroke, so
    /// trimming here would eat the space someone is about to type a word after). The Settings field
    /// passes `saveNow: false` per keystroke and saves once when editing ends — a save per keystroke
    /// would stamp and queue a sync op for every letter.
    static func setEmailSignatureText(_ text: String, saveNow: Bool = true, in context: ModelContext,
                                      subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveAppSettings, subscription)
        let target = try context.writableBusinessProfile(nil, .saveAppSettings)
        setIfChanged(target, \.emailSignatureText, text)
        if saveNow { context.saveChanges() }
    }
}

// MARK: - The singleton

extension ModelContext {
    /// The business profile a write lands on: the one given (a detached stand-in is adopted into
    /// the store — the caller has passed the gate, so the insert is allowed — unless a stored
    /// profile exists by now, which is used instead), else the stored singleton, else a new one. A deleted profile is refused. A helper, not an entry point: only
    /// ever called after the caller's own gate, by BusinessProfileService and DocumentService
    /// (the compliance documents live on the profile), whose writes then save.
    @MainActor
    func writableBusinessProfile(_ profile: BusinessProfile?,
                                 _ operation: MBWriteOperation) throws -> BusinessProfile {
        let stored = try? fetch(FetchDescriptor<BusinessProfile>()).first
        if let profile {
            if profile.modelContext == nil, !profile.isDeleted {
                // A stand-in from while the bootstrap was refused. If the real profile has
                // appeared since (reconnected, or pulled by a sync), the write goes onto it —
                // inserting the stand-in too would make a second singleton.
                if let stored { return stored }
                insert(profile)
            }
            try DomainGate.requireLive(profile, operation)
            return profile
        }
        if let stored { return stored }
        let created = BusinessProfile()
        insert(created)
        return created
    }
}
