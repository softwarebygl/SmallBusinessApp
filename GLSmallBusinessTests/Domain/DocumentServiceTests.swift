//
//  DocumentServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  Every document slot through its one door: upload / replace / remove / "good through", the
//  add paths (package extras, job and invoice attachments), the gates, and the save. The
//  per-slot field mapping of the certificate slots is also pinned in the Customer, Subcontractor,
//  BusinessProfile and Project service tests.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct DocumentServiceTests {

    @Test func aPackageExtraIsAddedReplacedAndRemovedAsARecord() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()

        let extra = try DomainState.subscribed.run {
            try DocumentService.addPackageExtra(Data([1]), name: "permit.pdf", to: customer, in: context)
        }
        #expect(extra.customer === customer && extra.name == "permit.pdf")
        #expect(extra.syncID != nil && !context.hasChanges, "saved now, with its id")

        try DomainState.subscribed.run {
            try DocumentService.set(.packageExtra(extra), data: Data([2]), name: "permit-v2.pdf", in: context)
        }
        #expect(extra.data == Data([2]) && extra.name == "permit-v2.pdf" && !context.hasChanges)

        let extraID = try #require(extra.syncID)
        try DomainState.subscribed.run { try DocumentService.set(.packageExtra(extra), data: nil, name: "", in: context) }
        #expect(try context.fetchCount(FetchDescriptor<CustomerDocument>()) == 0, "removing it deletes the record")
        #expect(GLSyncOutboxEntry.all(in: context).contains { $0.isDelete && $0.recordID == extraID },
                "through the routed delete")
        #expect(!context.hasChanges)
    }

    @Test func invoiceAndJobAttachmentsAttachReplaceAndRemove() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        let job = TS.job("Tile", start: .now, in: context)
        context.saveChanges()

        let photos = try DomainState.subscribed.run {
            try DocumentService.attachPhotos([Data([1]), Data([2])], to: .invoice(invoice), in: context)
        }
        let doc = try DomainState.subscribed.run {
            try DocumentService.attachDocument(Data([3]), name: "lien.pdf", to: .invoice(invoice), in: context)
        }
        #expect(photos.allSatisfy { $0.invoice === invoice && $0.kind == .photo })
        #expect(photos.map(\.name) == [mbLoc("Photo \(1)"), mbLoc("Photo \(2)")], "numbered within the record (F13)")
        #expect(doc.invoice === invoice && doc.kind == .document)
        #expect(invoice.photos.count == 2 && invoice.documents.count == 1)
        #expect(!context.hasChanges && doc.syncID != nil)

        let jobDoc = try DomainState.subscribed.run {
            try DocumentService.attachDocument(Data([4]), name: "permit.pdf", to: .job(job), in: context)
        }
        #expect(jobDoc.job === job && job.documents.count == 1)

        try DomainState.subscribed.run {
            try DocumentService.set(.attachment(doc), data: Data([5]), name: "lien-v2.pdf", in: context)
            try DocumentService.set(.attachment(doc), data: nil, name: "", in: context)
        }
        #expect(invoice.documents.isEmpty && !context.hasChanges)
    }

    @Test func onlyCertificatesHaveAnExpiry() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let project = Project(name: "Kitchen")
        context.insert(project)
        let extra = CustomerDocument(name: "x.pdf", data: Data([1]), customer: customer)
        context.insert(extra)
        let attachment = JobAttachment(kind: .document, name: "d.pdf", data: Data([1]),
                                       job: TS.job(start: .now, in: context))
        context.insert(attachment)
        context.saveChanges()
        let june = TS.day(2027, 6, 30)

        try DomainState.subscribed.run {
            try DocumentService.setExpiry(.customerCertificate(customer, .workersComp), june, in: context)
            try DocumentService.setExpiry(.compliance(.wcExemption), june, in: context)
            for slot: DocumentService.Slot in [.referenceCOI, .masterAgreement(project), .packageExtra(extra),
                                                .attachment(attachment)] {
                #expect(!slot.hasExpiry)
                #expect(domainError { try DocumentService.setExpiry(slot, june, in: context) } == .noExpiry)
            }
        }
        #expect(customer.wcCoiExpiresOn == june && !context.hasChanges)
        #expect(DocumentService.Slot.subcontractorCOI(TS.subcontractor()).hasExpiry)
    }

    @Test func everyDocumentWriteIsGated() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(in: context)
        let project = Project(name: "Kitchen")
        context.insert(project)
        let attachment = JobAttachment(kind: .photo, name: "a.jpg", caption: "", data: Data([1]), invoice: invoice)
        context.insert(attachment)
        context.saveChanges()

        // Replacing an attachment's file is gated like adding one.
        #expect(DomainState.lapsed.run {
            domainError { try DocumentService.set(.attachment(attachment), data: Data([2]), name: "b.jpg", in: context) }
        } == .readOnly(operation: "addJobAttachment", lapsed: true))
        #expect(attachment.data == Data([1]))
        #expect(DomainState.lapsed.run { domainError { _ = try DocumentService.addPackageExtra(Data([1]), name: "a", to: customer, in: context) } }
                == .readOnly(operation: "saveDocument", lapsed: true))
        #expect(DomainState.offline.run { domainError { try DocumentService.set(.masterAgreement(project), data: nil, name: "", in: context) } }
                == .readOnly(operation: "deleteDocument", lapsed: false))
        #expect(DomainState.lapsed.run { domainError { _ = try DocumentService.attachPhotos([Data([1])], to: .invoice(invoice), in: context) } }
                == .readOnly(operation: "addJobAttachment", lapsed: true))
        #expect(DomainState.offline.run { domainError { try DocumentService.setExpiry(.compliance(.license), .now, in: context) } }
                == .readOnly(operation: "saveDocument", lapsed: false))
        #expect(try context.fetchCount(FetchDescriptor<CustomerDocument>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<JobAttachment>()) == 1, "only the fixture")
    }

    @Test func aDocumentOnADeletedRecordIsRefused() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(in: context)
        context.saveChanges()
        try DomainState.subscribed.run {
            try DeletionService.delete([.customer(customer), .invoice(invoice)], in: context)
            #expect(domainError { try DocumentService.set(.customerCertificate(customer, .generalLiability),
                                                          data: Data([1]), name: "gl.pdf", in: context) } == .recordNotFound)
            #expect(domainError { _ = try DocumentService.attachDocument(Data([1]), name: "a", to: .invoice(invoice), in: context) }
                    == .recordNotFound)
        }
    }
}
