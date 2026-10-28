//
//  CustomerTypedDeleteTests.swift
//  GLSmallBusinessTests
//
//  Owner ruling 2026-09-25 (7): a customer (client) is deleted only when the person asks, after
//  an alert that shows the client's name, says everything tied to them goes too, and needs the
//  name typed. The screens and the assistant use the same GoldLifeUI gate; every other delete
//  keeps the standard alert.
//

import Foundation
import GoldLifeAI
import GoldLifeUI
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct CustomerTypedDeleteTests {

    // MARK: - The name that is typed

    @Test func theTypedNameIsFirstAndLastElseTheBusinessElseNone() {
        #expect(CustomerDeleteConfirmation.typedName(first: "Ana", last: "Lopez", business: "Lopez Tile") == "Ana Lopez")
        #expect(CustomerDeleteConfirmation.typedName(first: "  Ana ", last: "", business: nil) == "Ana")
        #expect(CustomerDeleteConfirmation.typedName(first: "", last: "Lopez", business: nil) == "Lopez")
        #expect(CustomerDeleteConfirmation.typedName(first: "", last: " ", business: " Reed GC ") == "Reed GC")
        // Nothing to type: the standard alert asks instead, so the record never becomes undeletable.
        #expect(CustomerDeleteConfirmation.typedName(first: "", last: "", business: "  ") == nil)
        #expect(CustomerDeleteConfirmation.typedName(first: "", last: "", business: nil) == nil)

        let nameless = Customer(firstName: "")
        #expect(CustomerDeleteConfirmation.pending(for: nameless).typedName == nil)
        let named = Customer(firstName: "Mi", lastName: "Tran")
        #expect(CustomerDeleteConfirmation.pending(for: named).typedName == "Mi Tran")
    }

    /// The gate's own comparison (GoldLifeUI) accepts what a keyboard does on its own and nothing less.
    @Test func whatIsTypedMustBeTheWholeName() {
        #expect(GLTypedNameMatch.matches("ana lopez", "Ana Lopez"))
        #expect(GLTypedNameMatch.matches("Ana  López", "Ana Lopez"))
        #expect(!GLTypedNameMatch.matches("Ana", "Ana Lopez"))
        #expect(!GLTypedNameMatch.matches("", "Ana Lopez"))
    }

    @Test func theTitleNamesTheClientAndWarnsEverythingGoesInEnglishAndSpanish() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        MBLocalization.shared.language = .en
        #expect(CustomerDeleteConfirmation.title(name: "Ana Lopez")
                == "Delete Ana Lopez? Their estimates, invoices, change orders, receipts, and documents are removed too.")
        MBLocalization.shared.language = .es
        #expect(CustomerDeleteConfirmation.title(name: "Ana Lopez")
                == "¿Eliminar a Ana Lopez? Sus presupuestos, facturas, órdenes de cambio, recibos y documentos también se eliminan.")
    }

    /// Every string this change put on screen has its Spanish, with its placeholders intact —
    /// including GoldLifeUI's typed-name message, which resolves against this app's catalog.
    @Test func theNewStringsAreTranslated() throws {
        let url = GLSource.appRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "This can\u{2019}t be undone. To confirm, type the name: %@\n\nDelete turns on once what you type matches.",
            "Delete %@? Their estimates, invoices, change orders, receipts, and documents are removed too.",
            "Their estimates, invoices, change orders, receipts, and documents are removed too. This can\u{2019}t be undone.",
            "Pick the logo as a photo or a file so you can crop it.",
            "Delete this customer?",
            "Name",
        ]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing key: \(key)")
            let es = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = try #require(es?["value"] as? String, "no Spanish for: \(key)")
            #expect(!value.isEmpty && value != key)
            #expect(value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count,
                    "placeholders differ for: \(key)")
        }
    }

    // MARK: - The screens use the gate

    @Test func everyScreenThatDeletesACustomerAsksForTheTypedName() throws {
        let deleters = GLSource.files(under: GLSource.appRoot.appendingPathComponent("Screens"))
            .filter { $0.text.contains("DeletionService.Target.customer") }
        #expect(!deleters.isEmpty)
        for file in deleters {
            #expect(file.text.contains(".customerDeleteConfirmation("),
                    "\(file.path) deletes customers without the typed-name gate")
            #expect(!file.text.contains("\"Delete this customer?\""),
                    "\(file.path) still has the plain customer delete alert")
        }
        let gate = try #require(GLSource.file("UIComponents/CustomerDeleteConfirmation.swift"))
        #expect(gate.contains(".glTypedNameConfirmation("), "the gate is GoldLifeUI's, never a copy")
    }

    // MARK: - The assistant uses the gate

    @Test func theAssistantAsksForTheTypedNameOneClientPerCall() async throws {
        let world = try MBWriteWorld()
        let other = TS.customer(first: "Ana", last: "Lopez", business: nil, in: world.context)
        let estimate = TS.estimate(number: "EST-0042", in: world.context)
        world.context.saveChanges()
        let otherID = world.id(other)

        // Two clients in one call: split, so each is confirmed by its own name.
        let two = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "customer", "id": .string(world.customerID)],
                        ["kind": "customer", "id": .string(otherID)]],
        ])
        #expect(MBWriteHarness.failureReason(two) == "invalid_arguments")
        #expect(MBWriteHarness.failureMessage(two).contains("one customer per call"))

        // A client alongside anything else: the same.
        let mixed = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "customer", "id": .string(otherID)],
                        ["kind": "estimate", "id": .string(world.id(estimate))]],
        ])
        #expect(MBWriteHarness.failureReason(mixed) == "invalid_arguments")
        #expect(world.customers().count == 2 && world.estimates().count == 1, "nothing was deleted")

        // One client: the typed-name gate, naming them.
        let one = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "customer", "id": .string(otherID)]],
        ])
        let confirmation = try #require(MBWriteHarness.confirmation(one))
        #expect(confirmation.typedName == "Ana Lopez")
        #expect(GLAIStrings.english(confirmation.line).contains("Ana Lopez"))
        #expect(GLAIConfirmationRequest(items: [confirmation]).typedName == "Ana Lopez")

        // Any other kind keeps the standard alert.
        let plain = await MBWriteHarness.run(world.box, "delete", [
            "records": [["kind": "estimate", "id": .string(world.id(estimate))]],
        ])
        #expect(try #require(MBWriteHarness.confirmation(plain)).typedName == nil)
    }
}
