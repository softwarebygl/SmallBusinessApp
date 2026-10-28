//
//  MBAreaToolTests.swift
//  GLSmallBusinessTests — AI
//
//  The money, expenses, catalog and settings areas' write tools: each one does what the matching
//  form's Save does, refuses what the form refuses, asks the person where contract §5 says to ask,
//  and offers an Undo that puts the record back.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBAreaToolTests {

    // MARK: save_change_order / apply_change_order

    @Test func aChangeOrderIsCreatedEditedAndUndone() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0001", lines: [(1_000, false)], in: world.context)
        world.context.saveChanges()

        let created = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "title": "Extra shower niche",
            "items": [["name": "Niche", "quantity": .number(1), "unit_price": .number(350)]],
        ])
        let output = MBWriteHarness.output(created)
        #expect(output["change_order"]?["number"]?.stringValue?.hasPrefix("CO-") == true)
        #expect(MBWriteHarness.titles(created) == ["Created change order"])
        let orderID = MBWriteHarness.id(output, "change_order")

        // Editing replaces the whole item list, and a credit stays a credit.
        let edited = await MBWriteHarness.run(world.box, "save_change_order", [
            "id": .string(orderID),
            "items": [["name": "Credit for removed tile", "unit_price": .number(200), "is_credit": true]],
        ])
        _ = MBWriteHarness.output(edited)
        let order = try #require(MBRecordLookup.record(.changeOrder, id: orderID, as: ChangeOrder.self,
                                                       in: world.context))
        #expect(order.sortedLineItems.count == 1)
        #expect(order.sortedLineItems.first?.unitPrice == -200)

        // Undo puts the first item list back.
        let reverted = await MBWriteHarness.undoLatest(edited)
        guard case .reverted = reverted else {
            Issue.record("expected the edit to be undone")
            return
        }
        #expect(order.sortedLineItems.first?.name == "Niche")
    }

    @Test func aNewChangeOrderNeedsAnInvoiceAndAnItem() async throws {
        let world = try MBWriteWorld()
        let noInvoice = await MBWriteHarness.run(world.box, "save_change_order", [
            "title": "Extra work",
            "items": [["name": "Niche"]],
        ])
        #expect(MBWriteHarness.failureReason(noInvoice) == "invalid_arguments")

        let invoice = TS.invoice(number: "INV-0002", lines: [(500, false)], in: world.context)
        world.context.saveChanges()
        let noItems = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "title": "Extra work",
        ])
        #expect(MBWriteHarness.failureReason(noItems) == DomainError.itemRequired.code)
    }

    @Test func aChangeOrderOnAPaidInvoiceAsksFirst() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0003", lines: [(400, false)], in: world.context)
        TS.pay(invoice, 400, in: world.context)
        world.context.saveChanges()
        #expect(invoice.isMoneyLocked)

        let asked = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "items": [["name": "Extra tile", "unit_price": .number(120)]],
        ])
        #expect(MBWriteHarness.line(asked).contains("INV-0003"))
        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        // A confirmed change to a money-locked record keeps no Undo (contract §5).
        #expect(MBWriteHarness.undo(done) == nil)
    }

    @Test func applyingAChangeOrderNeedsItApprovedAndCanBeUndone() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0004", lines: [(900, false)], in: world.context)
        world.context.saveChanges()
        let created = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "items": [["name": "Extra tile", "unit_price": .number(250)]],
        ])
        let orderID = MBWriteHarness.id(MBWriteHarness.output(created), "change_order")

        let notApproved = await MBWriteHarness.run(world.box, "apply_change_order", ["id": .string(orderID)])
        #expect(MBWriteHarness.failureReason(notApproved) == DomainError.changeOrderNotApproved.code)
        #expect(MBWriteHarness.failureMessage(notApproved).contains("set_status"))

        _ = await MBWriteHarness.run(world.box, "set_status",
                                     ["kind": "change_order", "id": .string(orderID), "status": "approved"])
        let applied = await MBWriteHarness.run(world.box, "apply_change_order", ["id": .string(orderID)])
        _ = MBWriteHarness.output(applied)
        #expect(invoice.total == 1_150)

        let reverted = await MBWriteHarness.undoLatest(applied)
        guard case .reverted = reverted else {
            Issue.record("expected the apply to be undone")
            return
        }
        #expect(invoice.total == 900)
    }

    /// Editing an APPLIED order re-pushes its rows onto the invoice, so taking enough off can
    /// settle the invoice — and lock it. That door closes behind the person, so they are asked.
    @Test func editingAnAppliedChangeOrderThatWouldPayTheInvoiceAsksFirst() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0007", lines: [(1_000, false)], in: world.context)
        world.context.saveChanges()
        let created = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "items": [["name": "Extra tile", "unit_price": .number(500)]],
        ])
        let orderID = MBWriteHarness.id(MBWriteHarness.output(created), "change_order")
        _ = await MBWriteHarness.run(world.box, "set_status",
                                     ["kind": "change_order", "id": .string(orderID), "status": "approved"])
        _ = await MBWriteHarness.run(world.box, "apply_change_order", ["id": .string(orderID)])
        #expect(invoice.total == 1_500)
        TS.pay(invoice, 1_000, in: world.context)
        world.context.saveChanges()
        #expect(!invoice.isMoneyLocked)

        // Dropping the $500 leaves $1,000 billed against $1,000 paid: paid, and locked.
        let asked = await MBWriteHarness.run(world.box, "save_change_order", [
            "id": .string(orderID),
            "items": [["name": "Extra tile", "unit_price": .number(0)]],
        ])
        #expect(MBWriteHarness.line(asked).contains("INV-0007"))
        #expect(invoice.total == 1_500, "nothing is written before the person answers")
        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(invoice.isMoneyLocked)
        // Confirmed: no Undo to be dropped on sight afterwards (contract §5).
        #expect(MBWriteHarness.undo(done) == nil)
    }

    /// An edit that leaves the invoice unsettled still goes straight through, with its Undo.
    @Test func editingAnAppliedChangeOrderThatLeavesABalanceIsNotAsked() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(number: "INV-0008", lines: [(1_000, false)], in: world.context)
        world.context.saveChanges()
        let created = await MBWriteHarness.run(world.box, "save_change_order", [
            "invoice_id": .string(world.id(invoice)),
            "items": [["name": "Extra tile", "unit_price": .number(500)]],
        ])
        let orderID = MBWriteHarness.id(MBWriteHarness.output(created), "change_order")
        _ = await MBWriteHarness.run(world.box, "set_status",
                                     ["kind": "change_order", "id": .string(orderID), "status": "approved"])
        _ = await MBWriteHarness.run(world.box, "apply_change_order", ["id": .string(orderID)])

        let edited = await MBWriteHarness.run(world.box, "save_change_order", [
            "id": .string(orderID),
            "items": [["name": "Extra tile", "unit_price": .number(400)]],
        ])
        _ = MBWriteHarness.output(edited)
        #expect(invoice.total == 1_400)
        #expect(MBWriteHarness.undo(edited) != nil)
    }

    // MARK: save_receipt

    @Test func aReceiptIsAddedChangedAndUndone() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_receipt", [
            "vendor": "Floor & Decor", "total": .number(212.5), "category": "Materials",
            "date": "2026-09-20",
        ])
        let output = MBWriteHarness.output(created)
        // Money arrives in whole cents (law 60; a fraction of a cent is refused — WholeCentAmountTests).
        #expect(output["receipt"]?["total"]?.doubleValue == 212.50)
        #expect(MBWriteHarness.titles(created) == ["Added receipt"])
        let id = MBWriteHarness.id(output, "receipt")

        let edited = await MBWriteHarness.run(world.box, "save_receipt", [
            "id": .string(id), "customer_id": .string(world.customerID), "notes": "Master bath",
        ])
        _ = MBWriteHarness.output(edited)
        let receipt = try #require(MBRecordLookup.record(.receipt, id: id, as: Receipt.self, in: world.context))
        #expect(receipt.customer?.persistentModelID == world.customer.persistentModelID)
        #expect(receipt.vendor == "Floor & Decor")

        // null clears the customer again, and Undo restores the edit.
        let cleared = await MBWriteHarness.run(world.box, "save_receipt",
                                               ["id": .string(id), "customer_id": .null])
        _ = MBWriteHarness.output(cleared)
        #expect(receipt.customer == nil)
        let reverted = await MBWriteHarness.undoLatest(cleared)
        guard case .reverted = reverted else {
            Issue.record("expected the edit to be undone")
            return
        }
        #expect(receipt.customer?.persistentModelID == world.customer.persistentModelID)
    }

    @Test func aReceiptWithNothingOnItIsRefused() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "save_receipt", ["category": "Materials"])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.receiptDetailsRequired.code)
    }

    @Test func undoingANewReceiptDeletesIt() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_receipt",
                                               ["vendor": "Home Depot", "total": .number(40)])
        let id = MBWriteHarness.id(MBWriteHarness.output(created), "receipt")
        let reverted = await MBWriteHarness.undoLatest(created)
        guard case .reverted = reverted else {
            Issue.record("expected the receipt to be deleted")
            return
        }
        #expect(MBRecordLookup.record(.receipt, id: id, as: Receipt.self, in: world.context) == nil)
    }

    // MARK: save_price_item

    @Test func aPriceItemIsAddedAndItsPercentDiscountIsCapped() async throws {
        let world = try MBWriteWorld()
        let created = await MBWriteHarness.run(world.box, "save_price_item", [
            "name": "Porcelain tile", "category": "Tile", "unit": "squareFoot",
            "unit_price": .number(9.5), "kind": "material", "taxable": true,
        ])
        let output = MBWriteHarness.output(created)
        #expect(output["price_item"]?["unit"]?.stringValue == "squareFoot")
        let id = MBWriteHarness.id(output, "price_item")

        let overPercent = await MBWriteHarness.run(world.box, "save_price_item", [
            "id": .string(id), "discount_type": "percentage", "discount_value": .number(140),
        ])
        #expect(MBWriteHarness.failureReason(overPercent) == DomainError.percentOutOfRange.code)

        let raised = await MBWriteHarness.run(world.box, "save_price_item",
                                              ["id": .string(id), "unit_price": .number(10.5)])
        _ = MBWriteHarness.output(raised)
        let item = try #require(MBRecordLookup.record(.priceItem, id: id, as: PriceSheetItem.self,
                                                      in: world.context))
        #expect(item.unitPrice == 10.5)
        let reverted = await MBWriteHarness.undoLatest(raised)
        guard case .reverted = reverted else {
            Issue.record("expected the price to go back")
            return
        }
        #expect(item.unitPrice == 9.5)
    }

    @Test func aPriceItemNeedsAName() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "save_price_item", ["category": "Tile"])
        #expect(MBWriteHarness.failureReason(refused) == DomainError.itemNameRequired.code)
    }

    // MARK: save_project

    @Test func aProjectIsMadeAroundAJobAndItsJobsChange() async throws {
        let world = try MBWriteWorld()
        let first = TS.job("Master bath", start: MBToolHarness.now, customer: world.customer, in: world.context)
        let second = TS.job("Guest bath", start: MBToolHarness.now, customer: world.customer, in: world.context)
        world.context.saveChanges()

        let noJob = await MBWriteHarness.run(world.box, "save_project", ["name": "Whole house"])
        #expect(MBWriteHarness.failureReason(noJob) == "job_required")

        let created = await MBWriteHarness.run(world.box, "save_project", [
            "name": "Whole house", "add_job_ids": [.string(world.id(first))],
        ])
        let projectID = MBWriteHarness.id(MBWriteHarness.output(created), "project")
        #expect(first.project?.name == "Whole house")

        let grown = await MBWriteHarness.run(world.box, "save_project", [
            "id": .string(projectID), "name": "Remodel", "add_job_ids": [.string(world.id(second))],
        ])
        _ = MBWriteHarness.output(grown)
        #expect(second.project?.name == "Remodel")

        // Undo puts the name and the job list back.
        let reverted = await MBWriteHarness.undoLatest(grown)
        guard case .reverted = reverted else {
            Issue.record("expected the project edit to be undone")
            return
        }
        #expect(second.project == nil)
        #expect(first.project?.name == "Whole house")
    }

    // MARK: update_business

    @Test func changingContactDetailsAsksWithTheOldAndNewValues() async throws {
        let world = try MBWriteWorld()
        let asked = await MBWriteHarness.run(world.box, "update_business", [
            "email": "new@goldtile.example", "business_name": "Gold Tile Co",
        ])
        let line = MBWriteHarness.line(asked)
        #expect(line.contains("office@goldtile.example"))
        #expect(line.contains("new@goldtile.example"))

        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.email == "new@goldtile.example")
        #expect(MBWriteHarness.titles(done) == ["Updated business details"])
    }

    @Test func changingOnlyTheWebsiteJustSavesAndCanBeUndone() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_business",
                                            ["website_url": "https://goldtile.example"])
        _ = MBWriteHarness.output(done)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.websiteURL == "https://goldtile.example")
        let reverted = await MBWriteHarness.undoLatest(done)
        guard case .reverted = reverted else {
            Issue.record("expected the website to go back")
            return
        }
        #expect(MBRecordLookup.businessProfile(in: world.context)?.websiteURL == "")
    }

    @Test func aBusinessCallWithNoFieldsIsRefused() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "update_business", [:])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
    }

    /// Contract §5's confirm list is contact / payment-instruction / message-template /
    /// review-link. The address prints on every document, the warranty text is template wording,
    /// and the receipts switch IS the review link — each gets its old → new line.
    @Test func theAddressWarrantyAndReviewSwitchAlsoAskFirst() async throws {
        let world = try MBWriteWorld()
        let asked = await MBWriteHarness.run(world.box, "update_business", [
            "address": ["street1": "4120 Capital Circle", "city": "Miami", "state": "FL"],
        ])
        let line = MBWriteHarness.line(asked)
        #expect(line.contains("4120 Capital Circle"))
        #expect(MBRecordLookup.businessProfile(in: world.context)?.address.street1 == "",
                "nothing moves before the person answers")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(asked))
        #expect(MBRecordLookup.businessProfile(in: world.context)?.address.street1 == "4120 Capital Circle")

        let warranty = await MBWriteHarness.run(world.box, "update_business",
                                                ["warranty_text": "One year on all labor."])
        #expect(MBWriteHarness.line(warranty).contains("One year on all labor."))
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(warranty))
        #expect(MBRecordLookup.businessProfile(in: world.context)?.warrantyText == "One year on all labor.")

        let switched = await MBWriteHarness.run(world.box, "update_business",
                                                ["review_link_on_receipts": true])
        #expect(!MBWriteHarness.line(switched).isEmpty)
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(switched))
        #expect(MBRecordLookup.businessProfile(in: world.context)?.includeReviewLinkOnReceipts == true)
    }

    // MARK: update_work_schedule

    @Test func theWorkScheduleTakesEachKindOfChange() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_work_schedule", [
            "weekdays": [["day": "saturday", "works": true, "start": "08:00", "end": "13:00"]],
            "holidays": [["id": "us.christmas", "off": true]],
            "add_time_off": [["start": "2026-12-24", "end": "2026-12-26"]],
        ])
        let output = MBWriteHarness.output(done)
        #expect(output["work_schedule"] != nil)
        let schedule = WorkScheduleService.current(in: world.context)
        #expect(schedule.weekdayHours[6].isWorkday)
        #expect(schedule.weekdayHours[6].startMinutes == 8 * 60)
        #expect(schedule.isHolidayOff("us.christmas"))
        #expect(schedule.vacations.count == 1)

        let reverted = await MBWriteHarness.undoLatest(done)
        guard case .reverted = reverted else {
            Issue.record("expected the schedule to go back")
            return
        }
        #expect(WorkScheduleService.current(in: world.context).vacations.isEmpty)
    }

    @Test func aBadClockTimeIsRefusedAndNothingIsWritten() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "update_work_schedule", [
            "weekdays": [["day": "monday", "start": "8am"]],
        ])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
    }

    // MARK: update_app_settings

    @Test func appSettingsWriteOnlyTheAppsOwnPreferences() async throws {
        let world = try MBWriteWorld()
        let before = AppSettingsService.language
        let done = await MBWriteHarness.run(world.box, "update_app_settings", [
            "book_one_job_at_a_time": false, "logo_on_documents": false, "email_extra_line": "Thanks!",
        ])
        _ = MBWriteHarness.output(done)
        #expect(AppSettingsService.oneJobAtATime() == false)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.showLogoOnDocuments == false)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.emailSignatureText == "Thanks!")
        // The language wasn't sent, so it is untouched.
        #expect(AppSettingsService.language == before)

        let reverted = await MBWriteHarness.undoLatest(done)
        guard case .reverted = reverted else {
            Issue.record("expected the settings to go back")
            return
        }
        #expect(AppSettingsService.oneJobAtATime() == true)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.showLogoOnDocuments == true)
    }

    /// There is no `updatedAt` on a preference, so Undo can't tell whether the person changed one
    /// by hand in between. It therefore puts back ONLY what this call wrote.
    @Test func appSettingsUndoLeavesSettingsThisCallNeverTouched() async throws {
        let world = try MBWriteWorld()
        let done = await MBWriteHarness.run(world.box, "update_app_settings",
                                            ["book_one_job_at_a_time": false])
        _ = MBWriteHarness.output(done)
        #expect(AppSettingsService.oneJobAtATime() == false)

        // The person flips a different switch by hand, in Settings, before tapping Undo.
        try DomainState.subscribed.run {
            try BusinessProfileService.setDisplay(.logoOnDocuments, false, in: world.context)
        }
        #expect(MBRecordLookup.businessProfile(in: world.context)?.showLogoOnDocuments == false)

        let reverted = await MBWriteHarness.undoLatest(done)
        guard case .reverted = reverted else {
            Issue.record("expected the one setting to go back")
            return
        }
        #expect(AppSettingsService.oneJobAtATime() == true)
        #expect(MBRecordLookup.businessProfile(in: world.context)?.showLogoOnDocuments == false,
                "the hand-made change stands")
    }

    @Test func anEmptyAppSettingsCallIsRefused() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "update_app_settings", [:])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
    }

    // MARK: set_document

    @Test func aCertificateExpiryIsSetAndCleared() async throws {
        let world = try MBWriteWorld()
        let set = await MBWriteHarness.run(world.box, "set_document", [
            "document": "customer_coi", "action": "set_expiry",
            "id": .string(world.customerID), "expires_on": "2027-03-01",
        ])
        _ = MBWriteHarness.output(set)
        #expect(world.customer.coiExpiresOn != nil)
        #expect(MBWriteHarness.titles(set) == ["Updated document"])

        let cleared = await MBWriteHarness.run(world.box, "set_document", [
            "document": "customer_coi", "action": "clear_expiry", "id": .string(world.customerID),
        ])
        _ = MBWriteHarness.output(cleared)
        #expect(world.customer.coiExpiresOn == nil)
    }

    @Test func aDocumentWithNoExpiryRefusesOneAndARemovalAsksFirst() async throws {
        let world = try MBWriteWorld()
        let noExpiry = await MBWriteHarness.run(world.box, "set_document", [
            "document": "project_agreement", "action": "set_expiry", "expires_on": "2027-01-01",
        ])
        #expect(MBWriteHarness.failureReason(noExpiry) == DomainError.noExpiry.code)

        world.customer.coiData = Data("cert".utf8)
        world.customer.coiName = "COI.pdf"
        world.context.saveChanges()
        let asked = await MBWriteHarness.run(world.box, "set_document", [
            "document": "customer_coi", "action": "remove", "id": .string(world.customerID),
        ])
        #expect(MBWriteHarness.confirmation(asked)?.isDestructive == true)
        let done = await MBWriteHarness.confirm(asked)
        _ = MBWriteHarness.output(done)
        #expect(world.customer.coiData == nil)
        #expect(MBWriteHarness.undo(done) == nil)
    }

    /// Tax data stays on its own screen (contract §5 quarantine).
    @Test func theSubcontractorW9StaysOnItsOwnScreen() async throws {
        let world = try MBWriteWorld()
        let refused = await MBWriteHarness.run(world.box, "set_document",
                                               ["document": "subcontractor_w9", "action": "remove"])
        #expect(MBWriteHarness.failureReason(refused) == "not_available")
    }

    /// Photos and logos are removed as the manifest promises (found 2026-09-29: it refused),
    /// after the standard confirmation (law 58: a delete asks first), through the same services
    /// the screens use; nothing on file says so without asking.
    @Test func aLogoOrAPhotoIsRemovedAfterTheConfirmation() async throws {
        let world = try MBWriteWorld()
        let profile = try #require(MBRecordLookup.businessProfile(in: world.context))
        profile.logoData = Data("logo".utf8)
        profile.logoDataDark = Data("dark".utf8)
        world.customer.profileImageData = Data("face".utf8)
        world.context.saveChanges()

        let logo = await MBWriteHarness.run(world.box, "set_document", ["document": "business_logo", "action": "remove"])
        #expect(MBWriteHarness.confirmation(logo)?.isDestructive == true)
        #expect(MBWriteHarness.line(logo) == "Remove Logo")
        #expect(profile.logoData != nil, "nothing changes before the person confirms")
        _ = MBWriteHarness.output(await MBWriteHarness.confirm(logo))
        #expect(profile.logoData == nil && profile.logoDataDark != nil, "only the light logo")

        let photo = await MBWriteHarness.run(world.box, "set_document",
                                             ["document": "customer_photo", "action": "remove",
                                              "id": .string(world.customerID)])
        let done = await MBWriteHarness.confirm(photo)
        _ = MBWriteHarness.output(done)
        #expect(world.customer.profileImageData == nil)
        #expect(MBWriteHarness.titles(done) == ["Removed document"])

        let again = await MBWriteHarness.run(world.box, "set_document",
                                             ["document": "customer_photo", "action": "remove",
                                              "id": .string(world.customerID)])
        #expect(MBWriteHarness.failureReason(again) == "not_on_file")
        let noID = await MBWriteHarness.run(world.box, "set_document", ["document": "employee_photo", "action": "remove"])
        #expect(MBWriteHarness.failureReason(noID) == "not_found")

        // A lapsed app refuses the write when confirmed, like the screen.
        let dark = await MBWriteHarness.run(world.box, "set_document", ["document": "business_logo_dark", "action": "remove"])
        _ = await MBWriteHarness.confirm(dark, state: .lapsed)
        #expect(profile.logoDataDark != nil)
    }
}
