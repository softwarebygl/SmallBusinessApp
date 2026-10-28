//
//  JobAttachmentTests.swift
//  GLSmallBusinessTests
//
//  A job's photos/documents cascade-delete with it, while its receipts (financial records) survive;
//  the kind-filtered computeds return the right items; and the kind accessor round-trips.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct JobAttachmentTests {
    @Test func attachmentsCascadeDeleteWithTheJob() throws {
        let container = try TestStore.makeContainer()   // held so the context stays valid
        let ctx = container.mainContext
        let job = ScheduledJob(title: "Backsplash")
        ctx.insert(job)
        ctx.insert(JobAttachment(kind: .photo, name: "After", data: Data([0x1]), job: job))
        ctx.insert(JobAttachment(kind: .document, name: "Permit.pdf", data: Data([0x2]), job: job))
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<JobAttachment>()) == 2)

        ctx.delete(job)
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<JobAttachment>()) == 0)   // cascade — they belong to the job
    }

    @Test func receiptsSurviveJobDeletion() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let customer = Customer(firstName: "Dani", lastName: "Carter")
        ctx.insert(customer)
        let job = ScheduledJob(title: "Backsplash", customer: customer)
        ctx.insert(job)
        let receipt = Receipt(vendor: "Henderson Hardware", total: 127.43, customer: customer, job: job)
        ctx.insert(receipt)
        ctx.saveChanges()
        #expect(receipt.job?.persistentModelID == job.persistentModelID)

        ctx.delete(job)
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<Receipt>()) == 1)               // nullify — the expense survives
        let surviving = try #require(try ctx.fetch(FetchDescriptor<Receipt>()).first)
        #expect(surviving.job == nil)                                              // job link cleared
        #expect(surviving.customer?.persistentModelID == customer.persistentModelID)   // customer link intact
    }

    @Test func photosAndDocumentsAreKindFilteredAndSorted() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let job = ScheduledJob(title: "Job")
        ctx.insert(job)
        ctx.insert(JobAttachment(kind: .photo, name: "Old", createdAt: .now.addingTimeInterval(-100), job: job))
        ctx.insert(JobAttachment(kind: .photo, name: "New", createdAt: .now, job: job))
        ctx.insert(JobAttachment(kind: .document, name: "Doc", job: job))
        ctx.saveChanges()

        #expect(job.photos.count == 2)
        #expect(job.photos.first?.name == "New")   // newest first
        #expect(job.documents.count == 1)
        #expect(job.documents.first?.name == "Doc")
        #expect(job.sortedReceipts.isEmpty)
    }

    @Test func kindRoundTripsThroughRawString() {
        let attachment = JobAttachment(kind: .document)
        #expect(attachment.kind == .document)
        #expect(attachment.kindRaw == "document")
        attachment.kind = .photo
        #expect(attachment.kindRaw == "photo")
    }
}
