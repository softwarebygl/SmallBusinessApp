//
//  CustomerDocumentTests.swift
//  GLSmallBusinessTests
//
//  A customer's Contractor Package extras cascade-delete with them. (The oldest-first
//  ordering of `sortedPackageDocuments` is pinned in ContractorPackageCoverageTests.)
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct CustomerDocumentTests {
    @Test func extrasCascadeDeleteWithTheCustomer() throws {
        let container = try TestStore.makeContainer()   // held so the context stays valid
        let ctx = container.mainContext
        let customer = Customer(firstName: "Dani", lastName: "Carter")
        ctx.insert(customer)
        ctx.insert(CustomerDocument(name: "OSHA-30.pdf", data: Data([0x1]), customer: customer))
        ctx.insert(CustomerDocument(name: "Vendor-Agreement.pdf", data: Data([0x2]), customer: customer))
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<CustomerDocument>()) == 2)

        ctx.delete(customer)
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<CustomerDocument>()) == 0)   // cascade — they belong to the customer
    }
}
