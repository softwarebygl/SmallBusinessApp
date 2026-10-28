//
//  BusinessMappers.swift
//  GLSmallBusiness
//
//  GLSync payload mappers for the business-level records: the two singletons
//  (BusinessProfile, UserProfile), the retired-but-live PaymentProcessor, and the job pair
//  (ScheduledJob + its cascade-child JobAttachment).
//
//  Contract: GLSYNC-SPEC.md §6 and gl-business-api/sync-manifest.json. Payload keys are the
//  SWIFT property names verbatim, so the manifest's protected / strip_fields / max_merge /
//  write_once / status_transitions lists match with no translation table in between.
//
//  Three kinds of stored property deliberately never appear in a payload:
//    • the CASCADE parent link (`PaymentProcessor.businessProfile`, `JobAttachment.job`) —
//      it rides as `glSyncParentID`. Nullify-style references are NOT parents and DO ride in
//      the payload as plain uuids (see `ScheduledJob`).
//    • to-many relationship arrays — the inverse of a child's parent reference. The CHILD
//      carries the link, so emitting the array would duplicate it and race it.
//    • `BusinessProfile.w9TIN` — the one NEVER-SYNCS field (§6). The server strips it, but
//      the client must not rely on that; a plaintext SSN/EIN never leaves the device.
//

import Foundation
import SwiftData

// MARK: - Blob hashing

/// SHA-256 hex of a blob's bytes, or nil when there is no blob. Content addressing is what
/// lets a payload REFERENCE bytes it does not carry: the hash goes in the record, the bytes
/// go to `/attachments`. Pure, so `nonisolated` (the target defaults to MainActor isolation).
///
/// `private` rather than internal deliberately: one copy lives in every mapper file, and a
/// module-scope copy per file would be a duplicate declaration.
private nonisolated func glSyncBlobHash(for data: Data?) -> String? {
    // `!data.isEmpty` is load-bearing, not defensive: GLSyncRegistry.blobBytes filters empty
    // blobs OUT of the upload, so hashing one here would put a {sha256} reference in the
    // payload pointing at bytes that never reach R2 — a document every other device then
    // fails to fetch. Two of the three copies of this helper were missing it (found by
    // GLSyncMappingTests' blob-consistency check, 2026-08-23).
    guard let data, !data.isEmpty else { return nil }
    // Remembered by the bytes (QA 2026-10-03 F91): an unchanged logo is not hashed again on
    // every fold of the profile.
    return GLSyncBlobHashCache.sha256(data)
}

// MARK: - Reference resolution

/// Look-ups for nullify-style references, which arrive as the referent's `syncID`.
///
/// When the referent has not been pulled yet the relationship is left NIL rather than
/// guessed or stubbed: a dangling id must never mint a local row, and the next pull carries
/// the referent so a later patch re-links it. Nil here is a normal, self-healing state.
private enum BusinessMapperLookup {

    static func customer(_ id: UUID?, in context: ModelContext) -> Customer? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Customer>(predicate: #Predicate { $0.syncID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func estimate(_ id: UUID?, in context: ModelContext) -> Estimate? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Estimate>(predicate: #Predicate { $0.syncID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func invoice(_ id: UUID?, in context: ModelContext) -> Invoice? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.syncID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func project(_ id: UUID?, in context: ModelContext) -> Project? {
        guard id != nil else { return nil }
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.syncID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

// MARK: - BusinessProfile

extension BusinessProfile: GLSyncMappable {

    static var glSyncType: String { "business_profile" }

    /// A singleton with no owner above it — the manifest says `parent: null`.
    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload { glSyncPayload(only: nil) }

    /// The payload, or only `fields` of it (nil = all). Same values either way: the fold asks
    /// for just the fields history says moved, and the seven document hashes are built only
    /// when their field is one of them (QA 2026-10-03 F91 — a new invoice bumps
    /// `lastInvoiceNumber`, and that used to re-hash every logo and document).
    ///
    /// One statement per key rather than one 64-entry dictionary literal: a heterogeneous
    /// literal this size is the classic "unable to type-check this expression in reasonable
    /// time" failure, and every mapper here has to keep compiling for years.
    func glSyncPayload(only fields: Set<String>?) -> GLSyncPayload {
        func wants(_ key: String) -> Bool { fields?.contains(key) ?? true }
        var payload: GLSyncPayload = [:]
        payload["syncID"] = GLSyncValue.uuid(syncID)
        payload["updatedAt"] = GLSyncValue.date(updatedAt)
        payload["businessName"] = GLSyncValue.string(businessName)
        payload["ownerFirstName"] = GLSyncValue.string(ownerFirstName)
        payload["ownerLastName"] = GLSyncValue.string(ownerLastName)
        payload["phone"] = GLSyncValue.string(phone)
        payload["email"] = GLSyncValue.string(email)
        payload["websiteURL"] = GLSyncValue.string(websiteURL)
        payload["reviewsURL"] = GLSyncValue.string(reviewsURL)
        payload["includeReviewLinkOnReceipts"] = GLSyncValue.bool(includeReviewLinkOnReceipts)
        payload["licenseNumber"] = GLSyncValue.string(licenseNumber)
        payload["address"] = GLSyncValue.address(address)
        if wants("logoData") {
            payload["logoData"] = GLSyncValue.blobRef(sha256: glSyncBlobHash(for: logoData), name: nil)
        }
        if wants("logoDataDark") {
            payload["logoDataDark"] = GLSyncValue.blobRef(sha256: glSyncBlobHash(for: logoDataDark), name: nil)
        }
        payload["showLogoOnDocuments"] = GLSyncValue.bool(showLogoOnDocuments)
        payload["showAddressOnDocuments"] = GLSyncValue.bool(showAddressOnDocuments)
        payload["emailSignatureEnabled"] = GLSyncValue.bool(emailSignatureEnabled)
        payload["emailSignatureText"] = GLSyncValue.string(emailSignatureText)
        // Monotonic document counters. MAX-merged server-side (manifest `max_merge`) so a stale
        // device can never hand back a lower number and reissue an already-sent one.
        payload["lastInvoiceNumber"] = GLSyncValue.int(lastInvoiceNumber)
        payload["lastEstimateNumber"] = GLSyncValue.int(lastEstimateNumber)
        payload["estimateMessageSubject"] = GLSyncValue.string(estimateMessageSubject)
        payload["messageIntro"] = GLSyncValue.string(messageIntro)
        payload["messageClosing"] = GLSyncValue.string(messageClosing)
        payload["invoiceMessageSubject"] = GLSyncValue.string(invoiceMessageSubject)
        payload["invoiceMessageIntro"] = GLSyncValue.string(invoiceMessageIntro)
        payload["invoiceMessageClosing"] = GLSyncValue.string(invoiceMessageClosing)
        payload["receiptMessageSubject"] = GLSyncValue.string(receiptMessageSubject)
        payload["receiptMessageIntro"] = GLSyncValue.string(receiptMessageIntro)
        payload["receiptMessageClosing"] = GLSyncValue.string(receiptMessageClosing)
        payload["changeOrderMessageSubject"] = GLSyncValue.string(changeOrderMessageSubject)
        payload["changeOrderMessageIntro"] = GLSyncValue.string(changeOrderMessageIntro)
        payload["changeOrderMessageClosing"] = GLSyncValue.string(changeOrderMessageClosing)
        payload["packageMessageSubject"] = GLSyncValue.string(packageMessageSubject)
        payload["packageMessageIntro"] = GLSyncValue.string(packageMessageIntro)
        payload["packageMessageClosing"] = GLSyncValue.string(packageMessageClosing)
        payload["completionMessageSubject"] = GLSyncValue.string(completionMessageSubject)
        payload["completionMessageIntro"] = GLSyncValue.string(completionMessageIntro)
        payload["completionMessageClosing"] = GLSyncValue.string(completionMessageClosing)
        payload["workScheduleData"] = workScheduleObject()
        payload["warrantyText"] = GLSyncValue.string(warrantyText)
        payload["w9Name"] = GLSyncValue.string(w9Name)
        payload["w9TaxClassificationRaw"] = GLSyncValue.raw(w9TaxClassification)
        payload["w9LLCClassification"] = GLSyncValue.string(w9LLCClassification)
        payload["w9OtherClassification"] = GLSyncValue.string(w9OtherClassification)
        payload["w9TINTypeRaw"] = GLSyncValue.raw(w9TINType)
        // w9TIN is NOT here and must never be. See the file header.
        payload["w9ExemptPayeeCode"] = GLSyncValue.string(w9ExemptPayeeCode)
        payload["w9FATCACode"] = GLSyncValue.string(w9FATCACode)
        // Retired-but-live document fields still ride: the bytes exist on real installs, and
        // dropping them from the payload would silently orphan them.
        if wants("proofOfInsuranceData") {
            payload["proofOfInsuranceData"] = GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: proofOfInsuranceData), name: proofOfInsuranceName)
        }
        payload["proofOfInsuranceName"] = GLSyncValue.string(proofOfInsuranceName)
        if wants("wcInsuranceData") {
            payload["wcInsuranceData"] = GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: wcInsuranceData), name: wcInsuranceName)
        }
        payload["wcInsuranceName"] = GLSyncValue.string(wcInsuranceName)
        if wants("wcExemptionData") {
            payload["wcExemptionData"] = GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: wcExemptionData), name: wcExemptionName)
        }
        payload["wcExemptionName"] = GLSyncValue.string(wcExemptionName)
        if wants("licenseDocumentData") {
            payload["licenseDocumentData"] = GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: licenseDocumentData), name: licenseDocumentName)
        }
        payload["licenseDocumentName"] = GLSyncValue.string(licenseDocumentName)
        // Expiry for the two business-scoped compliance documents (2026-09-01).
        payload["wcExemptionExpiresOn"] = GLSyncValue.date(wcExemptionExpiresOn)
        payload["licenseExpiresOn"] = GLSyncValue.date(licenseExpiresOn)
        if wants("ownerReferenceCOIData") {
            payload["ownerReferenceCOIData"] = GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: ownerReferenceCOIData), name: ownerReferenceCOIName)
        }
        payload["ownerReferenceCOIName"] = GLSyncValue.string(ownerReferenceCOIName)
        payload["coiHolderOffsetX"] = GLSyncValue.double(coiHolderOffsetX)
        payload["coiHolderOffsetY"] = GLSyncValue.double(coiHolderOffsetY)
        payload["coiHolderBoxWidth"] = GLSyncValue.double(coiHolderBoxWidth)
        payload["coiCoverExistingHolder"] = GLSyncValue.bool(coiCoverExistingHolder)
        payload["stripeConnectedAccountId"] = GLSyncValue.string(stripeConnectedAccountId)
        payload["stripeChargesEnabled"] = GLSyncValue.bool(stripeChargesEnabled)
        payload["stripeAccountClaim"] = GLSyncValue.string(stripeAccountClaim)
        payload["payLinkInclusionRaw"] = GLSyncValue.raw(payLinkInclusion)
        payload["payLinkDefaultOn"] = GLSyncValue.bool(payLinkDefaultOn)
        payload["zelleTag"] = GLSyncValue.string(zelleTag)
        payload["zelleEmail"] = GLSyncValue.string(zelleEmail)
        payload["zellePhone"] = GLSyncValue.string(zellePhone)
        payload["zelleDefaultOn"] = GLSyncValue.bool(zelleDefaultOn)
        if wants("zelleQRCodeData") {
            payload["zelleQRCodeData"] = GLSyncValue.blobRef(sha256: glSyncBlobHash(for: zelleQRCodeData), name: nil)
        }
        guard let fields else { return payload }
        return payload.filter { fields.contains($0.key) }
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        // Optional scalars read "key present" explicitly, because a patch is partial: an
        // ABSENT key means "not touched", an explicit null means "cleared".
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        businessName = GLSyncValue.string(payload, "businessName", default: businessName)
        ownerFirstName = GLSyncValue.string(payload, "ownerFirstName", default: ownerFirstName)
        ownerLastName = GLSyncValue.string(payload, "ownerLastName", default: ownerLastName)
        phone = GLSyncValue.string(payload, "phone", default: phone)
        email = GLSyncValue.string(payload, "email", default: email)
        websiteURL = GLSyncValue.string(payload, "websiteURL", default: websiteURL)
        reviewsURL = GLSyncValue.string(payload, "reviewsURL", default: reviewsURL)
        includeReviewLinkOnReceipts = GLSyncValue.bool(payload, "includeReviewLinkOnReceipts",
                                                       default: includeReviewLinkOnReceipts)
        licenseNumber = GLSyncValue.string(payload, "licenseNumber", default: licenseNumber)
        address = GLSyncValue.address(payload, "address") ?? address
        showLogoOnDocuments = GLSyncValue.bool(payload, "showLogoOnDocuments", default: showLogoOnDocuments)
        showAddressOnDocuments = GLSyncValue.bool(payload, "showAddressOnDocuments",
                                                   default: showAddressOnDocuments)
        emailSignatureEnabled = GLSyncValue.bool(payload, "emailSignatureEnabled",
                                                 default: emailSignatureEnabled)
        emailSignatureText = GLSyncValue.string(payload, "emailSignatureText",
                                                default: emailSignatureText)
        lastInvoiceNumber = GLSyncValue.int(payload, "lastInvoiceNumber", default: lastInvoiceNumber)
        lastEstimateNumber = GLSyncValue.int(payload, "lastEstimateNumber", default: lastEstimateNumber)
        estimateMessageSubject = GLSyncValue.string(payload, "estimateMessageSubject",
                                                     default: estimateMessageSubject)
        messageIntro = GLSyncValue.string(payload, "messageIntro", default: messageIntro)
        messageClosing = GLSyncValue.string(payload, "messageClosing", default: messageClosing)
        invoiceMessageSubject = GLSyncValue.string(payload, "invoiceMessageSubject",
                                                    default: invoiceMessageSubject)
        invoiceMessageIntro = GLSyncValue.string(payload, "invoiceMessageIntro", default: invoiceMessageIntro)
        invoiceMessageClosing = GLSyncValue.string(payload, "invoiceMessageClosing",
                                                    default: invoiceMessageClosing)
        receiptMessageSubject = GLSyncValue.string(payload, "receiptMessageSubject",
                                                    default: receiptMessageSubject)
        receiptMessageIntro = GLSyncValue.string(payload, "receiptMessageIntro", default: receiptMessageIntro)
        receiptMessageClosing = GLSyncValue.string(payload, "receiptMessageClosing",
                                                    default: receiptMessageClosing)
        changeOrderMessageSubject = GLSyncValue.string(payload, "changeOrderMessageSubject",
                                                        default: changeOrderMessageSubject)
        changeOrderMessageIntro = GLSyncValue.string(payload, "changeOrderMessageIntro",
                                                      default: changeOrderMessageIntro)
        changeOrderMessageClosing = GLSyncValue.string(payload, "changeOrderMessageClosing",
                                                        default: changeOrderMessageClosing)
        packageMessageSubject = GLSyncValue.string(payload, "packageMessageSubject",
                                                    default: packageMessageSubject)
        packageMessageIntro = GLSyncValue.string(payload, "packageMessageIntro", default: packageMessageIntro)
        packageMessageClosing = GLSyncValue.string(payload, "packageMessageClosing",
                                                    default: packageMessageClosing)
        completionMessageSubject = GLSyncValue.string(payload, "completionMessageSubject",
                                                       default: completionMessageSubject)
        completionMessageIntro = GLSyncValue.string(payload, "completionMessageIntro",
                                                     default: completionMessageIntro)
        completionMessageClosing = GLSyncValue.string(payload, "completionMessageClosing",
                                                       default: completionMessageClosing)
        applyWorkScheduleObject(payload)
        warrantyText = GLSyncValue.string(payload, "warrantyText", default: warrantyText)
        w9Name = GLSyncValue.string(payload, "w9Name", default: w9Name)
        // An unknown classification degrades to "not set" rather than failing the record.
        w9TaxClassificationRaw = W9TaxClassification(
            rawValue: GLSyncValue.string(payload, "w9TaxClassificationRaw")
        )?.rawValue ?? ""
        w9LLCClassification = GLSyncValue.string(payload, "w9LLCClassification", default: w9LLCClassification)
        w9OtherClassification = GLSyncValue.string(payload, "w9OtherClassification",
                                                    default: w9OtherClassification)
        w9TINTypeRaw = W9TINType(rawValue: GLSyncValue.string(payload, "w9TINTypeRaw"))?.rawValue ?? ""
        // w9TIN is never read back either — an incoming plaintext TIN is not ours to restore.
        w9ExemptPayeeCode = GLSyncValue.string(payload, "w9ExemptPayeeCode", default: w9ExemptPayeeCode)
        w9FATCACode = GLSyncValue.string(payload, "w9FATCACode", default: w9FATCACode)
        // Blob BYTES are fetched separately by the engine, so only the labels land here. These
        // profile blobs have no hash column to stash the incoming sha256 in, so the Data is
        // left untouched and the attachment fetch reconciles it.
        proofOfInsuranceName = GLSyncValue.string(payload, "proofOfInsuranceName",
                                                   default: proofOfInsuranceName)
        wcInsuranceName = GLSyncValue.string(payload, "wcInsuranceName", default: wcInsuranceName)
        wcExemptionName = GLSyncValue.string(payload, "wcExemptionName", default: wcExemptionName)
        licenseDocumentName = GLSyncValue.string(payload, "licenseDocumentName", default: licenseDocumentName)
        if payload["wcExemptionExpiresOn"] != nil { wcExemptionExpiresOn = GLSyncValue.date(payload, "wcExemptionExpiresOn") }
        if payload["licenseExpiresOn"] != nil { licenseExpiresOn = GLSyncValue.date(payload, "licenseExpiresOn") }
        ownerReferenceCOIName = GLSyncValue.string(payload, "ownerReferenceCOIName",
                                                    default: ownerReferenceCOIName)
        coiHolderOffsetX = GLSyncValue.double(payload, "coiHolderOffsetX", default: coiHolderOffsetX)
        coiHolderOffsetY = GLSyncValue.double(payload, "coiHolderOffsetY", default: coiHolderOffsetY)
        coiHolderBoxWidth = GLSyncValue.double(payload, "coiHolderBoxWidth", default: coiHolderBoxWidth)
        coiCoverExistingHolder = GLSyncValue.bool(payload, "coiCoverExistingHolder",
                                                   default: coiCoverExistingHolder)
        stripeConnectedAccountId = GLSyncValue.string(payload, "stripeConnectedAccountId",
                                                      default: stripeConnectedAccountId)
        stripeChargesEnabled = GLSyncValue.bool(payload, "stripeChargesEnabled", default: stripeChargesEnabled)
        stripeAccountClaim = GLSyncValue.string(payload, "stripeAccountClaim", default: stripeAccountClaim)
        payLinkInclusionRaw = GLSyncValue.raw(payload, "payLinkInclusionRaw",
                                               default: PayLinkInclusion.all).rawValue
        payLinkDefaultOn = GLSyncValue.bool(payload, "payLinkDefaultOn", default: payLinkDefaultOn)
        zelleTag = GLSyncValue.string(payload, "zelleTag", default: zelleTag)
        zelleEmail = GLSyncValue.string(payload, "zelleEmail", default: zelleEmail)
        zellePhone = GLSyncValue.string(payload, "zellePhone", default: zellePhone)
        zelleDefaultOn = GLSyncValue.bool(payload, "zelleDefaultOn", default: zelleDefaultOn)
    }

    /// `workScheduleData` is the ONE inline blob (GLSYNC-SPEC §6): a small structured config,
    /// not an attachment, so it rides as a JSON OBJECT the server can read and merge. Decoded
    /// and re-encoded rather than passed through raw, so a payload can never carry bytes that
    /// no longer parse as the current `WorkSchedule` shape.
    private func workScheduleObject() -> Any {
        guard let stored = workScheduleData,
              let decoded = try? JSONDecoder().decode(WorkSchedule.self, from: stored),
              let encoded = try? JSONEncoder().encode(decoded),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? GLSyncPayload
        else { return NSNull() }   // nil or unparseable: send null, never the derived default
        return object
    }

    private func applyWorkScheduleObject(_ payload: GLSyncPayload) {
        if let object = payload["workScheduleData"] as? GLSyncPayload,
           let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? JSONDecoder().decode(WorkSchedule.self, from: data) {
            workScheduleData = try? JSONEncoder().encode(decoded)
        } else if payload["workScheduleData"] is NSNull {
            workScheduleData = nil
        }
    }
}

// MARK: - UserProfile

extension UserProfile: GLSyncMappable {

    static var glSyncType: String { "user_profile" }

    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    /// App settings only. The person's name, contact, address, photo and signature live in
    /// the Gold Life ID alone (law 48; audit 2026-10-03 F19): they are never sent, and a pulled
    /// row that still carries them (one stored before the change) never writes them back.
    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "useMyNameInEmails": GLSyncValue.bool(useMyNameInEmails),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        useMyNameInEmails = GLSyncValue.bool(payload, "useMyNameInEmails",
                                             default: useMyNameInEmails)
    }
}

// MARK: - PaymentProcessor

extension PaymentProcessor: GLSyncMappable {

    /// RETIRED model, live rows — still mapped so existing fee history migrates intact.
    static var glSyncType: String { "payment_processor" }

    /// Cascade child of the business profile (manifest `parent: "business_profile"`).
    var glSyncParentID: UUID? { businessProfile?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "feePercent": GLSyncValue.double(feePercent),
            "flatFee": GLSyncValue.double(flatFee),
            "createdAt": GLSyncValue.date(createdAt),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        name = GLSyncValue.string(payload, "name", default: name)
        feePercent = GLSyncValue.double(payload, "feePercent", default: feePercent)
        flatFee = GLSyncValue.double(payload, "flatFee", default: flatFee)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // `businessProfile` is the cascade parent: it travels in the envelope, so the engine
        // owns the link, not this mapper.
    }
}

// MARK: - ScheduledJob

extension ScheduledJob: GLSyncMappable {

    static var glSyncType: String { "scheduled_job" }

    /// No cascade parent (manifest `parent: null`). The customer/estimate/invoice/project
    /// links all NULLIFY, so they are ordinary payload fields below.
    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "title": GLSyncValue.string(title),
            // A deliberate snapshot: it outlives the customer record it was copied from.
            "customerName": GLSyncValue.string(customerName),
            "startDate": GLSyncValue.date(startDate),
            "durationDays": GLSyncValue.int(durationDays),
            "notes": GLSyncValue.string(notes),
            "createdAt": GLSyncValue.date(createdAt),
            "statusRaw": GLSyncValue.raw(status),
            "completedAt": GLSyncValue.date(completedAt),
            "serviceAddress": GLSyncValue.address(serviceAddress),
            "agreedPrice": GLSyncValue.optional(agreedPrice),
            "isAllDay": GLSyncValue.bool(isAllDay),
            "startTime": GLSyncValue.date(startTime),
            "durationMinutes": GLSyncValue.optional(durationMinutes),
            "recurrenceFrequencyRaw": GLSyncValue.raw(recurrenceFrequency),
            "recurrenceWeekdayMask": GLSyncValue.int(recurrenceWeekdayMask),
            "recurrenceEndDate": GLSyncValue.date(recurrenceEndDate),
            "recurrenceCount": GLSyncValue.int(recurrenceCount),
            // Nullify references, not parents: each carries the referent's syncID.
            "customer": GLSyncValue.uuid(customer?.syncID),
            "estimate": GLSyncValue.uuid(estimate?.syncID),
            "invoice": GLSyncValue.uuid(invoice?.syncID),
            "project": GLSyncValue.uuid(project?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        title = GLSyncValue.string(payload, "title", default: title)
        customerName = GLSyncValue.string(payload, "customerName", default: customerName)
        startDate = GLSyncValue.date(payload, "startDate") ?? startDate
        durationDays = GLSyncValue.int(payload, "durationDays", default: durationDays)
        notes = GLSyncValue.string(payload, "notes", default: notes)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        statusRaw = GLSyncValue.raw(payload, "statusRaw", default: JobStatus.scheduled).rawValue
        if payload["completedAt"] != nil { completedAt = GLSyncValue.date(payload, "completedAt") }
        serviceAddress = GLSyncValue.address(payload, "serviceAddress") ?? serviceAddress
        if payload["agreedPrice"] != nil { agreedPrice = GLSyncValue.optionalDouble(payload, "agreedPrice") }
        isAllDay = GLSyncValue.bool(payload, "isAllDay", default: isAllDay)
        if payload["startTime"] != nil { startTime = GLSyncValue.date(payload, "startTime") }
        if payload["durationMinutes"] != nil {
            durationMinutes = GLSyncValue.optionalInt(payload, "durationMinutes")
        }
        // An unknown frequency degrades to "one-off", which is the empty-string default.
        recurrenceFrequencyRaw = RecurrenceFrequency(
            rawValue: GLSyncValue.string(payload, "recurrenceFrequencyRaw")
        )?.rawValue ?? ""
        recurrenceWeekdayMask = GLSyncValue.int(payload, "recurrenceWeekdayMask",
                                                 default: recurrenceWeekdayMask)
        if payload["recurrenceEndDate"] != nil {
            recurrenceEndDate = GLSyncValue.date(payload, "recurrenceEndDate")
        }
        recurrenceCount = GLSyncValue.int(payload, "recurrenceCount", default: recurrenceCount)
        // Each reference resolves against the local store by syncID. A referent that has not
        // been pulled yet leaves the link nil; a later pull carries it and the next patch
        // re-links. Never invent a local row for a dangling id.
        if payload["customer"] != nil {
            customer = BusinessMapperLookup.customer(GLSyncValue.uuid(payload, "customer"), in: context)
        }
        if payload["estimate"] != nil {
            estimate = BusinessMapperLookup.estimate(GLSyncValue.uuid(payload, "estimate"), in: context)
        }
        if payload["invoice"] != nil {
            invoice = BusinessMapperLookup.invoice(GLSyncValue.uuid(payload, "invoice"), in: context)
        }
        if payload["project"] != nil {
            project = BusinessMapperLookup.project(GLSyncValue.uuid(payload, "project"), in: context)
        }
    }
}

// MARK: - JobAttachment

extension JobAttachment: GLSyncMappable {

    static var glSyncType: String { "job_attachment" }

    /// Cascade child of its job (manifest `parent: "scheduled_job"`) — these belong to the
    /// job, unlike receipts, which outlive it.
    var glSyncParentID: UUID? { job?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            // `name` rides twice on purpose: inside the blob reference as the attachment's
            // label, and as its own key because it is a separate stored property.
            "data": GLSyncValue.blobRef(sha256: glSyncBlobHash(for: data), name: name),
            "name": GLSyncValue.string(name),
            "caption": GLSyncValue.string(caption),
            "createdAt": GLSyncValue.date(createdAt),
            "kindRaw": GLSyncValue.raw(kind),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        // Only the label lands here: the bytes come from the engine's attachment fetch, and
        // there is no hash column on this model to park the incoming sha256 in.
        name = GLSyncValue.string(payload, "name", default: name)
        caption = GLSyncValue.string(payload, "caption", default: caption)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        kindRaw = GLSyncValue.raw(payload, "kindRaw", default: JobAttachmentKind.photo).rawValue
        // `job` is the cascade parent: it travels in the envelope, so the engine owns the link.
    }
}

// MARK: - Audit

// The exact payload keys each type emits, in emit order. The round-trip / property-count
// guard (GLSYNC-SPEC §8) reads this instead of re-deriving the list, so adding a stored
// property without adding it here is what makes the suite fail.
//
// `GLSyncMapperAudit` itself is the shared namespace across the mapper files; this file only
// extends it.
extension GLSyncMapperAudit {

    nonisolated static let businessProperties: [String: [String]] = [
        "business_profile": [
            "syncID", "updatedAt", "businessName", "ownerFirstName", "ownerLastName", "phone", "email",
            "websiteURL", "reviewsURL", "includeReviewLinkOnReceipts", "licenseNumber", "address",
            "logoData", "logoDataDark", "showLogoOnDocuments", "showAddressOnDocuments",
            "emailSignatureEnabled", "emailSignatureText",
            "lastInvoiceNumber", "lastEstimateNumber", "estimateMessageSubject", "messageIntro",
            "messageClosing", "invoiceMessageSubject", "invoiceMessageIntro", "invoiceMessageClosing",
            "receiptMessageSubject", "receiptMessageIntro", "receiptMessageClosing",
            "changeOrderMessageSubject", "changeOrderMessageIntro", "changeOrderMessageClosing",
            "packageMessageSubject", "packageMessageIntro", "packageMessageClosing",
            "completionMessageSubject", "completionMessageIntro", "completionMessageClosing",
            "workScheduleData", "warrantyText", "w9Name", "w9TaxClassificationRaw",
            "w9LLCClassification", "w9OtherClassification", "w9TINTypeRaw", "w9ExemptPayeeCode",
            "w9FATCACode", "proofOfInsuranceData", "proofOfInsuranceName", "wcInsuranceData",
            "wcInsuranceName", "wcExemptionData", "wcExemptionName", "licenseDocumentData",
            "licenseDocumentName", "wcExemptionExpiresOn", "licenseExpiresOn",
            "ownerReferenceCOIData", "ownerReferenceCOIName",
            "coiHolderOffsetX", "coiHolderOffsetY", "coiHolderBoxWidth", "coiCoverExistingHolder",
            "stripeConnectedAccountId", "stripeChargesEnabled", "stripeAccountClaim",
            "payLinkInclusionRaw", "payLinkDefaultOn",
            "zelleTag", "zelleEmail", "zellePhone", "zelleQRCodeData", "zelleDefaultOn",
        ],
        "user_profile": [
            "syncID", "updatedAt", "useMyNameInEmails",
        ],
        "payment_processor": [
            "syncID", "updatedAt", "name", "feePercent", "flatFee", "createdAt",
        ],
        "scheduled_job": [
            "syncID", "updatedAt", "title", "customerName", "startDate", "durationDays", "notes", "createdAt",
            "statusRaw", "completedAt", "serviceAddress", "agreedPrice", "isAllDay", "startTime",
            "durationMinutes", "recurrenceFrequencyRaw", "recurrenceWeekdayMask", "recurrenceEndDate",
            "recurrenceCount", "customer", "estimate", "invoice", "project",
        ],
        "job_attachment": [
            "syncID", "updatedAt", "data", "name", "caption", "createdAt", "kindRaw",
        ],
    ]
}
