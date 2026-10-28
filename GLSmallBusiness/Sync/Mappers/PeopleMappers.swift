//
//  PeopleMappers.swift
//  GLSmallBusiness
//
//  GLSync payload mappers for the people side of the app: employees, the hours they log, the
//  paychecks that settle those hours, subcontractors, and their ledger entries. See
//  GLSYNC-SPEC.md §6 for the rules and gl-business-api/sync-manifest.json for the server's
//  per-type enforcement — the `glSyncType` strings below are that file's keys, verbatim.
//
//  Conventions these five mappers share (why, not what):
//  - Payload keys are the SWIFT property names, so the manifest's protected / write_once /
//    max_merge lists line up without a translation table someone could get wrong later.
//  - The CASCADE parent (an entry's employee, a payment's subcontractor) rides as
//    `glSyncParentID` — the server keys it as its own column, so repeating it in the payload
//    would give one edge two sources of truth. Nullify-style links (a time entry's customer or
//    paycheck, a sub payment's customer) are ordinary payload fields carrying the referent's id.
//  - To-many relationships are never emitted: they are the inverse of a child's own reference,
//    and the CHILD row carries the link.
//  - Reads pass the CURRENT value as the fallback, and nullable fields are guarded on key
//    presence, because a coalesced patch (GLSYNC-SPEC §2) carries only the fields that changed:
//    an ABSENT key must leave its property alone, an explicit null must clear it.
//

import CryptoKit
import Foundation
import SwiftData

// MARK: - Blob hashing

/// SHA-256 hex of an attachment's bytes. The bytes go to `/attachments` (content-addressed) and
/// only this digest plus a label ride in the payload, so a 4 MB photo never inflates a sync chunk.
/// File-scope `private` deliberately: every mapper group needs this same one-liner, and a shared
/// internal symbol would collide across the mapper files.
private nonisolated func glSyncBlobHash(for data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Reference resolution
//
// Incoming links arrive as the referent's `syncID`. A referent that has not been pulled yet
// resolves to nil and the relationship is left unset — the next pull carries it, and a briefly
// missing nullify-style link is a state the app already handles everywhere.

private func glSyncFetchOne<T: PersistentModel>(
    _ predicate: Predicate<T>, in context: ModelContext
) -> T? {
    var descriptor = FetchDescriptor<T>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}

private func glSyncCustomer(_ id: UUID?, in context: ModelContext) -> Customer? {
    guard let id else { return nil }
    let target: UUID? = id   // matched against an OPTIONAL column, so the operand stays optional
    return glSyncFetchOne(#Predicate<Customer> { $0.syncID == target }, in: context)
}

private func glSyncEmployee(_ id: UUID?, in context: ModelContext) -> Employee? {
    guard let id else { return nil }
    let target: UUID? = id
    return glSyncFetchOne(#Predicate<Employee> { $0.syncID == target }, in: context)
}

private func glSyncPaycheck(_ id: UUID?, in context: ModelContext) -> Paycheck? {
    guard let id else { return nil }
    let target: UUID? = id
    return glSyncFetchOne(#Predicate<Paycheck> { $0.syncID == target }, in: context)
}

private func glSyncSubcontractor(_ id: UUID?, in context: ModelContext) -> Subcontractor? {
    guard let id else { return nil }
    let target: UUID? = id
    return glSyncFetchOne(#Predicate<Subcontractor> { $0.syncID == target }, in: context)
}

// MARK: - Employee

extension Employee: GLSyncMappable {

    static var glSyncType: String { "employee" }

    /// Top-level record — an employee is nobody's cascade child (manifest `employee.parent: null`).
    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    /// `timeEntries` and `paychecks` are absent on purpose: both are to-many inverses, and each
    /// child ships its own parent link.
    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "firstName": GLSyncValue.string(firstName),
            "lastName": GLSyncValue.string(lastName),
            "email": GLSyncValue.string(email),
            "phone": GLSyncValue.string(phone),
            "payType": GLSyncValue.raw(payType),
            "hourlyRate": GLSyncValue.double(hourlyRate),
            "annualSalary": GLSyncValue.double(annualSalary),
            "payFrequency": GLSyncValue.raw(payFrequency),
            "anchorPayday": GLSyncValue.date(anchorPayday),
            "hireDate": GLSyncValue.date(hireDate),
            "isActive": GLSyncValue.bool(isActive),
            "notes": GLSyncValue.string(notes),
            "createdAt": GLSyncValue.date(createdAt),
            "profileImageData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: profileImageData), name: nil
            ),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        firstName = GLSyncValue.string(payload, "firstName", default: firstName)
        lastName = GLSyncValue.string(payload, "lastName", default: lastName)
        email = GLSyncValue.string(payload, "email", default: email)
        phone = GLSyncValue.string(payload, "phone", default: phone)
        // Enums: an ABSENT key leaves the value alone; a present-but-unknown one degrades to the
        // model's own default rather than failing the record (GLSYNC-SPEC §6).
        if payload["payType"] != nil {
            payType = GLSyncValue.raw(payload, "payType", default: PayType.hourly)
        }
        hourlyRate = GLSyncValue.double(payload, "hourlyRate", default: hourlyRate)
        annualSalary = GLSyncValue.double(payload, "annualSalary", default: annualSalary)
        if payload["payFrequency"] != nil {
            payFrequency = GLSyncValue.raw(payload, "payFrequency", default: PayFrequency.weekly)
        }
        anchorPayday = GLSyncValue.date(payload, "anchorPayday") ?? anchorPayday
        hireDate = GLSyncValue.date(payload, "hireDate") ?? hireDate
        isActive = GLSyncValue.bool(payload, "isActive", default: isActive)
        notes = GLSyncValue.string(payload, "notes", default: notes)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // profileImageData: the engine fetches attachment bytes separately, and Employee carries
        // no companion name or hash column to stash the reference in — so there is nothing to
        // apply here and the local bytes are left untouched.
    }
}

// MARK: - Time entry

extension TimeEntry: GLSyncMappable {

    static var glSyncType: String { "time_entry" }

    /// The employee is the CASCADE parent (manifest `time_entry.parent`). `customer` and
    /// `paycheck` NULLIFY instead, so they ride in the payload as plain ids.
    var glSyncParentID: UUID? { employee?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "date": GLSyncValue.date(date),
            "hours": GLSyncValue.double(hours),
            "note": GLSyncValue.string(note),
            "rateSnapshot": GLSyncValue.double(rateSnapshot),
            "amount": GLSyncValue.double(amount),
            "customer": GLSyncValue.uuid(customer?.syncID),
            "paycheck": GLSyncValue.uuid(paycheck?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        date = GLSyncValue.date(payload, "date") ?? date
        hours = GLSyncValue.double(payload, "hours", default: hours)
        note = GLSyncValue.string(payload, "note", default: note)
        rateSnapshot = GLSyncValue.double(payload, "rateSnapshot", default: rateSnapshot)
        amount = GLSyncValue.double(payload, "amount", default: amount)
        // References resolve by syncID; a referent this device has not pulled yet leaves the link
        // nil and a later pull fixes it — an unlinked entry simply reads as untagged/unpaid.
        if payload["customer"] != nil {
            customer = glSyncCustomer(GLSyncValue.uuid(payload, "customer"), in: context)
        }
        if payload["paycheck"] != nil {
            paycheck = glSyncPaycheck(GLSyncValue.uuid(payload, "paycheck"), in: context)
        }
        // The cascade parent normally arrives out-of-band as the op's parent_id, but honor it when
        // the engine folds it into the payload — otherwise a pulled entry could never find its
        // employee and would surface as an orphan in Log Hours.
        if payload["employee"] != nil {
            employee = glSyncEmployee(GLSyncValue.uuid(payload, "employee"), in: context)
        }
    }
}

// MARK: - Paycheck

extension Paycheck: GLSyncMappable {

    static var glSyncType: String { "paycheck" }

    var glSyncParentID: UUID? { employee?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    /// `coveredEntries` is absent on purpose: it is the to-many inverse of `TimeEntry.paycheck`,
    /// which each entry already ships. Emitting both would let one settlement edge be decided
    /// twice, in two different ops, with no rule for which wins.
    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "payPeriodStart": GLSyncValue.date(payPeriodStart),
            "payPeriodEnd": GLSyncValue.date(payPeriodEnd),
            "payDate": GLSyncValue.date(payDate),
            "grossAmount": GLSyncValue.double(grossAmount),
            "hoursPaid": GLSyncValue.double(hoursPaid),
            "method": GLSyncValue.raw(method),
            "note": GLSyncValue.string(note),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        payPeriodStart = GLSyncValue.date(payload, "payPeriodStart") ?? payPeriodStart
        payPeriodEnd = GLSyncValue.date(payload, "payPeriodEnd") ?? payPeriodEnd
        payDate = GLSyncValue.date(payload, "payDate") ?? payDate
        grossAmount = GLSyncValue.double(payload, "grossAmount", default: grossAmount)
        hoursPaid = GLSyncValue.double(payload, "hoursPaid", default: hoursPaid)
        // `.other` is the shipped degrade target for an unrecognized payment method.
        if payload["method"] != nil {
            method = GLSyncValue.raw(payload, "method", default: PaymentMethod.other)
        }
        note = GLSyncValue.string(payload, "note", default: note)
        // See TimeEntry: the parent normally rides out-of-band, honored here when it does not.
        if payload["employee"] != nil {
            employee = glSyncEmployee(GLSyncValue.uuid(payload, "employee"), in: context)
        }
    }
}

// MARK: - Subcontractor

extension Subcontractor: GLSyncMappable {

    static var glSyncType: String { "subcontractor" }

    var glSyncParentID: UUID? { nil }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    /// `w9Name` rides twice on purpose: inside the `w9Data` reference as the attachment's label,
    /// and under its own key because it is a separate stored property the user can edit without
    /// ever touching the bytes.
    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "firstName": GLSyncValue.string(firstName),
            "lastName": GLSyncValue.string(lastName),
            "businessName": GLSyncValue.string(businessName),
            "email": GLSyncValue.string(email),
            "phone": GLSyncValue.string(phone),
            "hourlyRate": GLSyncValue.double(hourlyRate),
            "address": GLSyncValue.address(address),
            "isActive": GLSyncValue.bool(isActive),
            "notes": GLSyncValue.string(notes),
            "createdAt": GLSyncValue.date(createdAt),
            "profileImageData": GLSyncValue.blobRef(
                sha256: glSyncBlobHash(for: profileImageData), name: nil
            ),
            "tinKey": GLSyncValue.string(tinKey),
            "w9TINTypeRaw": GLSyncValue.raw(w9TINType),
            "w9Data": GLSyncValue.blobRef(sha256: glSyncBlobHash(for: w9Data), name: w9Name),
            "w9Name": GLSyncValue.string(w9Name),
            // Their certificate of insurance (2026-09-01), same shape as the
            // customer's: the blob rides as a {sha256, name} reference and the
            // label is its own key, because `coiName` is a stored property too.
            "coiData": GLSyncValue.blobRef(sha256: glSyncBlobHash(for: coiData), name: coiName),
            "coiName": GLSyncValue.string(coiName),
            "coiExpiresOn": GLSyncValue.date(coiExpiresOn),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        firstName = GLSyncValue.string(payload, "firstName", default: firstName)
        lastName = GLSyncValue.string(payload, "lastName", default: lastName)
        businessName = GLSyncValue.string(payload, "businessName", default: businessName)
        email = GLSyncValue.string(payload, "email", default: email)
        phone = GLSyncValue.string(payload, "phone", default: phone)
        hourlyRate = GLSyncValue.double(payload, "hourlyRate", default: hourlyRate)
        address = GLSyncValue.address(payload, "address") ?? address
        isActive = GLSyncValue.bool(payload, "isActive", default: isActive)
        notes = GLSyncValue.string(payload, "notes", default: notes)
        createdAt = GLSyncValue.date(payload, "createdAt") ?? createdAt
        // tinKey is the device-Keychain join key and is WRITE-ONCE: overwriting a live key orphans
        // the stored TIN with no plaintext anywhere to recover it from. Fill an empty one only.
        if tinKey.isEmpty {
            tinKey = GLSyncValue.string(payload, "tinKey", default: tinKey)
        }
        if payload["w9TINTypeRaw"] != nil {
            // An unrecognized type degrades to "none on file" rather than persisting a value no
            // shipped build can render — the same rule the enums follow.
            w9TINType = GLSyncValue.optionalString(payload, "w9TINTypeRaw")
                .flatMap(W9TINType.init(rawValue:))
        }
        // The W-9 label is a stored property in its own right, so it applies even though the bytes
        // behind `w9Data` are fetched separately by the engine and left untouched here.
        w9Name = GLSyncValue.string(payload, "w9Name", default: w9Name)
        coiName = GLSyncValue.string(payload, "coiName", default: coiName)
        if payload["coiExpiresOn"] != nil { coiExpiresOn = GLSyncValue.date(payload, "coiExpiresOn") }
        // profileImageData / w9Data: attachment bytes are the engine's job; Subcontractor has no
        // column to stash an incoming hash in, so only the name above is applied.
    }
}

// MARK: - Sub payment

extension SubPayment: GLSyncMappable {

    static var glSyncType: String { "sub_payment" }

    /// The subcontractor is the CASCADE parent (manifest `sub_payment.parent`); `customer`
    /// nullifies, so the job tag rides in the payload and the ledger entry survives the customer.
    var glSyncParentID: UUID? { subcontractor?.syncID }

    var glSyncID: UUID? {
        get { syncID }
        set { syncID = newValue }
    }

    func glSyncPayload() -> GLSyncPayload {
        [
            "syncID": GLSyncValue.uuid(syncID),
            "updatedAt": GLSyncValue.date(updatedAt),
            "amount": GLSyncValue.double(amount),
            "hours": GLSyncValue.double(hours),
            "date": GLSyncValue.date(date),
            "paidDate": GLSyncValue.date(paidDate),
            "method": GLSyncValue.raw(method),
            "detail": GLSyncValue.string(detail),
            "customer": GLSyncValue.uuid(customer?.syncID),
        ]
    }

    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext) {
        if let id = GLSyncValue.uuid(payload, "syncID") { syncID = id }
        if payload["updatedAt"] != nil { updatedAt = GLSyncValue.date(payload, "updatedAt") }
        amount = GLSyncValue.double(payload, "amount", default: amount)
        hours = GLSyncValue.double(payload, "hours", default: hours)
        date = GLSyncValue.date(payload, "date") ?? date
        // paidDate nil means "still owed" and the app lets that flip back and forth, so an explicit
        // null here has to clear it — hence the presence guard rather than a plain read.
        if payload["paidDate"] != nil { paidDate = GLSyncValue.date(payload, "paidDate") }
        if payload["method"] != nil {
            method = GLSyncValue.raw(payload, "method", default: PaymentMethod.other)
        }
        detail = GLSyncValue.string(payload, "detail", default: detail)
        if payload["customer"] != nil {
            customer = glSyncCustomer(GLSyncValue.uuid(payload, "customer"), in: context)
        }
        // See TimeEntry: the parent normally rides out-of-band, honored here when it does not.
        if payload["subcontractor"] != nil {
            subcontractor = glSyncSubcontractor(
                GLSyncValue.uuid(payload, "subcontractor"), in: context
            )
        }
    }
}

// MARK: - Property audit
//
// The exact payload keys each mapper above emits, consumed by the round-trip / property-count
// guard (GLSYNC-SPEC.md §8): add a stored property to one of these @Models without mapping it and
// the suite fails, instead of the field silently never reaching the server.
//
// `GLSyncMapperAudit` is declared once for the whole mapper set; each group file only extends it.

extension GLSyncMapperAudit {

    nonisolated static let peopleProperties: [String: [String]] = [
        "employee": [
            "syncID", "updatedAt", "firstName", "lastName", "email", "phone",
            "payType", "hourlyRate", "annualSalary", "payFrequency", "anchorPayday",
            "hireDate", "isActive", "notes", "createdAt", "profileImageData",
        ],
        "time_entry": [
            "syncID", "updatedAt", "date", "hours", "note", "rateSnapshot", "amount",
            "customer", "paycheck",
        ],
        "paycheck": [
            "syncID", "updatedAt", "payPeriodStart", "payPeriodEnd", "payDate",
            "grossAmount", "hoursPaid", "method", "note",
        ],
        "subcontractor": [
            "syncID", "updatedAt", "firstName", "lastName", "businessName", "email",
            "phone", "hourlyRate", "address", "isActive", "notes", "createdAt",
            "profileImageData", "tinKey", "w9TINTypeRaw", "w9Data", "w9Name",
            "coiData", "coiName", "coiExpiresOn",
        ],
        "sub_payment": [
            "syncID", "updatedAt", "amount", "hours", "date", "paidDate", "method",
            "detail", "customer",
        ],
    ]
}
