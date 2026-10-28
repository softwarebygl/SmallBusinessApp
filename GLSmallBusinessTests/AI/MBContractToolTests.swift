//
//  MBContractToolTests.swift
//  GLSmallBusinessTests — AI
//
//  Tests for `create_contract`, `edit_contract`, `invoice_from_contract`, and contract status/deletion.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBContractToolTests {

    @Test func createContractStandaloneSavesContractWithLines() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let created = await MBWriteHarness.run(world.box, "create_contract", [
            "customer_id": .string(custID),
            "title": "Master Bath Remodel",
            "agreed_price": 5000.0,
            "groups": [
                [
                    "name": "Demolition",
                    "lines": [
                        [
                            "name": "Tile tearout",
                            "quantity": 100.0,
                            "unit_price": 15.0,
                            "kind": "labor"
                        ]
                    ]
                ]
            ]
        ])

        let contractID = MBWriteHarness.id(MBWriteHarness.output(created), "contract")
        #expect(!contractID.isEmpty)
        #expect(MBWriteHarness.titles(created) == ["Created contract"])

        let contract = try #require(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context))
        #expect(contract.title == "Master Bath Remodel")
        #expect(contract.agreedPrice == 5000.0)
        #expect(contract.status == .draft)
        #expect(contract.sortedGroups.count == 1)
        #expect(contract.sortedGroups.first?.sortedLineItems.count == 1)
        #expect(contract.sortedGroups.first?.sortedLineItems.first?.name == "Tile tearout")
    }

    @Test func createContractFromEstimateCopiesEstimateDetails() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let estCreated = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(custID),
            "job_title": "Kitchen Flooring",
            "groups": [
                [
                    "name": "Flooring",
                    "lines": [
                        [
                            "name": "Porcelain Tile",
                            "quantity": 200.0,
                            "unit": "squareFoot",
                            "unit_price": 10.0,
                            "kind": "material"
                        ]
                    ]
                ]
            ]
        ])
        let estID = MBWriteHarness.id(MBWriteHarness.output(estCreated), "estimate")
        #expect(!estID.isEmpty)

        let contractCreated = await MBWriteHarness.run(world.box, "create_contract", [
            "from_estimate_id": .string(estID),
            "agreed_price": 2000.0
        ])
        let contractID = MBWriteHarness.id(MBWriteHarness.output(contractCreated), "contract")
        #expect(!contractID.isEmpty)

        let contract = try #require(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context))
        #expect(contract.title == "Kitchen Flooring")
        #expect(contract.agreedPrice == 2000.0)
        #expect(contract.estimate != nil)
        #expect(contract.sortedGroups.first?.name == "Flooring")
        #expect(contract.sortedGroups.first?.sortedLineItems.first?.name == "Porcelain Tile")
    }

    @Test func editContractUpdatesFieldsAndCanBeUndone() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let created = await MBWriteHarness.run(world.box, "create_contract", [
            "customer_id": .string(custID),
            "title": "Deck Build",
            "agreed_price": 3000.0
        ])
        let contractID = MBWriteHarness.id(MBWriteHarness.output(created), "contract")
        let contract = try #require(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context))

        let edited = await MBWriteHarness.run(world.box, "edit_contract", [
            "id": .string(contractID),
            "title": "Covered Deck Build",
            "agreed_price": 4500.0,
            "status": "signed"
        ])
        #expect(MBWriteHarness.titles(edited) == ["Updated contract"])
        #expect(contract.title == "Covered Deck Build")
        #expect(contract.agreedPrice == 4500.0)
        #expect(contract.status == .signed)

        // Undo revert
        let reverted = await MBWriteHarness.undoLatest(edited)
        #expect(reverted != nil)
        #expect(contract.title == "Deck Build")
        #expect(contract.agreedPrice == 3000.0)
        #expect(contract.status == .draft)
    }

    @Test func invoiceFromContractGeneratesInvoice() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let created = await MBWriteHarness.run(world.box, "create_contract", [
            "customer_id": .string(custID),
            "title": "Roof Replacement",
            "agreed_price": 10000.0,
            "groups": [
                [
                    "name": "Roofing",
                    "lines": [
                        [
                            "name": "Shingles",
                            "quantity": 10.0,
                            "unit_price": 500.0,
                            "kind": "material"
                        ]
                    ]
                ]
            ]
        ])
        let contractID = MBWriteHarness.id(MBWriteHarness.output(created), "contract")

        // Progress invoice 50%
        let invoiced = await MBWriteHarness.run(world.box, "invoice_from_contract", [
            "contract_id": .string(contractID),
            "mode": "percentage",
            "percentage": 50.0
        ])
        let invoiceID = MBWriteHarness.id(MBWriteHarness.output(invoiced), "invoice")
        #expect(!invoiceID.isEmpty)

        let invoice = try #require(MBRecordLookup.record(.invoice, id: invoiceID, as: Invoice.self, in: world.context))
        #expect(invoice.jobTitle.contains("Roof Replacement"))
        #expect(invoice.sortedGroups.first?.sortedLineItems.first?.name.contains("50%") == true)
        #expect(invoice.sortedGroups.first?.sortedLineItems.first?.unitPrice == 5000.0)
    }

    @Test func setStatusUpdatesContractStatus() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let created = await MBWriteHarness.run(world.box, "create_contract", [
            "customer_id": .string(custID),
            "title": "Fence Installation",
            "agreed_price": 2500.0
        ])
        let contractID = MBWriteHarness.id(MBWriteHarness.output(created), "contract")
        let contract = try #require(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context))
        #expect(contract.status == .draft)

        let statusUpdated = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "contract",
            "id": .string(contractID),
            "status": "signed"
        ])
        #expect(MBWriteHarness.failureReason(statusUpdated) == nil)
        #expect(contract.status == .signed)

        let statusCompleted = await MBWriteHarness.run(world.box, "set_status", [
            "kind": "contract",
            "id": .string(contractID),
            "status": "completed"
        ])
        #expect(MBWriteHarness.failureReason(statusCompleted) == nil)
        #expect(contract.status == .completed)
    }

    @Test func deleteContractRemovesContractFromStore() async throws {
        let world = try MBWriteWorld()
        let customer = try #require(world.customers().first)
        let custID = world.id(customer)

        let created = await MBWriteHarness.run(world.box, "create_contract", [
            "customer_id": .string(custID),
            "title": "Driveway Paving",
            "agreed_price": 4000.0
        ])
        let contractID = MBWriteHarness.id(MBWriteHarness.output(created), "contract")
        #expect(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context) != nil)

        let asked = await MBWriteHarness.run(world.box, "delete", [
            "records": [
                ["kind": "contract", "id": .string(contractID)]
            ]
        ])
        let done = await MBWriteHarness.confirm(asked)
        #expect(MBWriteHarness.failureReason(done) == nil)
        #expect(MBRecordLookup.record(.contract, id: contractID, as: Contract.self, in: world.context) == nil)
    }
}

