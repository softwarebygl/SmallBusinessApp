//
//  ContactMappers.swift
//  GLSmallBusiness
//
//  GLSync payload mappers for the customer-side records: the customer, the extra documents
//  in that customer's Contractor Package, their expense receipts, and the projects that
//  group their jobs. See GLSYNC-SPEC.md §6 for the rules and
//  gl-business-api/sync-manifest.json for the server's per-type enforcement — every
//  `glSyncType` below is a manifest key, spelled exactly as the manifest spells it.
//
//  Payload keys are the SWIFT property names verbatim, so the manifest's protected /
//  max_merge / write_once / strip_fields lists match with no translation table in between.
//  Hand-written on purpose (the no-AI-contingency rule): the regression net is the
//  round-trip test plus the property audit at the bottom of this file.
//

import CryptoKit
import Foundation
import SwiftData

// MARK: - Shared file utilities

/// SHA-256 hex of a blob's bytes. Attachment bytes never ride in a payload (GLSYNC-SPEC §6):
/// the hash identifies the object in R2 and the engine ships the bytes separately, which is
/// also what makes a re-sent record cheap — same bytes, same hash, no second upload.
///
/// `private` rather than internal deliberately: one copy of this helper lives in every mapper
/// file, and a module-scope copy per file would be a duplicate declaration.
private nonisolated func glSyncBlobHash(for data: Data?) -> String? {
    // `!data.isEmpty` is load-bearing, not defensive: GLSyncRegistry.blobBytes filters empty
    // blobs OUT of the upload, so hashing one here would put a {sha256} reference in the
    // payload pointing at bytes that never reach R2 — a document every other device then
    // fails to fetch. Two of the three copies of this helper were missing it (found by
    // GLSyncMappingTests' blob-consistency check, 2026-08-23).
    guard let data, !data.isEmpty else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Resolve a nullify-style reference (a payload uuid) to a local job.
///
/// A missing referent is NOT an error: parents and children arrive in whatever order the
/// server pages them, so an unresolved id means "not on this device yet". Leave the link nil
/// and let a later pull re-apply the payload once the job exists — never fabricate a row.
private func glSyncScheduledJob(_ id: UUID?, in context: ModelContext) -> ScheduledJob? {
    guard id != nil else { return nil }
    var descriptor = FetchDescriptor<ScheduledJob>(
        predicate: #Predicate<ScheduledJob> { $0.syncID == id })
    descriptor.fetchLimit = 1
    return (try? context.fetch(descriptor))?.first
}

// MARK: - Customer

extension Customer: GLSyncMappable {

    static var glSyncType: String { "customer" }

    /// A root record — the manifest says `parent: null`. Everything that cascades off a
    /// customer points at THIS id instead.
    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "firstName": GLSyncValue.string(firstName),
            "middleName": GLSyncValue.string(middleName),
            "lastName": GLSyncValue.string(lastName),
            "email": GLSyncValue.string(email),
            "phoneNumber": GLSyncValue.string(phoneNumber),
            "officePhone": GLSyncValue.string(officePhone),
            "businessName": GLSyncValue.optional(businessName),
            // An object, never flattened columns — the server stores it whole.
            "address": GLSyncValue.address(address),
            "createdAt": GLSyncValue.date(createdAt),
            // The three blobs ride as {sha256, name} references. The COIs carry their own
            // label inside the reference AND as their own key, because `coiName` /
            // `wcCoiName` are separate stored properties the server has to keep.
            "profileImageData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: profileImageData), name: nil),
            "coiData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: coiData), name: coiName),
            "coiName": GLSyncValue.string(coiName),
            "wcCoiData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: wcCoiData), name: wcCoiName),
            "wcCoiName": GLSyncValue.string(wcCoiName),
            // Certificate expiry (2026-09-01). Plain optional dates, so the server
            // stores them like any other nullable scalar.
            "coiExpiresOn": GLSyncValue.date(coiExpiresOn),
            "wcCoiExpiresOn": GLSyncValue.date(wcCoiExpiresOn),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        updatedAt = GLSyncValue.date(payload, "updatedAt") ?? updatedAt
        firstName = GLSyncValue.string(payload, "firstName", default: firstName)
        middleName = GLSyncValue.string(payload, "middleName", default: middleName)
        lastName = GLSyncValue.string(payload, "lastName", default: lastName)
        email = GLSyncValue.string(payload, "email", default: email)
        phoneNumber = GLSyncValue.string(payload, "phoneNumber", default: phoneNumber)
        officePhone = GLSyncValue.string(payload, "officePhone", default: officePhone)
        // Presence, not value: an ABSENT key leaves the local value alone, an explicit null
        // clears it. Same rule the scalar read helpers get for free from their defaults.
        if payload["businessName"] != nil {
            businessName = GLSyncValue.optionalString(payload, "businessName")
        }
        address = GLSyncValue.address(payload, "address") ?? address
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // Blob BYTES are never applied here — the engine fetches attachments separately and
        // fills the `Data` in. Only the labels are the mapper's business; Customer has
        // nowhere to park an incoming sha256, so the hash stays the engine's bookkeeping.
        coiName = GLSyncValue.string(payload, "coiName", default: coiName)
        wcCoiName = GLSyncValue.string(payload, "wcCoiName", default: wcCoiName)
        if payload["coiExpiresOn"] != nil { coiExpiresOn = GLSyncValue.date(payload, "coiExpiresOn") }
        if payload["wcCoiExpiresOn"] != nil { wcCoiExpiresOn = GLSyncValue.date(payload, "wcCoiExpiresOn") }
    }
}

// MARK: - CustomerDocument

extension CustomerDocument: GLSyncMappable {

    static var glSyncType: String { "customer_document" }

    /// Cascade parent (manifest `parent: "customer"`): these extras were added for one
    /// customer's package and mean nothing without it. The link rides in the envelope as the
    /// parent id, which is why `customer` is not a payload key.
    var glSyncParentID: UUID? { customer?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "data": GLSyncValue.blobRef(sha256: glSyncBlobHash(for: data), name: name),
            "name": GLSyncValue.string(name),
            "createdAt": GLSyncValue.date(createdAt),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        updatedAt = GLSyncValue.date(payload, "updatedAt") ?? updatedAt
        // The filename is a real stored property, so it comes from its own key; the bytes
        // arrive later through /attachments and are never written from a payload.
        name = GLSyncValue.string(payload, "name", default: name)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
    }
}

// MARK: - Receipt

extension Receipt: GLSyncMappable {

    static var glSyncType: String { "receipt" }

    /// Cascade parent (manifest `parent: "customer"`). The `job` link is a NULLIFY reference,
    /// not the parent — a receipt is a financial record that outlives the job it was bought
    /// for — so it rides in the payload as an ordinary uuid field below.
    var glSyncParentID: UUID? { customer?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "vendor": GLSyncValue.string(vendor),
            "date": GLSyncValue.date(date),
            // Money as entered. `total` is server-protected: contested, never auto-merged.
            "total": GLSyncValue.double(total),
            "category": GLSyncValue.string(category),
            "notes": GLSyncValue.string(notes),
            "recognizedText": GLSyncValue.string(recognizedText),
            "createdAt": GLSyncValue.date(createdAt),
            "scanData": GLSyncValue.blobRef(sha256: glSyncBlobHash(for: scanData), name: nil),
            "job": GLSyncValue.uuid(job?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        updatedAt = GLSyncValue.date(payload, "updatedAt") ?? updatedAt
        vendor = GLSyncValue.string(payload, "vendor", default: vendor)
        date = GLSyncValue.date(payload, "date") ?? date
        total = GLSyncValue.double(payload, "total", default: total)
        category = GLSyncValue.string(payload, "category", default: category)
        notes = GLSyncValue.string(payload, "notes", default: notes)
        recognizedText = GLSyncValue.string(payload, "recognizedText", default: recognizedText)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // The scan bytes come from /attachments; Receipt has no field for their hash, so
        // nothing about `scanData` is applied here.
        //
        // The job link resolves to whatever is already local: an id we have not pulled yet
        // leaves it nil on purpose and a later pull re-applies this payload.
        if payload["job"] != nil {
            job = glSyncScheduledJob(GLSyncValue.uuid(payload, "job"), in: context)
        }
    }
}

// MARK: - Project

extension Project: GLSyncMappable {

    static var glSyncType: String { "project" }

    /// The manifest declares `customer` as the parent with `parent_delete: "nullify"` — the
    /// project survives its customer's deletion and simply loses the link, matching the local
    /// nullify rule on `Project.customer`. Still the parent, so still the envelope's id.
    var glSyncParentID: UUID? { customer?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "name": GLSyncValue.string(name),
            "createdAt": GLSyncValue.date(createdAt),
            // The signed master agreement: reference in the payload, bytes in R2. Its label
            // rides inside the reference and as its own key (a separate stored property).
            "masterAgreementData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: masterAgreementData), name: masterAgreementName),
            "masterAgreementName": GLSyncValue.string(masterAgreementName),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let incoming = GLSyncValue.uuid(payload, "syncID") { syncID = incoming }
        updatedAt = GLSyncValue.date(payload, "updatedAt") ?? updatedAt
        name = GLSyncValue.string(payload, "name", default: name)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // Label only — the agreement's bytes and hash are the engine's attachment business.
        masterAgreementName = GLSyncValue.string(
            payload, "masterAgreementName", default: masterAgreementName)
    }
}

// MARK: - Property audit
//
// The exact payload keys each mapper in this file emits, in emission order. The round-trip /
// property-count test reads this rather than reflecting over the mappers, so adding a stored
// property to one of these @Models without mapping it fails the suite loudly
// (GLSYNC-SPEC.md §8). Keep a key here only while `glSyncPayload()` actually writes it.

extension GLSyncMapperAudit {

    nonisolated static let contactProperties: [String: [String]] = [
        "customer": [
            "syncID", "updatedAt", "firstName", "middleName", "lastName", "email",
            "phoneNumber", "officePhone", "businessName", "address", "createdAt",
            "profileImageData", "coiData", "coiName", "wcCoiData", "wcCoiName",
            "coiExpiresOn", "wcCoiExpiresOn",
        ],
        "customer_document": [
            "syncID", "updatedAt", "data", "name", "createdAt",
        ],
        "receipt": [
            "syncID", "updatedAt", "vendor", "date", "total", "category", "notes",
            "recognizedText", "createdAt", "scanData", "job",
        ],
        "project": [
            "syncID", "updatedAt", "name", "createdAt", "masterAgreementData",
            "masterAgreementName",
        ],
    ]
}
