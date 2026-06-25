//
//  JobMigrationTests.swift
//  GLSmallBusinessTests
//
//  The one-time backfill that enriches legacy bookings: links the source document's customer and
//  copies its service address, while leaving already-linked jobs untouched.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct JobMigrationTests {
    @Test func backfillsCustomerAndAddressFromTheSourceInvoice() throws {
        let container = try TestStore.makeContainer()   // held so the context stays valid
        let ctx = container.mainContext
        let customer = Customer(firstName: "Sam", lastName: "Lee")
        ctx.insert(customer)
        let invoice = Invoice(customer: customer)
        invoice.serviceAddress = Address(street1: "5 Oak St", city: "Tallahassee", state: "FL", postalCode: "32301")
        ctx.insert(invoice)
        let job = ScheduledJob(title: "Legacy booking", invoice: invoice)   // no customer link, blank address
        ctx.insert(job)
        ctx.saveChanges()
        #expect(job.customer == nil)

        JobMigration.backfill(ctx)

        #expect(job.customer?.persistentModelID == customer.persistentModelID)
        #expect(job.serviceAddress.street1 == "5 Oak St")
        #expect(job.customerName == customer.listDisplayName)   // snapshot filled from the source
    }

    @Test func backfillLeavesAlreadyLinkedJobsAlone() throws {
        let container = try TestStore.makeContainer()   // held so the context stays valid
        let ctx = container.mainContext
        let customer = Customer(firstName: "Ada", lastName: "Byron")
        ctx.insert(customer)
        let job = ScheduledJob(title: "Already linked", customer: customer)
        job.serviceAddress = Address(street1: "Existing St")
        ctx.insert(job)
        ctx.saveChanges()

        JobMigration.backfill(ctx)

        #expect(job.customer?.persistentModelID == customer.persistentModelID)   // unchanged
        #expect(job.serviceAddress.street1 == "Existing St")                     // unchanged
    }
}
