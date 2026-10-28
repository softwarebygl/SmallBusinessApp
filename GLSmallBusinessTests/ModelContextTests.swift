//
//  ModelContextTests.swift
//  GLSmallBusinessTests
//
//  The demo seeder — a logic function that needs a live SwiftData context. Containers come from
//  `TestStore` (Harness/TestStore.swift): isolated, in-memory, CloudKit off, so they coexist with
//  the host app's container. (Invoice.make(from:) — the estimate → invoice conversion — is owned by
//  InvoiceLifecycleCoverageTests and CalendarJobsEstimatesCoverageTests.)
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

#if DEBUG
@MainActor
struct DemoSeedTests {
    @Test func seedsSampleDataAndIsIdempotent() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        DemoSeed.populate(ctx)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Estimate>()) == 2)
        #expect(try ctx.fetchCount(FetchDescriptor<Invoice>()) == 2)   // INV-0001 + the completed job's paid INV-0002
        #expect(try ctx.fetchCount(FetchDescriptor<Receipt>()) == 4)
        #expect(try ctx.fetchCount(FetchDescriptor<BusinessProfile>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Employee>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<TimeEntry>()) == 8)
        #expect(try ctx.fetchCount(FetchDescriptor<Paycheck>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Subcontractor>()) == 2)
        #expect(try ctx.fetchCount(FetchDescriptor<SubPayment>()) == 4)   // 3 paid + 1 owed
        #expect(try ctx.fetchCount(FetchDescriptor<ScheduledJob>()) == 5)   // 2 source + from-scratch + completed + timed
        #expect(try ctx.fetchCount(FetchDescriptor<JobAttachment>()) == 3)   // 2 photos + 1 document on the completed job

        // Guarded on an empty store, so a second call must not duplicate.
        DemoSeed.populate(ctx)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Employee>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Subcontractor>()) == 2)
    }
}
#endif
