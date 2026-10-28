//
//  WholeCentAmountTests.swift
//  GLSmallBusinessTests
//
//  MONEY IS ENTERED IN WHOLE CENTS (REQUIREMENTS law 60, owner ruling 2026-09-27: "Why would i
//  ever accept a payment that is a fraction of a cent?"). An AMOUNT (a payment, a receipt total, a
//  deposit in dollars, a flat entry, a paycheck, a bonus, an amount due, an agreed price) takes at
//  most two decimals, on the form AND through the assistant; prices, rates and percentages keep
//  their precision and the amount made from them rounds once.
//
//  What is pinned here, each with its own instrument:
//    • the rule itself: `DomainMoney.isWholeCents` on the amount as written, and the keystroke rule
//      a field applies (`NumberParsing.allowsWholeCents`), in a dot and a comma locale;
//    • the forms (a source scan): every amount field refuses a third decimal, every price, rate,
//      percentage, hour and quantity field keeps it, and no money field is left unsorted or outside
//      the one number field that can refuse a keystroke;
//    • the assistant: every amount argument of every tool, sent with a fraction of a cent, is
//      refused with `invalid_arguments` before anything is written or anyone is asked, and the same
//      call in whole cents is not; a deposit is held to it only when it is in dollars;
//    • the manifest: every number argument is sorted into amounts or kept-as-sent values, and every
//      tool that takes an amount is bound behind the gate.
//  The keystroke itself is exercised on the real receipt form by `WholeCentEntryUITests`.
//

import Testing
import Foundation
import SwiftData
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct WholeCentAmountTests {

    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")   // grouping ".", decimal ","

    // MARK: - The rule

    @Test func wholeCentsIsReadOnTheAmountAsWritten() {
        for value in [0.0, 12, 12.3, 12.35, 1_000.01, 327.97, 0.3, 999_999_999.99] {
            #expect(DomainMoney.isWholeCents(value), "\(value)")
        }
        for value in [12.345, 0.001, 1.005, 2_500.005, 0.1 + 0.2, 99.999, 212.499] {
            #expect(!DomainMoney.isWholeCents(value), "\(value)")
        }
        #expect(!DomainMoney.isWholeCents(.infinity))
        #expect(!DomainMoney.isWholeCents(.nan))
    }

    @Test func fractionDigitsCountWhatFollowsTheSeparator() {
        #expect(NumberParsing.fractionDigits(in: "", locale: us) == 0)
        #expect(NumberParsing.fractionDigits(in: "12", locale: us) == 0)
        #expect(NumberParsing.fractionDigits(in: "12.", locale: us) == 0)
        #expect(NumberParsing.fractionDigits(in: "12.5", locale: us) == 1)
        #expect(NumberParsing.fractionDigits(in: "$1,234.56", locale: us) == 2)
        #expect(NumberParsing.fractionDigits(in: "12.345", locale: us) == 3)
        // Comma locales: "," is the decimal, "." only groups.
        #expect(NumberParsing.fractionDigits(in: "1.234,5", locale: de) == 1)
        #expect(NumberParsing.fractionDigits(in: "12,345", locale: de) == 3)
        #expect(NumberParsing.fractionDigits(in: "1.234", locale: de) == 0)
    }

    @Test func aThirdDecimalCanNeitherBeTypedNorPasted() {
        #expect(!NumberParsing.allowsWholeCents("12.345", replacing: "12.34", locale: us))
        #expect(!NumberParsing.allowsWholeCents("12.340", replacing: "12.34", locale: us), "not even a zero")
        #expect(!NumberParsing.allowsWholeCents("0.125", replacing: "", locale: us), "a paste is one edit")
        #expect(!NumberParsing.allowsWholeCents("12,345", replacing: "12,34", locale: de))
        #expect(NumberParsing.allowsWholeCents("12.34", replacing: "12.3", locale: us))
        #expect(NumberParsing.allowsWholeCents("1234", replacing: "123", locale: us))
        #expect(NumberParsing.allowsWholeCents("", replacing: "12.34", locale: us))
        #expect(NumberParsing.allowsWholeCents("12,34", replacing: "12,3", locale: de))
    }

    /// No legitimate amount is interrupted on the way in: every prefix of a whole-cent amount is
    /// itself allowed, typed one keystroke at a time.
    @Test func everyKeystrokeOfAWholeCentAmountStands() {
        for (text, locale) in [("1250.75", us), ("0.05", us), ("100", us), ("99.9", us), ("1234,56", de)] {
            var previous = ""
            for character in text {
                let next = previous + String(character)
                #expect(NumberParsing.allowsWholeCents(next, replacing: previous, locale: locale),
                        "typing \"\(text)\" was stopped at \"\(next)\"")
                previous = next
            }
        }
    }

    /// What the field keeps: a keystroke that would add a third decimal is refused and nothing
    /// else is; several keystrokes delivered as ONE change (fast typing — found 2026-09-27, when
    /// the field went back to "1" after "12.345" was typed at machine speed) keep every one that
    /// follows the rule, as at a person's pace; a digit put in among the decimals is refused whole.
    @Test func theFieldKeepsEveryKeystrokeButAThirdDecimal() {
        #expect(NumberParsing.wholeCentsText("12.345", replacing: "12.34", locale: us) == "12.34")
        #expect(NumberParsing.wholeCentsText("12.34", replacing: "12.3", locale: us) == "12.34")
        #expect(NumberParsing.wholeCentsText("12.345", replacing: "1", locale: us) == "12.34")
        #expect(NumberParsing.wholeCentsText("12.3456", replacing: "12.3", locale: us) == "12.34")
        #expect(NumberParsing.wholeCentsText("0.125", replacing: "", locale: us) == "0.12")
        #expect(NumberParsing.wholeCentsText("1250", replacing: "", locale: us) == "1250")
        #expect(NumberParsing.wholeCentsText("12.934", replacing: "12.34", locale: us) == "12.34",
                "a digit put in among the decimals is refused, not the one after it")
        #expect(NumberParsing.wholeCentsText("12,345", replacing: "12,3", locale: de) == "12,34")
        #expect(NumberParsing.wholeCentsText("12.3456", replacing: "12.345", locale: us) == "12.345")
        #expect(NumberParsing.wholeCentsText("12.34", replacing: "12.345", locale: us) == "12.34")
    }

    /// An older record that already holds a fraction of a cent is shown as it is stored; its text
    /// can lose digits (toward whole cents), never gain one.
    @Test func anOlderSubCentAmountCanLoseDigitsButNeverGainOne() {
        #expect(NumberParsing.allowsWholeCents("12.34", replacing: "12.345", locale: us))
        #expect(NumberParsing.allowsWholeCents("12.345", replacing: "12.3456", locale: us))
        #expect(!NumberParsing.allowsWholeCents("12.3456", replacing: "12.345", locale: us))
        #expect(!NumberParsing.allowsWholeCents("112.345", replacing: "12.345", locale: us))
    }

    // MARK: - The forms

    /// One `AutoClearNumberField(…)` call in the app: where, what it binds, and the whole call.
    private struct FieldCall {
        let path: String
        let binding: String
        let call: String
    }

    /// Every `AutoClearNumberField(…)` call in the app's sources (comments skipped), read to its
    /// matching parenthesis.
    private func fieldCalls() throws -> [FieldCall] {
        let valuePattern = try NSRegularExpression(pattern: #"value:\s*([^,\n)]+)"#)
        var calls: [FieldCall] = []
        for file in GLSource.files(excluding: ["UIComponents/AutoClearNumberField.swift"]) {
            let text = file.text
            var search = text.startIndex
            while let found = text.range(of: "AutoClearNumberField(", range: search..<text.endIndex) {
                search = found.upperBound
                let lineStart = text[..<found.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                if text[lineStart..<found.lowerBound].contains("//") { continue }
                var depth = 0
                var index = text.index(before: found.upperBound)
                while index < text.endIndex {
                    if text[index] == "(" { depth += 1 }
                    if text[index] == ")" { depth -= 1; if depth == 0 { break } }
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { continue }
                let call = String(text[found.lowerBound...index])
                let range = NSRange(call.startIndex..., in: call)
                guard let match = valuePattern.firstMatch(in: call, range: range),
                      let bindingRange = Range(match.range(at: 1), in: call) else { continue }
                calls.append(FieldCall(path: file.path, binding: call[bindingRange].trimmingCharacters(in: .whitespaces),
                                       call: call))
            }
        }
        return calls
    }

    /// Every AMOUNT field refuses a third decimal; every price, rate, percentage, hour and quantity
    /// field keeps what is typed. A number field this test doesn't know fails it until someone
    /// decides which it is — so a new money field can't quietly miss the rule.
    @Test func everyAmountFieldTakesWholeCentsAndEveryPriceOrRateKeepsItsPrecision() throws {
        let amounts: Set<String> = ["$total", "$amount", "$amountDueNow", "$bonusAmount", "$agreedPrice"]
        let keptAsTyped: Set<String> = ["$hourlyRate", "$annualSalary", "$rate", "$unitPrice", "line.unitPrice",
                                        "item.unitPrice", "$hours", "line.quantity", "item.quantity",
                                        "$defaultQuantity", "$taxRatePercent", "line.discountValue", "$discountValue"]
        let calls = try fieldCalls()
        #expect(calls.count >= 30, "the scan found the app's number fields (\(calls.count))")

        var amountFields = 0
        for field in calls {
            let wholeCents = field.call.contains("wholeCents: true")
            if amounts.contains(field.binding) {
                amountFields += 1
                #expect(wholeCents, "\(field.path): the \(field.binding) amount field must take whole cents")
            } else if keptAsTyped.contains(field.binding) {
                #expect(!field.call.contains("wholeCents"), "\(field.path): \(field.binding) keeps what is typed")
            } else if field.binding == "value" {
                // The document adjustment sections: Discount keeps what is typed; the estimate's
                // Deposit takes whole cents when it is in dollars.
                if field.path == "Screens/EstimateFormScreen.swift" {
                    #expect(field.call.contains("wholeCents: fixedIsAmount && type.wrappedValue == .fixed"),
                            "\(field.path): a deposit in dollars must take whole cents")
                } else {
                    #expect(!field.call.contains("wholeCents"), "\(field.path): a discount keeps what is typed")
                }
            } else {
                Issue.record("\(field.path): AutoClearNumberField bound to \(field.binding) is neither an amount nor a price, rate, percentage or quantity — sort it into one of the two lists")
            }
        }
        // Receipts 1, invoice payment + amount due 2, invoice form 1, employee 5, subcontractor 2, job 1, contract 1.
        #expect(amountFields == 13, "amount fields found: \(amountFields)")

        let estimate = try #require(GLSource.file("Screens/EstimateFormScreen.swift"))
        #expect(estimate.contains(#"adjustmentSection(title: mbLoc("Deposit"), type: $depositType, value: $depositValue, fixedIsAmount: true)"#))
        #expect(estimate.contains(#"adjustmentSection(title: mbLoc("Discount"), type: $discountType, value: $discountValue)"#))
    }

    /// A number field outside `AutoClearNumberField` can't refuse a keystroke: a `TextField` bound
    /// to a number (`value:` through a format) only reads the text when editing ends (the job's
    /// agreed price was one until 2026-09-27). So no screen binds a TextField to a number at all.
    @Test func noNumberFieldBypassesTheOneThatRefusesKeystrokes() throws {
        let valueBound = try NSRegularExpression(pattern: #"\bTextField\([^\n]*\bvalue:"#)
        var scanned = 0
        for file in GLSource.files() {
            scanned += 1
            let hits = valueBound.numberOfMatches(in: file.text, range: NSRange(file.text.startIndex..., in: file.text))
            #expect(hits == 0, "\(file.path): a TextField bound to a number outside AutoClearNumberField")
        }
        #expect(scanned > 50)
        let replaced = #"TextField("0", value: $agreedPrice, format: .money(code: currencyCode))"#
        #expect(valueBound.numberOfMatches(in: replaced, range: NSRange(replaced.startIndex..., in: replaced)) == 1,
                "the pattern catches the field it replaced")
    }

    // MARK: - The assistant

    private func rowCounts(_ context: ModelContext) -> [String: Int] {
        [
            "estimates": (try? context.fetchCount(FetchDescriptor<Estimate>())) ?? -1,
            "invoices": (try? context.fetchCount(FetchDescriptor<Invoice>())) ?? -1,
            "payments": (try? context.fetchCount(FetchDescriptor<InvoicePayment>())) ?? -1,
            "jobs": (try? context.fetchCount(FetchDescriptor<ScheduledJob>())) ?? -1,
            "receipts": (try? context.fetchCount(FetchDescriptor<Receipt>())) ?? -1,
            "timeEntries": (try? context.fetchCount(FetchDescriptor<TimeEntry>())) ?? -1,
            "paychecks": (try? context.fetchCount(FetchDescriptor<Paycheck>())) ?? -1,
            "subPayments": (try? context.fetchCount(FetchDescriptor<SubPayment>())) ?? -1,
        ]
    }

    /// One amount argument on one tool: the call's other arguments, built in a fresh world.
    private struct AmountCase {
        let tool: String
        let key: String
        let arguments: (MBWriteWorld) -> GLAIJSON
    }

    private func amountCases(_ world: MBWriteWorld) -> [AmountCase] {
        let context = world.context
        let invoice = TS.invoice(status: .sent, in: context)
        invoice.customer = world.customer
        let employee = TS.employee(first: "Luis", hourlyRate: 30, in: context)
        TS.logHours(employee, 10, date: MBToolHarness.now, in: context)
        let check = TS.paycheck(employee, gross: 500, periodStart: MBToolHarness.now, periodEnd: MBToolHarness.now,
                                payDate: MBToolHarness.now, in: context)
        let sub = TS.subcontractor(first: "Marco", in: context)
        TS.oweSub(sub, 500, date: TS.day(2026, 9, 10), in: context)
        context.saveChanges()
        let invoiceID = GLAIJSON.string(world.id(invoice))
        let employeeID = GLAIJSON.string(world.id(employee))
        let subID = GLAIJSON.string(world.id(sub))
        let line: GLAIJSON = ["groups": [["name": "Work", "lines": [["name": "Tile", "quantity": .number(1),
                                                                     "unit_price": .number(1000)]]]]]
        func merged(_ base: GLAIJSON, _ extra: [String: GLAIJSON]) -> GLAIJSON {
            .object((base.objectValue ?? [:]).merging(extra) { $1 })
        }
        return [
            AmountCase(tool: "record_payment", key: "amount") { _ in
                ["invoice_id": invoiceID, "method": "cash"] },
            AmountCase(tool: "create_invoice", key: "amount_due_now") { world in
                merged(line, ["customer_id": .string(world.customerID), "job_title": "Floor"]) },
            AmountCase(tool: "edit_invoice", key: "amount_due_now") { _ in ["id": invoiceID] },
            AmountCase(tool: "save_job", key: "agreed_price") { world in
                ["customer_id": .string(world.customerID), "title": "Backsplash", "start_date": "2026-09-21",
                 "duration_days": 1] },
            AmountCase(tool: "save_receipt", key: "total") { _ in ["vendor": "Floor & Decor", "date": "2026-09-20"] },
            AmountCase(tool: "log_time", key: "amount") { _ in
                ["employee_id": employeeID, "mode": "bonus", "date": "2026-09-20"] },
            AmountCase(tool: "pay_employee", key: "amount") { _ in ["employee_id": employeeID] },
            AmountCase(tool: "pay_employee", key: "bonus") { _ in ["employee_id": employeeID] },
            AmountCase(tool: "edit_paycheck", key: "gross_amount") { _ in
                ["id": .string(world.id(check)), "method": "zelle"] },
            AmountCase(tool: "log_sub_work", key: "amount") { _ in
                ["subcontractor_id": subID, "mode": "dollars", "date": "2026-09-21", "detail": "Grout"] },
            AmountCase(tool: "pay_subcontractor", key: "amount") { _ in ["subcontractor_id": subID, "method": "check"] },
        ]
    }

    /// Every amount the assistant can send, sent with a fraction of a cent, is refused as the
    /// model's own slip — `invalid_arguments`, a sentence naming the argument and the fix, never a
    /// row on the person's card — before anything is written or anyone is asked to confirm. The
    /// same call in whole cents is not refused for it.
    @Test func everyAmountArgumentWithAFractionOfACentIsRefused() async throws {
        let count = amountCases(try MBWriteWorld()).count
        #expect(count == 11)
        for index in 0..<count {
            let world = try MBWriteWorld()
            let amountCase = amountCases(world)[index]
            let before = rowCounts(world.context)
            var arguments = amountCase.arguments(world).objectValue ?? [:]
            arguments[amountCase.key] = .number(12.345)
            let outcome = await MBWriteHarness.run(world.box, amountCase.tool, .object(arguments))
            let label = "\(amountCase.tool).\(amountCase.key)"
            #expect(MBWriteHarness.failureReason(outcome) == "invalid_arguments", "\(label) was not refused")
            #expect(MBWriteHarness.failureMessage(outcome) == MBArguments.wholeCentsMessage(amountCase.key), "\(label)")
            if case .failure(let failure) = outcome { #expect(!failure.showsToPerson, "\(label)") }
            #expect(rowCounts(world.context) == before, "\(label) wrote something")

            arguments[amountCase.key] = .number(12.35)
            let whole = await MBWriteHarness.run(world.box, amountCase.tool, .object(arguments), callID: "whole")
            #expect(!MBWriteHarness.failureMessage(whole).contains("whole cents"), "\(label) refused whole cents")
        }
    }

    /// The edit paths change nothing when refused: the invoice keeps its amount due.
    @Test func aRefusedAmountDueLeavesTheInvoiceAsItWas() async throws {
        let world = try MBWriteWorld()
        let invoice = TS.invoice(status: .sent, in: world.context)
        invoice.customer = world.customer
        invoice.amountDueNow = 250
        world.context.saveChanges()
        let refused = await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(world.id(invoice)), "amount_due_now": .number(333.333),
        ])
        #expect(MBWriteHarness.failureReason(refused) == "invalid_arguments")
        #expect(invoice.amountDueNow == 250)

        _ = MBWriteHarness.output(await MBWriteHarness.run(world.box, "edit_invoice", [
            "id": .string(world.id(invoice)), "amount_due_now": .number(333.33),
        ]))
        #expect(invoice.amountDueNow == 333.33)
    }

    /// A deposit is an amount only in dollars: a fixed deposit_value with a fraction of a cent is
    /// refused (sent as the value, or by switching a stored percentage to fixed), a percentage
    /// keeps what was sent, and a fixed deposit in whole cents is taken as sent.
    @Test func aDepositInDollarsTakesWholeCentsAndAPercentageKeepsItsPrecision() async throws {
        let world = try MBWriteWorld()
        let lines: GLAIJSON = [["lines": [["name": "Tile install", "quantity": .number(1000), "unit_price": .number(0.125)]]]]
        let fixed = await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Floor",
            "deposit_type": "fixed", "deposit_value": .number(62.505), "groups": lines,
        ])
        #expect(MBWriteHarness.failureReason(fixed) == "invalid_arguments")
        #expect(MBWriteHarness.failureMessage(fixed).contains("deposit_value"))
        #expect(world.estimates().isEmpty, "nothing was saved")

        _ = MBWriteHarness.output(await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Floor",
            "deposit_type": "percentage", "deposit_value": .number(12.345), "groups": lines,
        ]))
        let estimate = try #require(world.estimates().first)
        #expect(estimate.depositType == .percentage && estimate.depositValue == 12.345)

        // Switching the stored 12.345% to dollars would make it $12.345: refused, nothing changes.
        let switched = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(world.id(estimate)), "deposit_type": "fixed",
        ])
        #expect(MBWriteHarness.failureReason(switched) == "invalid_arguments")
        #expect(estimate.depositType == .percentage && estimate.depositValue == 12.345)

        let edited = await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(world.id(estimate)), "deposit_type": "fixed", "deposit_value": .number(62.5),
        ])
        _ = MBWriteHarness.output(edited)
        #expect(estimate.depositType == .fixed && estimate.depositValue == 62.5)
        #expect(estimate.depositAmount == 62.5)

        // An edit that doesn't touch the deposit is never refused for it.
        _ = MBWriteHarness.output(await MBWriteHarness.run(world.box, "edit_estimate", [
            "id": .string(world.id(estimate)), "job_title": "Floor and shower",
        ]))
    }

    // MARK: - The manifest

    /// The number arguments that are not amounts, kept as the model sends them (a price, a rate,
    /// a percentage, a quantity, hours, a count, a year). `deposit_value` is here because it is a
    /// percentage OR dollars; the estimate tools hold it to whole cents when it is dollars.
    private static let keptAsSent: Set<String> = [
        "quantity", "unit_price", "discount_value", "tax_rate_percent", "deposit_value", "default_quantity",
        "hourly_rate", "annual_salary", "hours", "rate", "limit", "page", "duration_days", "duration_minutes",
        "repeat_count", "year", "percentage",
    ]

    /// Every number argument in the manifest, as (tool, argument name).
    private func numberArguments() throws -> [(tool: String, key: String)] {
        let text = try #require(GLSource.file("Resources/AI/tools.mb-1.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tools = try #require(root["tools"] as? [[String: Any]])
        var found: [(tool: String, key: String)] = []
        func walk(_ tool: String, _ schema: Any?) {
            guard let schema = schema as? [String: Any] else { return }
            for (key, property) in (schema["properties"] as? [String: Any]) ?? [:] {
                let type = (property as? [String: Any])?["type"]
                let types = (type as? [String]) ?? [(type as? String) ?? ""]
                if types.contains("number") || types.contains("integer") { found.append((tool, key)) }
                walk(tool, property)
            }
            walk(tool, schema["items"])
        }
        for tool in tools { walk(tool["name"] as? String ?? "", tool["parameters"]) }
        return found
    }

    /// Every number the model can send is either an amount (whole cents, refused otherwise) or a
    /// value kept as sent — never neither, so a new money argument can't slip past the rule.
    @Test func everyNumberArgumentIsAnAmountOrKeptAsSent() throws {
        let arguments = try numberArguments()
        #expect(arguments.count >= 40, "the manifest was read (\(arguments.count) number arguments)")
        for (tool, key) in arguments {
            #expect(MBArguments.amountKeys.contains(key) || Self.keptAsSent.contains(key),
                    "\(tool).\(key) is a number nobody has sorted into amounts or kept-as-sent values")
            #expect(!(MBArguments.amountKeys.contains(key) && Self.keptAsSent.contains(key)), "\(key) is in both")
        }
        let used = Set(arguments.map(\.key))
        #expect(MBArguments.amountKeys.isSubset(of: used), "an amount key the manifest no longer has")
    }

    /// Every tool that takes an amount is bound behind the gate, so no path reaches its service
    /// without the whole-cents check.
    @Test func everyToolThatTakesAnAmountIsBoundBehindTheGate() throws {
        let box = try MBToolHarness.toolbox(DomainFixtures.context())
        let tools = Set(try numberArguments().filter { MBArguments.amountKeys.contains($0.key) }.map(\.tool))
        #expect(tools.count >= 10, "\(tools.sorted())")
        for name in tools.sorted() {
            let executor = try #require(box.online.executor(named: name), "\(name) is not bound")
            #expect(executor is MBWholeCentsGate, "\(name) is bound without the whole-cents gate")
        }
        for name in ["create_estimate", "edit_estimate"] {
            #expect(box.online.executor(named: name) is MBWholeCentsGate)
        }
    }
}
