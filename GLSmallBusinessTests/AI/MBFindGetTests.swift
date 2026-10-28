//
//  MBFindGetTests.swift
//  GLSmallBusinessTests — AI
//
//  find → get round trips, the app's own filters (derived statuses, date ranges, people,
//  repeating jobs), id minting for rows that have none, paging long documents without losing a
//  line, and the output budgets: 8 KB online (`truncated: true`), 1,200 characters on device.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBFindGetTests {

    // MARK: - Round trips

    @Test func findThenGetRoundTripsEveryKind() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let expected: [MBRecordKind: String?] = [
            .customer: world.customer.syncID?.uuidString, .estimate: world.estimate.syncID?.uuidString,
            .invoice: world.invoice.syncID?.uuidString, .changeOrder: world.changeOrder.syncID?.uuidString,
            .job: world.job.syncID?.uuidString, .receipt: world.receipt.syncID?.uuidString,
            .employee: world.employee.syncID?.uuidString, .subcontractor: world.subcontractor.syncID?.uuidString,
            .project: world.project.syncID?.uuidString, .payment: world.payment.syncID?.uuidString,
            .paycheck: world.paycheck.syncID?.uuidString, .document: world.document.syncID?.uuidString,
        ]
        for (kind, id) in expected {
            let found = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": .string(kind.rawValue)]))
            #expect(found["kind"]?.stringValue == kind.rawValue)
            let ids = MBToolHarness.ids(found)
            #expect(ids.contains(id ?? "missing"), "find \(kind.rawValue) hands out the record's syncID")
            let got = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": .string(kind.rawValue), "id": .string(id ?? "")]))
            #expect(got["id"]?.stringValue == id, "get \(kind.rawValue) round-trips")
            #expect(got["kind"]?.stringValue == kind.rawValue)
            #expect(got["ok"]?.boolValue == true)
        }
    }

    @Test func getReturnsTotalsBalancesPaymentsAndChildIDs() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let invoice = MBToolHarness.output(await MBToolHarness.run(
            box, "get", ["kind": "invoice", "id": .string(world.invoice.syncID?.uuidString ?? "")]))
        #expect(invoice["number"]?.stringValue == "INV-0007")
        #expect(invoice["totals"]?["total"]?.doubleValue == DomainMoney.roundedToCents(world.invoice.total))
        #expect(invoice["totals"]?["balance_due"]?.doubleValue == DomainMoney.roundedToCents(world.invoice.balanceDue))
        #expect(invoice["payments"]?[0]?["id"]?.stringValue == world.payment.syncID?.uuidString)
        #expect(invoice["payments"]?[0]?["method"]?.stringValue == "card")
        #expect(invoice["change_orders"]?[0]?["id"]?.stringValue == world.changeOrder.syncID?.uuidString)
        #expect(invoice["job"]?["id"]?.stringValue == world.job.syncID?.uuidString)
        #expect(invoice["amount_due_now"]?.doubleValue == 200)
        let lineIDs = (invoice["lines"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        #expect(Set(lineIDs) == Set(world.invoice.allLineItems.compactMap { $0.syncID?.uuidString }))
        let groupID = world.invoice.sortedGroups.first?.syncID?.uuidString
        #expect(invoice["groups"]?[0]?["id"]?.stringValue == groupID)
        #expect(invoice["lines"]?[0]?["group_id"]?.stringValue == groupID)

        // A change order's credit line reads as a credit with a positive price.
        let order = MBToolHarness.output(await MBToolHarness.run(
            box, "get", ["kind": "change_order", "id": .string(world.changeOrder.syncID?.uuidString ?? "")]))
        let credit = order["lines"]?.arrayValue?.first { $0["is_credit"]?.boolValue == true }
        #expect(credit?["unit_price"]?.doubleValue == 150)

        // The receipt's read-off text comes back; its scan never does.
        let receipt = MBToolHarness.output(await MBToolHarness.run(
            box, "get", ["kind": "receipt", "id": .string(world.receipt.syncID?.uuidString ?? "")]))
        #expect(receipt["receipt_text"]?.stringValue?.contains("GROUT") == true)
        #expect(receipt["has_attached_file"]?.boolValue == true)

        // The estimate knows which invoice it became (none yet) and its deposit.
        let estimate = MBToolHarness.output(await MBToolHarness.run(
            box, "get", ["kind": "estimate", "id": .string(world.estimate.syncID?.uuidString ?? "")]))
        #expect(estimate["totals"]?["deposit"]?.doubleValue == DomainMoney.roundedToCents(world.estimate.depositAmount))
        #expect(estimate["invoice"] == .null)
    }

    @Test func singletonsNeedNoID() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let business = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "business"]))
        #expect(business["business_name"]?.stringValue == "Gold Tile Co")
        #expect(business["license"]?["expired"]?.boolValue == true)
        let schedule = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "work_schedule"]))
        #expect(schedule["weekdays"]?.arrayValue?.count == 7)
        #expect(schedule["weekdays"]?[1]?["day"]?.stringValue == "monday")
        #expect(schedule["weekdays"]?[1]?["works"]?.boolValue == true)
        let settings = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "app_settings"]))
        #expect(settings["language"]?.stringValue != nil)
        #expect(settings["book_one_job_at_a_time"]?.boolValue != nil)
        // A record kind without an id is the model's slip — never a "Not done" row.
        let outcome = await MBToolHarness.run(box, "get", ["kind": "invoice"])
        #expect(MBToolHarness.failureReason(outcome) == "invalid_arguments")
        if case .failure(let failure) = outcome { #expect(!failure.showsToPerson) }
    }

    // MARK: - Filters

    @Test func findFiltersByDerivedStatusCustomerAndDates() async throws {
        let context = try DomainFixtures.context()
        let cal = TS.calendar
        let now = MBToolHarness.now
        let maria = TS.customer(first: "Maria", last: "Lopez", email: "maria@example.com", phone: "555-0101", business: nil, in: context)
        let reed = TS.customer(in: context)
        let paid = TS.invoice(number: "INV-0001", createdAt: TS.day(2026, 3, 1), status: .sent, in: context)
        paid.customer = maria
        TS.pay(paid, 1000, date: TS.day(2026, 3, 5), in: context)
        let overdue = TS.invoice(number: "INV-0002", createdAt: TS.day(2026, 6, 1), status: .sent, in: context)
        overdue.customer = maria
        overdue.dueDate = TS.day(2026, 7, 1)
        let draft = TS.invoice(number: "INV-0003", createdAt: TS.day(2026, 9, 1), status: .draft, in: context)
        draft.customer = reed
        let expired = TS.estimate(number: "EST-0001", createdAt: TS.day(2026, 1, 1), status: .sent, in: context)
        expired.validUntil = TS.day(2026, 2, 1)
        let open = TS.estimate(number: "EST-0002", createdAt: now, status: .sent, in: context)
        open.validUntil = cal.date(byAdding: .day, value: 400, to: .now) ?? .now
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        func numbers(_ args: GLAIJSON) async -> [String] {
            MBToolHarness.results(MBToolHarness.output(await MBToolHarness.run(box, "find", args)))
                .compactMap { $0["number"]?.stringValue }
        }
        #expect(await numbers(["kind": "invoice", "status": "paid"]) == ["INV-0001"])
        #expect(await numbers(["kind": "invoice", "status": "overdue"]) == ["INV-0002"])
        #expect(await numbers(["kind": "invoice", "status": "unpaid"]) == ["INV-0003", "INV-0002"])
        #expect(await numbers(["kind": "invoice", "status": "draft"]) == ["INV-0003"])
        #expect(await numbers(["kind": "invoice", "customer_id": .string(maria.syncID?.uuidString ?? "")]) == ["INV-0002", "INV-0001"])
        #expect(await numbers(["kind": "invoice", "date_from": "2026-05-01", "date_to": "2026-06-30"]) == ["INV-0002"])
        #expect(await numbers(["kind": "invoice", "query": "INV-0003"]) == ["INV-0003"])
        #expect(await numbers(["kind": "estimate", "status": "expired"]) == ["EST-0001"])
        #expect(await numbers(["kind": "estimate", "status": "sent"]) == ["EST-0002"])

        // Search by the customer's phone, like the Customers list.
        let byPhone = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "customer", "query": "555-0101"]))
        #expect(MBToolHarness.ids(byPhone) == [maria.syncID?.uuidString ?? ""])

        // The model's slips come back as invalid arguments / not found, never a crash.
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "find", ["kind": "customer", "status": "paid"])) == "invalid_arguments")
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "find", ["kind": "invoice", "date_from": "June 1"])) == "invalid_arguments")
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "find", ["kind": "invoice", "customer_id": .string(UUID().uuidString)])) == "not_found")
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "find", ["kind": "business"])) == "invalid_arguments")
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": "not-an-id"])) == "not_found")
    }

    @Test func findJobsInADateRangeIncludesRepeats() async throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        // Weekly on Mondays from 2026-08-03, and a one-off two-day job on 2026-09-24.
        let weekly = TS.job("Lawn care", start: TS.day(2026, 8, 3), customer: customer, recurrence: .weekly, in: context)
        let oneOff = TS.job("Deck", start: TS.day(2026, 9, 24), days: 2, customer: customer, in: context)
        TS.job("Old job", start: TS.day(2026, 5, 1), customer: customer, status: .completed, in: context)
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        let week = MBToolHarness.output(await MBToolHarness.run(
            box, "find", ["kind": "job", "date_from": "2026-09-21", "date_to": "2026-09-27"]))
        #expect(Set(MBToolHarness.ids(week)) == [weekly.syncID?.uuidString ?? "", oneOff.syncID?.uuidString ?? ""])
        // A two-day job that started before the range still counts on its second day.
        let friday = MBToolHarness.output(await MBToolHarness.run(
            box, "find", ["kind": "job", "date_from": "2026-09-25", "date_to": "2026-09-25"]))
        #expect(MBToolHarness.ids(friday) == [oneOff.syncID?.uuidString ?? ""])
        let done = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "job", "status": "completed"]))
        #expect(MBToolHarness.results(done).first?["title"]?.stringValue == "Old job")
    }

    @Test func findPeopleRecordsByPersonAndOwedStatus() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let employeeID = world.employee.syncID?.uuidString ?? ""
        let owed = MBToolHarness.output(await MBToolHarness.run(
            box, "find", ["kind": "time_entry", "person_id": .string(employeeID), "status": "owed"]))
        #expect(MBToolHarness.results(owed).allSatisfy { $0["paid"]?.boolValue == false })
        #expect(owed["count"]?.intValue == 2, "neither entry is on a paycheck")
        let subOwed = MBToolHarness.output(await MBToolHarness.run(
            box, "find", ["kind": "sub_payment", "person_id": .string(world.subcontractor.syncID?.uuidString ?? ""), "status": "owed"]))
        #expect(MBToolHarness.ids(subOwed) == [world.subPayment.syncID?.uuidString ?? ""])
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(
            box, "find", ["kind": "time_entry", "person_id": .string(UUID().uuidString)])) == "invalid_arguments")
    }

    // MARK: - Words

    /// The AI eval bug: "John Smith" and "Mike Rivera" found nobody, because find matched the
    /// whole query against one field at a time and first and last names are separate fields.
    /// Every word now has to match some field (`RecordSearch.matches`, the lists' own matcher),
    /// in any order, ignoring case and accents — and one matching word is never enough.
    @Test func findMatchesEveryWordOfANameAcrossFields() async throws {
        let context = try DomainFixtures.context()
        let john = TS.customer(first: "John", last: "Smith", email: "john@example.com", phone: "555-0110",
                               business: nil, in: context)
        let rivera = TS.customer(first: "John", last: "Rivera", email: "", phone: "",
                                 business: "Rivera Tile & Stone", in: context)
        let jose = TS.customer(first: "José", last: "Núñez", email: "", phone: "", business: nil, in: context)
        let mike = TS.employee(first: "Mike", last: "Rivera", in: context)
        _ = TS.employee(first: "Mike", last: "Smith", in: context)
        let invoice = TS.invoice(number: "INV-0042", status: .sent, in: context)
        invoice.customer = john
        invoice.customerFirstName = "John"
        invoice.customerLastName = "Smith"
        let job = TS.job("Deck repair", start: TS.day(2026, 9, 1), customer: john, in: context)
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        func found(_ args: GLAIJSON) async -> GLAIJSON {
            MBToolHarness.output(await MBToolHarness.run(box, "find", args))
        }
        func ids(_ args: GLAIJSON) async -> [String] { MBToolHarness.ids(await found(args)) }

        // The tool hands back the record itself: its id, its name, one match.
        let smith = await found(["kind": "customer", "query": "John Smith"])
        #expect(smith["count"]?.intValue == 1)
        #expect(MBToolHarness.results(smith).first?["name"]?.stringValue == "John Smith")
        let johnID = john.syncID?.uuidString ?? "missing"
        #expect(MBToolHarness.ids(smith) == [johnID])
        #expect(await ids(["kind": "customer", "query": "smith john"]) == [johnID])
        // One matching word is not a match: "John Rivera" is the other John, never John Smith.
        #expect(await ids(["kind": "customer", "query": "John Rivera"]) == [rivera.syncID?.uuidString ?? "missing"])
        #expect(await ids(["kind": "customer", "query": "John Nobody"]).isEmpty)
        // Accents, both ways.
        let joseID = jose.syncID?.uuidString ?? "missing"
        #expect(await ids(["kind": "customer", "query": "jose nunez"]) == [joseID])
        #expect(await ids(["kind": "customer", "query": "José"]) == [joseID])
        // A business name, with or without a person's name alongside it.
        #expect(await ids(["kind": "customer", "query": "rivera tile"]) == [rivera.syncID?.uuidString ?? "missing"])
        #expect(await ids(["kind": "customer", "query": "john rivera stone"]) == [rivera.syncID?.uuidString ?? "missing"])
        // A single word behaves as it always did.
        #expect(await ids(["kind": "customer", "query": "john"]).count == 2)
        #expect(await ids(["kind": "customer", "query": "555-0110"]) == [johnID])

        // People, documents and jobs take several words too.
        let mikeRows = await ids(["kind": "employee", "query": "Mike Rivera"])
        #expect(mikeRows == [mike.syncID?.uuidString ?? "missing"])
        let invoiceID = invoice.syncID?.uuidString ?? "missing"
        #expect(await ids(["kind": "invoice", "query": "INV-0042"]) == [invoiceID])
        #expect(await ids(["kind": "invoice", "query": "John Smith"]) == [invoiceID])
        #expect(await ids(["kind": "invoice", "query": "John Rivera"]).isEmpty)
        #expect(await ids(["kind": "job", "query": "deck john smith"]) == [job.syncID?.uuidString ?? "missing"])
        #expect(await ids(["kind": "job", "query": "deck rivera"]).isEmpty)
    }

    // MARK: - Ids

    /// A row with no syncID yet (written before ids existed, or pulled from an old build) gets one
    /// on first read — the same id every later read hands out.
    @Test func aRowWithoutAnIDIsGivenOneOnFirstRead() async throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(first: "Old", last: "Timer", in: context)
        try context.save()                     // a plain save: no syncID minted
        #expect(customer.syncID == nil)
        let item = PriceSheetItem(name: "Grout", unitPrice: 12)
        context.insert(item)
        try context.save()
        let box = try MBToolHarness.toolbox(context)

        let first = MBToolHarness.ids(MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "customer"])))
        #expect(first.count == 1)
        #expect(customer.syncID?.uuidString == first.first)
        let again = MBToolHarness.ids(MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "customer"])))
        #expect(again == first)
        let items = MBToolHarness.ids(MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "price_item"])))
        #expect(items == [item.syncID?.uuidString ?? "missing"])
        let got = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "price_item", "id": .string(items.first ?? "")]))
        #expect(got["name"]?.stringValue == "Grout")
    }

    // MARK: - Budgets and paging

    @Test func findStaysUnder8KBAndSaysWhenItTrimmed() async throws {
        let context = try DomainFixtures.context()
        let long = String(repeating: "Long name ", count: 12)
        for index in 0..<80 {
            TS.customer(first: "\(long)\(index)", last: long, email: "\(index)@\(long).example".replacingOccurrences(of: " ", with: ""),
                        phone: "555-\(index)", business: long, in: context)
        }
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)
        let output = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "customer", "limit": 50]))
        #expect(output.serializedByteCount <= GLAIWire.maxToolOutputBytes)
        #expect(output["truncated"]?.boolValue == true)
        #expect(output["count"]?.intValue == 80)
        let shown = MBToolHarness.results(output).count
        #expect(shown > 0 && shown < 50)
        #expect(output["omitted"]?["results"]?.intValue == 50 - shown)

        let small = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "customer", "limit": 3]))
        #expect(MBToolHarness.results(small).count == 3)
        #expect(small["more"]?.intValue == 77)
        #expect(small["truncated"] == nil)
    }

    @Test func longInvoicesPageWithoutLosingALine() async throws {
        let context = try DomainFixtures.context()
        let details = String(repeating: "Set tile on the shower walls with a leveling system. ", count: 6)
        let invoice = TS.invoice(number: "INV-0099", status: .sent, lines: Array(repeating: (25.0, true), count: 130), in: context)
        invoice.customerNotes = String(repeating: "Notes. ", count: 400)
        for line in invoice.allLineItems { line.details = details }
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)
        let id = invoice.syncID?.uuidString ?? ""

        let first = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id)]))
        let pages = first["pages"]?.intValue ?? 0
        #expect(pages > 1)
        #expect(first["line_count"]?.intValue == 130)
        var seen: [String] = []
        for page in 1...max(1, pages) {
            let output = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id), "page": .number(Double(page))]))
            #expect(output.serializedByteCount <= GLAIWire.maxToolOutputBytes, "page \(page)")
            #expect(output["truncated"] == nil, "page \(page) was packed to fit, never trimmed")
            #expect(output["page"]?.intValue == page)
            seen += (output["lines"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            if page > 1 { #expect(output["totals"] == nil, "later pages carry lines only") }
        }
        let expected = invoice.allLineItems.compactMap { $0.syncID?.uuidString }
        #expect(seen == expected, "every line once, in order")
        let pastEnd = await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id), "page": .number(Double(pages + 1))])
        #expect(MBToolHarness.failureReason(pastEnd) == "invalid_arguments")
        // Paging is stable: the same page twice is the same bytes.
        let twiceA = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id), "page": 2]))
        let twiceB = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id), "page": 2]))
        #expect(twiceA == twiceB)
    }

    @Test func onDeviceAnswersAreShort() async throws {
        let world = try MBToolWorld()
        for index in 0..<12 {
            let invoice = TS.invoice(number: String(format: "INV-1%03d", index), status: .sent,
                                     lines: Array(repeating: (100.0, false), count: 12), in: world.context)
            invoice.customer = TS.customer(first: "Customer \(index)", last: "Name", in: world.context)
        }
        world.context.saveChanges()
        let box = try MBToolHarness.toolbox(world.context)
        let found = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": "invoice", "limit": 5], onDevice: true))
        #expect(MBToolHarness.results(found).count <= 5)
        #expect(found["more"] != nil)
        #expect(found.serializedString.count <= 1_200)
        let id = MBToolHarness.ids(found).first ?? ""
        let got = MBToolHarness.output(await MBToolHarness.run(box, "get", ["kind": "invoice", "id": .string(id)], onDevice: true))
        #expect(got.serializedString.count <= 1_200)
        #expect((got["lines"]?.arrayValue?.count ?? 0) <= 5)
        let owed = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "owed_to_me"], onDevice: true))
        #expect(owed.serializedString.count <= 1_200)
        #expect(owed["total_owed"] != nil, "totals survive the trim")
    }
}
