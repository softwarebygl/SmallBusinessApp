//
//  ModelContextTests.swift
//  GLSmallBusinessTests
//
//  The two logic functions that need a live SwiftData context: Invoice.make(from:) and the demo
//  seeder. We spin up an isolated in-memory container with CloudKit disabled — that's the piece the
//  original suite avoided, and disabling CloudKit lets it coexist with the host app's container.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
enum TestStore {
    /// A throwaway in-memory store for the current schema. CloudKit is off so it doesn't collide
    /// with the host app's container that already exists in the test process.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: GLSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }
}

@MainActor
struct InvoiceMakeTests {
    @Test func copiesSnapshotLinesAndDeposit() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        let est = TS.estimate(number: "EST-0009", taxRatePercent: 7.5, lines: [(1000, true), (500, false)])
        est.customerFirstName = "Marcus"
        est.customerLastName = "Reed"
        est.customerEmail = "marcus@x.com"
        est.depositType = .percentage
        est.depositValue = 20

        let inv = Invoice.make(from: est, number: "INV-0009", in: ctx)

        #expect(inv.number == "INV-0009")
        #expect(inv.sourceEstimateNumber == "EST-0009")
        #expect(inv.customerFirstName == "Marcus")
        #expect(inv.customerLastName == "Reed")
        #expect(inv.customerEmail == "marcus@x.com")
        #expect(close(inv.taxRatePercent, 7.5))
        #expect(close(inv.total, est.total))                 // same lines/tax → same total
        #expect(inv.allLineItems.count == est.allLineItems.count)
        #expect(inv.amountDueNow > 0)
        #expect(close(inv.amountDueNow, est.depositAmount))  // deposit becomes the "amount due now"
    }
}

#if DEBUG
@MainActor
struct DemoSeedTests {
    @Test func seedsSampleDataAndIsIdempotent() throws {
        let container = try TestStore.makeContainer()
        let ctx = ModelContext(container)

        DemoSeed.populate(ctx)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Estimate>()) == 2)
        #expect(try ctx.fetchCount(FetchDescriptor<Invoice>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Receipt>()) == 4)
        #expect(try ctx.fetchCount(FetchDescriptor<BusinessProfile>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Employee>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<TimeEntry>()) == 8)
        #expect(try ctx.fetchCount(FetchDescriptor<Paycheck>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Subcontractor>()) == 2)
        #expect(try ctx.fetchCount(FetchDescriptor<SubPayment>()) == 3)

        // Guarded on an empty store, so a second call must not duplicate.
        DemoSeed.populate(ctx)
        #expect(try ctx.fetchCount(FetchDescriptor<Customer>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Employee>()) == 3)
        #expect(try ctx.fetchCount(FetchDescriptor<Subcontractor>()) == 2)
    }
}
#endif
