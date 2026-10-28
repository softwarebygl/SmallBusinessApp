//
//  DocumentService.swift
//  GLSmallBusiness
//
//  Every uploaded-document write, one door for all of them: upload, replace, remove and the
//  "good through" date, for every slot a document detail screen (or the Contractor Package, the
//  job and invoice screens, a project's master agreement) can write — and, later, the assistant's
//  `set_document` tool.
//
//  Rules: an upload or replace is gated `.saveDocument`, a remove `.deleteDocument`, an expiry
//  `.saveDocument`; attaching a new photo or document to a job or invoice is `.addJobAttachment`.
//  Removing a slot that IS a record (a job/invoice attachment, a package extra) deletes the record
//  through `DeletionService`; removing a file stored ON a record clears the bytes and the file
//  name, and leaves the expiry date as it is (the certificate screens always have). Every write
//  saves.
//
//  The subcontractor's uploaded W-9 is NOT a slot here, deliberately: it is tax-class, and no
//  service (so no tool) reads or writes a W-9 (law 58(7) quarantine; see SubcontractorService).
//

import Foundation
import SwiftData

@MainActor
enum DocumentService {

    /// One place a document lives.
    enum Slot {
        /// A customer's General Liability or Workers' Comp certificate.
        case customerCertificate(Customer, CustomerCertificate)
        case subcontractorCOI(Subcontractor)
        /// The business's workers' comp exemption or contractor license.
        case compliance(ComplianceKind)
        /// The owner's blank reference COI (never sent).
        case referenceCOI
        /// A customer's Contractor Package extra.
        case packageExtra(CustomerDocument)
        case masterAgreement(Project)
        /// A job document or an invoice attachment.
        case attachment(JobAttachment)

        /// Whether the slot has a "good through" date.
        var hasExpiry: Bool {
            switch self {
            case .customerCertificate, .subcontractorCOI, .compliance: return true
            default: return false
            }
        }
    }

    /// Where a new photo or document is attached.
    enum AttachmentOwner {
        case job(ScheduledJob)
        case invoice(Invoice)
    }

    // MARK: Replace / remove

    /// Uploads or replaces the slot's file, or removes it with `data: nil`. `profile` is the
    /// business profile the compliance and reference-COI slots write to (the stored one when nil).
    static func set(_ slot: Slot, data: Data?, name: String, profile: BusinessProfile? = nil,
                    in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        guard let data else {
            try remove(slot, profile: profile, in: context, subscription: subscription)
            return
        }
        // Replacing a job or invoice attachment's file is gated like adding one.
        let operation: MBWriteOperation
        if case .attachment = slot { operation = .addJobAttachment } else { operation = .saveDocument }
        try DomainGate.requireWritable(operation, subscription)
        switch slot {
        case .customerCertificate(let customer, let kind):
            try DomainGate.requireLive(customer, operation)
            storeCertificate(kind, data: data, name: name, on: customer)
        case .subcontractorCOI(let sub):
            try DomainGate.requireLive(sub, operation)
            setIfChanged(sub, \.coiData, data)
            setIfChanged(sub, \.coiName, name)
        case .compliance(let kind):
            kind.store(try context.writableBusinessProfile(profile, operation), data: data, name: name)
        case .referenceCOI:
            let target = try context.writableBusinessProfile(profile, operation)
            setIfChanged(target, \.ownerReferenceCOIData, data)
            setIfChanged(target, \.ownerReferenceCOIName, name)
        case .packageExtra(let document):
            try DomainGate.requireLive(document, operation)
            setIfChanged(document, \.data, data)
            setIfChanged(document, \.name, name)
        case .masterAgreement(let project):
            try DomainGate.requireLive(project, operation)
            setIfChanged(project, \.masterAgreementData, data)
            setIfChanged(project, \.masterAgreementName, name)
        case .attachment(let attachment):
            try DomainGate.requireLive(attachment, operation)
            setIfChanged(attachment, \.data, data)
            setIfChanged(attachment, \.name, name)
        }
        context.saveChanges()
    }

    /// Sets the slot's "good through" date, or clears it with `nil`. A slot without one refuses.
    static func setExpiry(_ slot: Slot, _ date: Date?, profile: BusinessProfile? = nil,
                          in context: ModelContext, subscription: SubscriptionManager? = nil) throws {
        let operation = MBWriteOperation.saveDocument
        try DomainGate.requireWritable(operation, subscription)
        switch slot {
        case .customerCertificate(let customer, let kind):
            try DomainGate.requireLive(customer, operation)
            switch kind {
            case .generalLiability: setIfChanged(customer, \.coiExpiresOn, date)
            case .workersComp: setIfChanged(customer, \.wcCoiExpiresOn, date)
            }
        case .subcontractorCOI(let sub):
            try DomainGate.requireLive(sub, operation)
            setIfChanged(sub, \.coiExpiresOn, date)
        case .compliance(let kind):
            kind.setExpiry(try context.writableBusinessProfile(profile, operation), date)
        default:
            throw DomainGate.refusal(.noExpiry, operation)
        }
        context.saveChanges()
    }

    // MARK: Add

    /// Adds a document to a customer's Contractor Package.
    @discardableResult
    static func addPackageExtra(_ data: Data, name: String, to customer: Customer, in context: ModelContext,
                                subscription: SubscriptionManager? = nil) throws -> CustomerDocument {
        try DomainGate.requireWritable(.saveDocument, subscription)
        try DomainGate.requireLive(customer, .saveDocument)
        let document = CustomerDocument(name: name, data: data, customer: customer)
        context.insert(document)
        context.saveChanges()
        return document
    }

    /// Attaches a document (a PDF or image) under its file name.
    @discardableResult
    static func attachDocument(_ data: Data, name: String, to owner: AttachmentOwner, in context: ModelContext,
                               subscription: SubscriptionManager? = nil) throws -> JobAttachment {
        guard let document = try attach([(JobAttachmentKind.document, name, data)], to: owner,
                                        in: context, subscription).first else {
            throw DomainError.recordNotFound   // unreachable: one file in, one attachment out
        }
        return document
    }

    /// Attaches photos (already downsized JPEGs), numbered within their record: "Photo 1", "Photo 2"…
    /// The name is the file name a customer receives, so every photo on a record gets its own
    /// (until 3.3.0 each one was "Photo", and Text/Share sent one photo several times — audit F13).
    @discardableResult
    static func attachPhotos(_ photos: [Data], to owner: AttachmentOwner, in context: ModelContext,
                             subscription: SubscriptionManager? = nil) throws -> [JobAttachment] {
        let existing: [JobAttachment]
        switch owner {
        case .job(let job): existing = job.photos
        case .invoice(let invoice): existing = invoice.photos
        }
        let names = numberedPhotoNames(count: photos.count, existing: existing.map(\.name))
        return try attach(zip(names, photos).map { (JobAttachmentKind.photo, $0.0, $0.1) },
                          to: owner, in: context, subscription)
    }

    /// `count` new names "Photo N", counting on from the photos already on the record and
    /// skipping any name already taken. Pure, so it is tested on its own.
    static func numberedPhotoNames(count: Int, existing: [String]) -> [String] {
        var taken = Set(existing.map { $0.lowercased() })
        var next = existing.count + 1
        var names: [String] = []
        for _ in 0..<max(0, count) {
            var name = mbLoc("Photo \(next)")
            while taken.contains(name.lowercased()) {
                next += 1
                name = mbLoc("Photo \(next)")
            }
            taken.insert(name.lowercased())
            names.append(name)
            next += 1
        }
        return names
    }

    // MARK: Internals

    private static func remove(_ slot: Slot, profile: BusinessProfile?, in context: ModelContext,
                               subscription: SubscriptionManager?) throws {
        switch slot {
        case .packageExtra(let document):
            try DeletionService.delete([.customerDocument(document)], in: context, subscription: subscription)
            return
        case .attachment(let attachment):
            try DeletionService.delete([.attachment(attachment)], in: context, subscription: subscription)
            return
        default:
            break
        }
        let operation = MBWriteOperation.deleteDocument
        try DomainGate.requireWritable(operation, subscription)
        switch slot {
        case .customerCertificate(let customer, let kind):
            try DomainGate.requireLive(customer, operation)
            storeCertificate(kind, data: nil, name: "", on: customer)
        case .subcontractorCOI(let sub):
            try DomainGate.requireLive(sub, operation)
            setIfChanged(sub, \.coiData, nil)
            setIfChanged(sub, \.coiName, "")
        case .compliance(let kind):
            kind.store(try context.writableBusinessProfile(profile, operation), data: nil, name: "")
        case .referenceCOI:
            let target = try context.writableBusinessProfile(profile, operation)
            setIfChanged(target, \.ownerReferenceCOIData, nil)
            setIfChanged(target, \.ownerReferenceCOIName, "")
        case .masterAgreement(let project):
            try DomainGate.requireLive(project, operation)
            setIfChanged(project, \.masterAgreementData, nil)
            setIfChanged(project, \.masterAgreementName, "")
        case .packageExtra, .attachment:
            return   // deleted above
        }
        context.saveChanges()
    }

    private static func storeCertificate(_ kind: CustomerCertificate, data: Data?, name: String,
                                         on customer: Customer) {
        switch kind {
        case .generalLiability:
            setIfChanged(customer, \.coiData, data)
            setIfChanged(customer, \.coiName, name)
        case .workersComp:
            setIfChanged(customer, \.wcCoiData, data)
            setIfChanged(customer, \.wcCoiName, name)
        }
    }

    private static func attach(_ files: [(JobAttachmentKind, String, Data)], to owner: AttachmentOwner,
                               in context: ModelContext, _ subscription: SubscriptionManager?) throws -> [JobAttachment] {
        let operation = MBWriteOperation.addJobAttachment
        try DomainGate.requireWritable(operation, subscription)
        let added: [JobAttachment]
        switch owner {
        case .job(let job):
            try DomainGate.requireLive(job, operation)
            added = files.map { JobAttachment(kind: $0.0, name: $0.1, data: $0.2, job: job) }
        case .invoice(let invoice):
            try DomainGate.requireLive(invoice, operation)
            added = files.map { JobAttachment(kind: $0.0, name: $0.1, data: $0.2, invoice: invoice) }
        }
        added.forEach { context.insert($0) }
        context.saveChanges()
        return added
    }
}
