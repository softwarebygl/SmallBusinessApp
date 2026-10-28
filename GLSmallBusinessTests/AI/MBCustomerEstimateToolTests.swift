//
//  MBCustomerEstimateToolTests.swift
//  GLSmallBusinessTests — AI
//
//  `save_customer`, `create_estimate` and `edit_estimate`: the save itself, every refusal, the
//  activity rows the person reads, and Undo — including the two rules that keep Undo honest
//  (an entry is skipped when the record moved since, and a create's Undo is a real delete).
//
//  Pillar 2: an edit NEVER mints a second document.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBCustomerEstimateToolTests {

    // MARK: - save_customer

    @Test func savingACustomerAddsThenChangesOnlyWhatWasSent() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_customer", [
            "first_name": "Ana", "last_name": "Lopez", "email": "ana@example.com",
            "address": ["street1": "9 Oak Ln", "city": "Miami", "state": "FL", "postal_code": "32303"],
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "customer")
        #expect(!id.isEmpty)
        #expect(MBWriteHarness.titles(created) == ["Added customer"])
        #expect(MBWriteHarness.activity(created).first?.kind == .created)
        #expect(MBWriteHarness.activity(created).first?.record?.kind == "customer")

        let customer = try #require(MBRecordLookup.record(.customer, id: id, as: Customer.self, in: world.context))
        #expect(customer.firstName == "Ana")
        #expect(customer.address.city == "Miami")

        // Only the sent fields change: the address and the first name stay put.
        let updated = await MBWriteHarness.run(world.box, "save_customer", ["id": .string(id), "phone": "(850) 555-0143"])
        #expect(MBWriteHarness.titles(updated) == ["Updated customer"])
        #expect(customer.phoneNumber == "(850) 555-0143")
        #expect(customer.firstName == "Ana")
        #expect(customer.address.city == "Miami")
        #expect(world.customers().count == 2)   // the fixture's customer and this one
    }

    @Test func aCustomerWithNoNameIsRefusedTheWayTheFormRefusesIt() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "save_customer", ["email": "nobody@example.com"])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.nameRequired.code)
        #expect(world.customers().count == 1)
    }

    @Test func saveCustomerRejectsPronounNames() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "for", "last_name": "me"])
        #expect(MBWriteHarness.failureReason(outcome) == "invalid_arguments")
        #expect(world.customers().count == 1)

        let outcome2 = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "myself"])
        #expect(MBWriteHarness.failureReason(outcome2) == "invalid_arguments")
        #expect(world.customers().count == 1)

        // Owner ruling 2026-09-26: only a WHOLE name that is a phrase is refused; a real
        // client named Mi is saved.
        let real = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "Mi", "last_name": "Nguyen"])
        #expect(MBWriteHarness.failureReason(real) == nil)
        #expect(world.customers().count == 2)
    }

    @Test func undoTakesBackANewCustomerAndIsSkippedWhenItChangedSince() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "Ana", "last_name": "Lopez"])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "customer")
        let revert = await MBWriteHarness.undoLatest(created)
        guard case .reverted(let activity)? = revert else {
            Issue.record("the new customer should have been removed")
            return
        }
        #expect(GLAIStrings.english(activity.title) == "Deleted customer")
        #expect(MBRecordLookup.record(.customer, id: id, as: Customer.self, in: world.context) == nil)

        // A customer edited on the form after the tool wrote it is left alone.
        let second = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "Bea", "last_name": "Ruiz"])
        let secondID = MBWriteHarness.id(MBWriteHarness.output(second), "customer")
        let bea = try #require(MBRecordLookup.record(.customer, id: secondID, as: Customer.self, in: world.context))
        try DomainState.subscribed.run {
            var draft = CustomerDraft(bea)
            draft.phoneNumber = "(850) 555-0100"
            try CustomerService.update(bea, with: draft, in: world.context)
        }
        let entry = try #require(MBWriteHarness.undo(second))
        #expect(entry.changedSince())
        #expect(MBRecordLookup.record(.customer, id: secondID, as: Customer.self, in: world.context) != nil)
    }

    @Test func aCustomerThatPickedUpRecordsIsKeptWhenUndoRuns() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_customer", ["first_name": "Ana", "last_name": "Lopez"])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "customer")
        let customer = try #require(MBRecordLookup.record(.customer, id: id, as: Customer.self, in: world.context))
        let estimate = TS.estimate(number: "EST-9001", in: world.context)
        estimate.customer = customer
        world.context.saveChanges()

        let entry = try #require(MBWriteHarness.undo(created))
        // The write ledger knows the tool's own write; the estimate came later on the form.
        let revert = await DomainState.subscribed.runAsync { await entry.revert() }
        guard case .failed(let reason) = revert else {
            Issue.record("the customer should have been kept")
            return
        }
        #expect(GLAIStrings.english(reason) == "It has other records now, so it was kept.")
        #expect(MBRecordLookup.record(.customer, id: id, as: Customer.self, in: world.context) != nil)
    }

    // MARK: - create_estimate

    @Test func creatingAnEstimateMatchesWhatTheFormWouldSave() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID),
            "job_title": " Master bath ",
            "tax_rate_percent": 7,
            "deposit_type": "percentage", "deposit_value": 25,
            "valid_until": "2026-10-31",
            "groups": [[
                "name": "Shower",
                "lines": [
                    ["name": "Tile install", "quantity": 120, "unit": "squareFoot", "unit_price": 9.125, "kind": "labor"],
                    ["name": "Tile", "quantity": 1, "unit": "lumpSum", "unit_price": 800, "kind": "material"],
                ],
            ]],
        ])
        let output = MBWriteHarness.output(outcome)
        let estimate = try #require(world.estimates().first)
        #expect(world.estimates().count == 1)
        #expect(estimate.jobTitle == "Master bath")
        #expect(estimate.number == "EST-0001")
        #expect(estimate.status == .draft)
        #expect(estimate.depositValue == 25)
        // A price is kept as sent, as the form keeps what was typed (law 60): 9.125 stays 9.125, and
        // the amount made from it is rounded once — 120 × 9.125 = $1,095.00.
        let lines = estimate.sortedGroups.flatMap(\.sortedLineItems)
        #expect(lines.first?.unitPrice == 9.125)
        #expect(lines.first?.lineTotal == 1095)
        #expect(lines.last?.unitPrice == 800)
        // Material is taxable by default (the form's rule), labor isn't.
        #expect(lines.map(\.isTaxable) == [false, true])
        #expect(output["estimate"]?["number"]?.stringValue == "EST-0001")
        #expect(MBWriteHarness.titles(outcome) == ["Created estimate"])
        #expect(MBWriteHarness.activity(outcome).first?.record?.id == world.id(estimate))
    }

    @Test func anEstimateWithNoCustomerOrNoLinesIsRefused() async throws {
        let world = try MBWriteWorld()
        let noCustomer = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": "not-an-id", "job_title": "Bath", "groups": [["lines": [["name": "Tile"]]]],
        ])
        #expect(MBWriteHarness.failureReason(noCustomer) == "not_found")

        let noLines = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Bath", "groups": [["name": "Shower", "lines": []]],
        ])
        #expect(MBWriteHarness.failureReason(noLines) == "invalid_arguments")

        let noTitle = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "  ",
            "groups": [["lines": [["name": "Tile", "unit_price": 10]]]],
        ])
        #expect(MBWriteHarness.failureReason(noTitle) == DomainError.titleRequired.code)
        #expect(world.estimates().isEmpty)
    }

    @Test func aTaxRateOver100IsRefusedForTheToolToo() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Bath", "tax_rate_percent": 150,
            "groups": [["lines": [["name": "Tile", "unit_price": 10]]]],
        ])
        #expect(MBWriteHarness.failureReason(outcome) == DomainError.percentOutOfRange.code)
        #expect(world.estimates().isEmpty)
    }

    // MARK: - edit_estimate

    /// Pillar 2: an edit changes the rows in place — one estimate, same id, same number.
    @Test func editingAnEstimateNeverMintsASecondOne() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Master bath",
            "groups": [["name": "Shower", "lines": [["name": "Tile install", "unit_price": 1000]]]],
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "estimate")
        let estimate = try #require(MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: world.context))
        let firstLine = try #require(estimate.sortedGroups.first?.sortedLineItems.first)
        let lineID = world.id(firstLine)
        let groupID = world.id(try #require(estimate.sortedGroups.first))

        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id),
            "lines": [
                ["line_id": .string(lineID), "unit_price": 1200],
                ["name": "Grout", "unit_price": 150, "group_id": .string(groupID)],
                ["name": "Bench", "unit_price": 450, "new_group": "Extras"],
            ],
        ])
        #expect(MBWriteHarness.titles(edited) == ["Updated estimate"])
        #expect(world.estimates().count == 1)
        #expect(estimate.number == "EST-0001")
        #expect(world.id(estimate) == id)
        #expect(estimate.sortedGroups.count == 2)
        #expect(estimate.sortedGroups.first?.sortedLineItems.map(\.unitPrice) == [1200, 150])
        #expect(estimate.sortedGroups.last?.name == "Extras")
        // The edited line kept its identity (RowReconciler updated it in place).
        #expect(world.id(firstLine) == lineID)
    }

    @Test func removingAndRenamingUsesTheIdsTheToolHandedOut() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0002", lines: [(100, false), (200, false)], in: world.context)
        estimate.customer = world.customer
        world.context.saveChanges()
        let id = world.id(estimate)
        let group = try #require(estimate.sortedGroups.first)
        let groupID = world.id(group)
        let secondLineID = world.id(try #require(group.sortedLineItems.last))

        let outcome = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id),
            "groups": [["group_id": .string(groupID), "name": "Main bath", "note": "Tile only"]],
            "remove_line_ids": [.string(secondLineID)],
            "customer_notes": "Thanks!",
        ])
        _ = MBWriteHarness.output(outcome)
        #expect(group.name == "Main bath")
        #expect(group.note == "Tile only")
        #expect(group.sortedLineItems.count == 1)
        #expect(estimate.customerNotes == "Thanks!")

        let unknown = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id), "remove_line_ids": ["11111111-1111-1111-1111-111111111111"],
        ])
        #expect(MBWriteHarness.failureReason(unknown) == "invalid_arguments")
        #expect(group.sortedLineItems.count == 1)
    }

    @Test func undoPutsAnEstimateEditBack() async throws {
        let world = try MBWriteWorld()
        let estimate = TS.estimate(number: "EST-0003", lines: [(1000, false)], in: world.context)
        estimate.customer = world.customer
        estimate.jobTitle = "Master bath"
        world.context.saveChanges()
        let id = world.id(estimate)

        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id), "job_title": "Guest bath",
            "lines": [["name": "Grout", "unit_price": 150]],
        ])
        #expect(estimate.jobTitle == "Guest bath")
        #expect(estimate.sortedGroups.flatMap(\.sortedLineItems).count == 2)

        let revert = await MBWriteHarness.undoLatest(edited)
        guard case .reverted(let activity)? = revert else {
            Issue.record("the edit should have been put back")
            return
        }
        #expect(GLAIStrings.english(activity.title) == "Restored estimate")
        #expect(estimate.jobTitle == "Master bath")
        #expect(estimate.sortedGroups.flatMap(\.sortedLineItems).count == 1)
    }

    /// A create, then an edit, then Undo: the edit goes back first, and the create's entry still
    /// runs (the ledger, not the raw `updatedAt`, decides "changed since").
    @Test func undoAfterAnEditStillTakesBackTheCreate() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Master bath",
            "groups": [["lines": [["name": "Tile install", "unit_price": 1000]]]],
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "estimate")
        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id), "job_title": "Guest bath",
        ])
        _ = await MBWriteHarness.undoLatest(edited)
        let revert = await MBWriteHarness.undoLatest(created)
        guard case .reverted? = revert else {
            Issue.record("the new estimate should have been removed")
            return
        }
        #expect(world.estimates().isEmpty)
    }

    /// Release eval 2026-09-27 (en-conversational-estimate-flow): after "add a 10% discount and a
    /// 30% deposit" the reply said "$855 with a $256.50 deposit". Right, but the model worked the
    /// deposit out itself: the write handed back the total and not the deposit. Now both come from
    /// the app (`Estimate.total` and `Estimate.depositAmount`, in whole cents).
    @Test func anEstimateWriteHandsBackTheTotalAndTheDepositTheAppWorkedOut() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Floor tile installation",
            "groups": [["lines": [["name": "Floor tile installation", "quantity": 100, "unit": "squareFoot",
                                    "unit_price": 9.5]]]],
        ])
        let first = MBWriteHarness.output(created)
        #expect(first["estimate"]?["total"]?.doubleValue == 950)
        #expect(first["estimate"]?["deposit"] == .null, "no deposit asked for yet")
        let id = MBWriteHarness.id(first, "estimate")
        let estimate = try #require(MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: world.context))

        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id), "discount_type": "percentage", "discount_value": 10,
            "deposit_type": "percentage", "deposit_value": 30,
        ])
        let row = MBWriteHarness.output(edited)["estimate"]
        #expect(row?["total"]?.doubleValue == 855)
        #expect(row?["deposit"]?.doubleValue == 256.5)
        #expect(row?["deposit"]?.doubleValue == DomainMoney.roundedToCents(estimate.depositAmount))

        // A fixed deposit reads back as dollars; taking it off reads back as none.
        let fixed = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id), "deposit_type": "fixed", "deposit_value": 300,
        ])
        #expect(MBWriteHarness.output(fixed)["estimate"]?["deposit"]?.doubleValue == 300)
        let none = await MBWriteHarness.run(world.box, "edit_estimate", ["id": .string(id), "deposit_type": "none"])
        #expect(MBWriteHarness.output(none)["estimate"]?["deposit"] == .null)
        #expect(MBWriteHarness.output(none)["estimate"]?["total"]?.doubleValue == 855)
    }

    /// An options estimate has no single total, so no single deposit either: the screens never show
    /// one and converting it never asks for one. The row says neither, whatever deposit is stored.
    @Test func anOptionsEstimateHandsBackNoTotalAndNoDeposit() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Flooring options", "combine_totals": false,
            "deposit_type": "percentage", "deposit_value": 30,
            "groups": [
                ["name": "Ceramic", "lines": [["name": "Ceramic floor", "unit_price": 1000]]],
                ["name": "Porcelain", "lines": [["name": "Porcelain floor", "unit_price": 2000]]],
            ],
        ])
        let row = MBWriteHarness.output(created)["estimate"]
        #expect(row?["options"]?.boolValue == true)
        #expect(row?["total"] == .null)
        #expect(row?["deposit"] == .null)
    }

    // MARK: - Compound & Conversational Invariants

    /// Verifies compound execution: creating a customer, then creating multiple estimates
    /// linked to that customer (e.g. kitchen demo and tile install) with specific line items.
    @Test func compoundCustomerAndMultipleEstimatesCreation() async throws {
        let world = try MBWriteWorld()

        // 1. Create client with details
        let customerOutcome = await MBWriteHarness.run(world.box, "save_customer", [
            "first_name": "John",
            "last_name": "Doe",
            "phone": "555-0199",
            "address": ["street1": "123 Main St", "city": "Orlando", "state": "FL", "postal_code": "32801"]
        ])
        let customerID = MBWriteHarness.id(MBWriteHarness.output(customerOutcome), "customer")
        #expect(!customerID.isEmpty)
        let customer = try #require(MBRecordLookup.record(.customer, id: customerID, as: Customer.self, in: world.context))
        #expect(customer.fullName == "John Doe")
        #expect(customer.address.street1 == "123 Main St")

        // 2. Create Estimate 1: Kitchen Demo
        let est1Outcome = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(customerID),
            "job_title": "Kitchen Demo",
            "groups": [[
                "name": "Demolition",
                "lines": [
                    ["name": "Cabinet & Countertop Removal", "quantity": 1, "unit": "job", "unit_price": 1200, "kind": "labor"],
                    ["name": "Hauling & Disposal", "quantity": 1, "unit": "lumpSum", "unit_price": 400, "kind": "labor"]
                ]
            ]]
        ])
        let est1ID = MBWriteHarness.id(MBWriteHarness.output(est1Outcome), "estimate")
        #expect(!est1ID.isEmpty)
        let est1 = try #require(MBRecordLookup.record(.estimate, id: est1ID, as: Estimate.self, in: world.context))
        #expect(est1.jobTitle == "Kitchen Demo")
        #expect(est1.customer?.fullName == "John Doe")
        #expect(est1.total == 1600)

        // 3. Create Estimate 2: Tile Install
        let est2Outcome = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(customerID),
            "job_title": "Tile Install",
            "tax_rate_percent": 7.0,
            "deposit_type": "percentage",
            "deposit_value": 25,
            "groups": [[
                "name": "Flooring",
                "lines": [
                    ["name": "Porcelain Tile", "quantity": 250, "unit": "squareFoot", "unit_price": 4.50, "kind": "material", "taxable": true],
                    ["name": "Tile Installation Labor", "quantity": 250, "unit": "squareFoot", "unit_price": 8.00, "kind": "labor", "taxable": false]
                ]
            ]]
        ])
        let est2ID = MBWriteHarness.id(MBWriteHarness.output(est2Outcome), "estimate")
        #expect(!est2ID.isEmpty)
        let est2 = try #require(MBRecordLookup.record(.estimate, id: est2ID, as: Estimate.self, in: world.context))
        #expect(est2.jobTitle == "Tile Install")
        #expect(est2.customer?.fullName == "John Doe")
        #expect(est2.depositValue == 25)
        #expect(est2.depositType == .percentage)
        #expect(est1.number != est2.number)
        #expect(world.estimates().count == 2)
    }

    /// Verifies standalone customer creation with full details without requiring any document.
    @Test func standaloneCustomerCreationWithoutDocuments() async throws {
        let world = try MBWriteWorld()
        let outcome = await MBWriteHarness.run(world.box, "save_customer", [
            "first_name": "Samantha",
            "last_name": "Jenkins",
            "business_name": "Jenkins Design Studio",
            "email": "samantha@jenkinsdesign.com",
            "phone": "555-4321",
            "office_phone": "555-9876",
            "address": [
                "street1": "456 Oak Ave",
                "street2": "Suite 200",
                "city": "Tampa",
                "state": "FL",
                "postal_code": "33602"
            ]
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(outcome), "customer")
        #expect(!id.isEmpty)
        let customer = try #require(MBRecordLookup.record(.customer, id: id, as: Customer.self, in: world.context))
        #expect(customer.firstName == "Samantha")
        #expect(customer.lastName == "Jenkins")
        #expect(customer.businessName == "Jenkins Design Studio")
        #expect(customer.email == "samantha@jenkinsdesign.com")
        #expect(customer.phoneNumber == "555-4321")
        #expect(customer.officePhone == "555-9876")
        #expect(customer.address.street1 == "456 Oak Ave")
        #expect(customer.address.street2 == "Suite 200")
        #expect(customer.address.city == "Tampa")
        #expect((customer.estimates ?? []).isEmpty)
        #expect((customer.invoices ?? []).isEmpty)
    }

    /// Verifies deep surgical customization of all estimate options:
    /// materials vs labor, custom square footage, discounts, deposits, terms, and line additions/removals.
    @Test func conversationalEstimateItemizationAndSurgicalModifications() async throws {
        let world = try MBWriteWorld()
        // 1. Initial draft created
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID),
            "job_title": "Bathroom Remodel",
            "terms": "Net 30. 50% deposit required.",
            "groups": [[
                "name": "Wall Tile",
                "lines": [
                    ["name": "Subway Tile", "quantity": 100, "unit": "squareFoot", "unit_price": 5.0, "kind": "material", "taxable": true],
                    ["name": "Tile Setting", "quantity": 100, "unit": "squareFoot", "unit_price": 10.0, "kind": "labor", "taxable": false]
                ]
            ]]
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "estimate")
        let estimate = try #require(MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: world.context))
        let initialNumber = estimate.number
        #expect(estimate.terms == "Net 30. 50% deposit required.")

        let groupID = world.id(try #require(estimate.sortedGroups.first))
        let subwayTileLineID = world.id(try #require(estimate.sortedGroups.first?.sortedLineItems.first))

        // 2. Surgical edit: update subway tile square footage & price, add grout material, set 25% deposit, apply 5% discount
        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id),
            "deposit_type": "percentage",
            "deposit_value": 25,
            "discount_type": "percentage",
            "discount_value": 5,
            "customer_notes": "All materials included in price.",
            "lines": [
                ["line_id": .string(subwayTileLineID), "quantity": 120, "unit_price": 6.0],
                ["name": "Epoxy Grout", "quantity": 2, "unit": "item", "unit_price": 45.0, "kind": "material", "group_id": .string(groupID)]
            ]
        ])
        #expect(MBWriteHarness.titles(edited) == ["Updated estimate"])
        #expect(world.estimates().count == 1) // Invariant: no duplicate estimate minted
        #expect(estimate.number == initialNumber)
        #expect(estimate.depositValue == 25)
        #expect(estimate.discountValue == 5)
        #expect(estimate.customerNotes == "All materials included in price.")
        #expect(estimate.sortedGroups.first?.sortedLineItems.count == 3)
    }

    /// Verifies creation of an Options Estimate (combine_totals: false) with multiple distinct choices,
    /// and surgical addition of a new option tier without minting duplicates.
    @Test func optionsEstimateCreationAndSurgicalOptionRefinement() async throws {
        let world = try MBWriteWorld()
        // 1. Create an options estimate with two distinct option groups
        let created = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID),
            "job_title": "Flooring Options",
            "combine_totals": false,
            "groups": [
                [
                    "name": "Option 1 - Ceramic",
                    "note": "Standard ceramic tile",
                    "lines": [
                        ["name": "Ceramic Tile", "quantity": 300, "unit": "squareFoot", "unit_price": 3.0, "kind": "material", "taxable": true],
                        ["name": "Installation", "quantity": 300, "unit": "squareFoot", "unit_price": 7.0, "kind": "labor", "taxable": false]
                    ]
                ],
                [
                    "name": "Option 2 - Porcelain",
                    "note": "High-durability porcelain",
                    "lines": [
                        ["name": "Porcelain Tile", "quantity": 300, "unit": "squareFoot", "unit_price": 5.5, "kind": "material", "taxable": true],
                        ["name": "Installation", "quantity": 300, "unit": "squareFoot", "unit_price": 8.0, "kind": "labor", "taxable": false]
                    ]
                ]
            ]
        ])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "estimate")
        #expect(!id.isEmpty)
        let estimate = try #require(MBRecordLookup.record(.estimate, id: id, as: Estimate.self, in: world.context))
        #expect(estimate.combineTotals == false)
        #expect(estimate.isOptionsMode == true)
        #expect(estimate.sortedGroups.count == 2)

        // 2. Surgically add a third option tier (Option 3 - Marble)
        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(id),
            "lines": [
                [
                    "new_group": "Option 3 - Marble",
                    "name": "Italian Carrara Marble",
                    "quantity": 300,
                    "unit": "squareFoot",
                    "unit_price": 14.0,
                    "kind": "material",
                    "taxable": true
                ],
                [
                    "new_group": "Option 3 - Marble",
                    "name": "Precision Marble Installation",
                    "quantity": 300,
                    "unit": "squareFoot",
                    "unit_price": 12.0,
                    "kind": "labor",
                    "taxable": false
                ]
            ]
        ])
        #expect(MBWriteHarness.titles(edited) == ["Updated estimate"])
        #expect(world.estimates().count == 1) // Invariant: no duplicate document
        #expect(estimate.sortedGroups.count == 3)
        let option3 = try #require(estimate.sortedGroups.first { $0.name == "Option 3 - Marble" })
        #expect(option3.sortedLineItems.count == 2)
    }

    /// Verifies compound workflow creating a customer and immediately issuing a standalone invoice
    /// with materials, labor, and payment terms without an estimate intermediate.
    @Test func compoundCustomerAndStandaloneInvoiceCreation() async throws {
        let world = try MBWriteWorld()
        // 1. Add customer
        let customerOutcome = await MBWriteHarness.run(world.box, "save_customer", [
            "first_name": "Marcus",
            "last_name": "Vance",
            "email": "marcus.vance@example.com",
            "phone": "850-555-9012"
        ])
        let customerID = MBWriteHarness.id(MBWriteHarness.output(customerOutcome), "customer")
        #expect(!customerID.isEmpty)

        // 2. Create standalone invoice directly for that customer
        let invoiceOutcome = await MBWriteHarness.run(world.box, "create_invoice", [
            "customer_id": .string(customerID),
            "job_title": "Emergency Grout Repair",
            "payment_terms": "dueOnReceipt",
            "tax_rate_percent": 7.5,
            "groups": [[
                "name": "Repair Scope",
                "lines": [
                    ["name": "Grout Removal & Re-grouting", "quantity": 1, "unit": "job", "unit_price": 350.0, "kind": "labor", "taxable": false],
                    ["name": "Silicone Sealant & Grout", "quantity": 2, "unit": "item", "unit_price": 25.0, "kind": "material", "taxable": true]
                ]
            ]]
        ])
        let invoiceID = MBWriteHarness.id(MBWriteHarness.output(invoiceOutcome), "invoice")
        #expect(!invoiceID.isEmpty)
        let invoice = try #require(MBRecordLookup.record(.invoice, id: invoiceID, as: Invoice.self, in: world.context))
        #expect(invoice.customer?.fullName == "Marcus Vance")
        #expect(invoice.jobTitle == "Emergency Grout Repair")
        #expect(invoice.paymentTerms == .dueOnReceipt)
        #expect(invoice.subtotal == 400.0) // 350 + 50
        #expect(invoice.taxAmount == 3.75) // 50 * 7.5%
        #expect(invoice.total == 403.75)
        #expect(invoice.sourceEstimateNumber == nil)
    }
}
