//
//  ContractMigrationTests.swift
//  GLSmallBusinessTests
//
//  Tests for Contract serviceAddress resolution, migration backfill from
//  source estimates/jobs, and auto-healing of customer office address fallbacks.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ContractMigrationTests {

    @Test func contractInitPrioritizesEstimateSiteAddressOverCustomerOffice() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let customer = Customer(firstName: "Jason", lastName: "Garcia", businessName: "The Designery")
        customer.address = Address(street1: "3183 Capital Cir NE", street2: "STE C", city: "Miami", state: "FL", postalCode: "32308")
        customer.sameAsBillingAddress = true
        ctx.insert(customer)

        let estimate = Estimate(customer: customer)
        estimate.serviceAddress = Address(street1: "123 Ocean Blvd", city: "Miami", state: "FL", postalCode: "32312")
        ctx.insert(estimate)
        ctx.saveChanges()

        // Contract initialized without explicit serviceAddress should pick up estimate's site address
        let contract = Contract(
            number: "CON-0001",
            title: "Lori Martini - Backsplash",
            customerName: customer.listDisplayName,
            customer: customer,
            estimate: estimate
        )
        ctx.insert(contract)
        ctx.saveChanges()

        #expect(contract.serviceAddress.street1 == "123 Ocean Blvd")
        #expect(contract.serviceAddress.city == "Miami")
    }

    @Test func contractMigrationBackfillPicksUpEstimateSiteAddress() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let customer = Customer(firstName: "Jason", lastName: "Garcia", businessName: "The Designery")
        customer.address = Address(street1: "3183 Capital Cir NE", street2: "STE C", city: "Miami", state: "FL", postalCode: "32308")
        customer.sameAsBillingAddress = true
        ctx.insert(customer)

        let estimate = Estimate(customer: customer)
        estimate.jobTitle = "Lori Martini - Backsplash"
        estimate.serviceAddress = Address(street1: "456 Magnolia Way", city: "Miami", state: "FL", postalCode: "32301")
        ctx.insert(estimate)

        let job = ScheduledJob(title: "Lori Martini - Backsplash", estimate: estimate)
        job.customer = customer
        // job.serviceAddress is empty as legacy jobs had
        ctx.insert(job)
        ctx.saveChanges()

        ContractMigration.backfill(ctx)

        let contracts = (try? ctx.fetch(FetchDescriptor<Contract>())) ?? []
        let migrated = try #require(contracts.first { $0.title == "Lori Martini - Backsplash" })

        #expect(migrated.serviceAddress.street1 == "456 Magnolia Way")
        #expect(job.serviceAddress.street1 == "456 Magnolia Way")
    }

    @Test func healServiceAddressesRestoresSiteAddressWhenContractHadOfficeAddress() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let customer = Customer(firstName: "Jason", lastName: "Garcia", businessName: "The Designery")
        customer.address = Address(street1: "3183 Capital Cir NE", street2: "STE C", city: "Miami", state: "FL", postalCode: "32308")
        customer.sameAsBillingAddress = true
        ctx.insert(customer)

        let estimate = Estimate(customer: customer)
        estimate.jobTitle = "Lori Martini - Backsplash"
        estimate.serviceAddress = Address(street1: "789 Pine Needle Dr", city: "Miami", state: "FL", postalCode: "32308")
        ctx.insert(estimate)

        // Existing contract that was mistakenly populated with customer's office address
        let contract = Contract(
            number: "CON-0001",
            title: "Lori Martini - Backsplash",
            customerName: customer.listDisplayName,
            serviceAddress: customer.address, // office address
            customer: customer,
            estimate: estimate
        )
        ctx.insert(contract)

        let job = ScheduledJob(title: "Lori Martini - Backsplash", estimate: estimate)
        job.customer = customer
        job.contract = contract
        contract.scheduledJob = job
        ctx.insert(job)
        ctx.saveChanges()

        #expect(contract.serviceAddress.street1 == "3183 Capital Cir NE")

        ContractMigration.healServiceAddresses(ctx)

        #expect(contract.serviceAddress.street1 == "789 Pine Needle Dr")
        #expect(job.serviceAddress.street1 == "789 Pine Needle Dr")
    }
}
