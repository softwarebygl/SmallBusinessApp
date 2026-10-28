//
//  DemoWorld.swift
//  GLSmallBusinessTests — Harness
//
//  The demo dataset (`DemoSeed.populate`) on a fresh in-memory container, with every
//  record a test reaches for already fetched in a DETERMINISTIC order. The seeder inserts
//  in a fixed sequence but SwiftData returns rows in store order, which is not a promise —
//  so "the first customer" is Carter (sorted by last name), not whichever row came back
//  first, and a test that wants Marcus Reed asks for him by name.
//
//  Built by `TestStore.demoWorld()`.
//

import Foundation
import SwiftData
@testable import GLSmallBusiness

/// A name or number the demo dataset does not contain. Thrown, not trapped, so the failing
/// test reads "no invoice INV-0009 in the demo world" instead of taking the process down.
nonisolated struct DemoWorldError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
struct DemoWorld {
    let container: ModelContainer
    /// `container.mainContext` — the context a hosted screen observes.
    let context: ModelContext
    /// Sorted by last name, then first name: Carter, Nguyen, Reed.
    let customers: [Customer]
    /// Sorted by number.
    let invoices: [Invoice]
    /// Sorted by number.
    let estimates: [Estimate]
    /// Sorted by last name, then first name.
    let employees: [Employee]
    /// Sorted by last name, then first name.
    let subcontractors: [Subcontractor]
    /// The one seeded business profile.
    let profile: BusinessProfile
    /// Marcus Reed — the customer most of the demo dataset hangs off.
    let primary: Customer

    /// Seed `container` with the demo dataset and fetch it back in order.
    init(seeding container: ModelContainer) throws {
        let context = container.mainContext
        DemoSeed.populate(context)

        let byName: [SortDescriptor<Customer>] = [SortDescriptor(\.lastName), SortDescriptor(\.firstName)]
        self.container = container
        self.context = context
        customers = try context.fetch(FetchDescriptor<Customer>(sortBy: byName))
        invoices = try context.fetch(FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.number)]))
        estimates = try context.fetch(FetchDescriptor<Estimate>(sortBy: [SortDescriptor(\.number)]))
        employees = try context.fetch(FetchDescriptor<Employee>(
            sortBy: [SortDescriptor(\.lastName), SortDescriptor(\.firstName)]))
        subcontractors = try context.fetch(FetchDescriptor<Subcontractor>(
            sortBy: [SortDescriptor(\.lastName), SortDescriptor(\.firstName)]))
        guard let profile = try context.fetch(FetchDescriptor<BusinessProfile>()).first else {
            throw DemoWorldError(description: "the demo seed produced no BusinessProfile")
        }
        self.profile = profile
        guard let reed = customers.first(where: { $0.lastName == "Reed" }) else {
            throw DemoWorldError(description: "no customer Reed in the demo world — the seed changed")
        }
        primary = reed
    }

    // MARK: - Lookups by the names a test already knows

    func customer(_ last: String) throws -> Customer {
        try one(customers, "customer \(last)") { $0.lastName == last }
    }

    func invoice(_ number: String) throws -> Invoice {
        try one(invoices, "invoice \(number)") { $0.number == number }
    }

    func estimate(_ number: String) throws -> Estimate {
        try one(estimates, "estimate \(number)") { $0.number == number }
    }

    func employee(_ last: String) throws -> Employee {
        try one(employees, "employee \(last)") { $0.lastName == last }
    }

    func sub(_ last: String) throws -> Subcontractor {
        try one(subcontractors, "subcontractor \(last)") { $0.lastName == last }
    }

    private func one<T>(_ rows: [T], _ what: String, where matches: (T) -> Bool) throws -> T {
        guard let row = rows.first(where: matches) else {
            throw DemoWorldError(description: "no \(what) in the demo world")
        }
        return row
    }
}
