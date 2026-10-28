//
//  MBReportHelpTests.swift
//  GLSmallBusinessTests — AI
//
//  `report` answers from the screens' own math (StatsEngine, the Invoices screen's "Owed to
//  you", payroll accruals, the calendar's queries, certificate status), and `help` answers from
//  the screens' own words (every InfoLabel / InfoButton text, What's New).
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBReportHelpTests {

    // MARK: - Money

    @Test func moneySummaryUsesTheStatisticsMathOverAnySpanOfDays() async throws {
        let context = try DomainFixtures.context()
        let cal = TS.calendar
        let invoice = TS.invoice(createdAt: TS.day(2026, 3, 1), status: .sent, lines: [(1000, false)], in: context)
        TS.pay(invoice, 400, date: TS.day(2026, 3, 10), in: context)
        // The last minute of the last day still counts (the range is inclusive of whole days).
        TS.pay(invoice, 25, date: cal.date(bySettingHour: 23, minute: 30, second: 0, of: TS.day(2026, 3, 31)) ?? .now, in: context)
        TS.pay(invoice, 100, date: TS.day(2026, 4, 2), in: context)
        context.insert(Receipt(vendor: "Tile Depot", date: TS.day(2026, 3, 15), total: 50, category: "Tile"))
        context.insert(Receipt(vendor: "Gas", date: TS.day(2026, 4, 10), total: 30, category: "Fuel"))
        let employee = TS.employee(in: context)
        TS.paycheck(employee, gross: 240, periodStart: TS.day(2026, 3, 9), periodEnd: TS.day(2026, 3, 15),
                    payDate: TS.day(2026, 3, 20), in: context)
        TS.paySub(TS.subcontractor(in: context), 200, date: TS.day(2026, 3, 25), in: context)
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        let march = MBToolHarness.output(await MBToolHarness.run(
            box, "report", ["kind": "money_summary", "date_from": "2026-03-01", "date_to": "2026-03-31", "query": "tile"]))
        #expect(march["collected"]?.doubleValue == 425)
        #expect(march["expenses"]?.doubleValue == 50)
        #expect(march["net"]?.doubleValue == 375)
        #expect(march["payroll_paid"]?.doubleValue == 240)
        #expect(march["subcontractors_paid"]?.doubleValue == 200)
        #expect(march["invoiced"]?.doubleValue == 1000)
        #expect(march["expenses_matching"]?["amount"]?.doubleValue == 50)
        #expect(march["from"]?.stringValue == "2026-03-01")

        // The same month through StatsPeriod.month gives the same figures (one engine).
        let month = StatsEngine.summary(period: .month(year: 2026, month: 3), invoices: [invoice], estimates: [],
                                        receipts: MBRecordLookup.all(Receipt.self, in: context), calendar: cal)
        #expect(month.collected == 425 && month.expenses == 50)
    }

    @Test func statsPeriodDaysIsInclusiveAndOrderFree() {
        let cal = TS.calendar
        let period = StatsPeriod.days(from: TS.day(2026, 3, 31), to: TS.day(2026, 3, 1))
        #expect(period.contains(TS.day(2026, 3, 1), calendar: cal))
        #expect(period.contains(cal.date(bySettingHour: 23, minute: 59, second: 0, of: TS.day(2026, 3, 31)) ?? .now, calendar: cal))
        #expect(!period.contains(TS.day(2026, 4, 1), calendar: cal))
        #expect(!period.contains(cal.date(byAdding: .second, value: -1, to: TS.day(2026, 3, 1)) ?? .now, calendar: cal))
        #expect(!period.label.isEmpty)
        let summary = StatsEngine.summary(period: period, invoices: [], estimates: [], receipts: [], calendar: cal)
        #expect(summary.inOut.count == 1, "a span of days is one bucket")
    }

    @Test func owedToMeMatchesTheInvoicesScreen() async throws {
        let context = try DomainFixtures.context()
        let maria = TS.customer(first: "Maria", last: "Lopez", in: context)
        let reed = TS.customer(in: context)
        let a = TS.invoice(number: "INV-0001", status: .sent, lines: [(1000, false)], in: context)
        a.customer = maria
        TS.pay(a, 250, in: context)
        let b = TS.invoice(number: "INV-0002", status: .sent, lines: [(300, false)], in: context)
        b.customer = reed
        let paid = TS.invoice(number: "INV-0003", status: .sent, lines: [(90, false)], in: context)
        paid.customer = reed
        TS.pay(paid, 90, in: context)
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        let output = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "owed_to_me"]))
        let screenRule = MBRecordLookup.all(Invoice.self, in: context).filter { !$0.isPaid }.reduce(0) { $0 + max(0, $1.balanceDue) }
        #expect(output["total_owed"]?.doubleValue == screenRule)
        #expect(output["total_owed"]?.doubleValue == 1050)
        #expect(output["customers"]?[0]?["customer"]?["id"]?.stringValue == maria.syncID?.uuidString, "biggest first")
        #expect(output["customers"]?[0]?["owes"]?.doubleValue == 750)
        #expect(output["invoice_count"]?.intValue == 2)
    }

    @Test func iOweAddsPayrollAndSubcontractors() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let output = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "i_owe"]))
        #expect(output["payroll_total"]?.doubleValue == 360)          // 12 h × $30, none paid
        #expect(output["subcontractors_total"]?.doubleValue == 450)
        #expect(output["total"]?.doubleValue == 810)
        #expect(output["employees"]?[0]?["employee"]?["id"]?.stringValue == world.employee.syncID?.uuidString)
    }

    // MARK: - Schedule

    @Test func scheduleExpandsRepeatsAndNamesTheSeries() async throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let weekly = TS.job("Lawn care", start: TS.day(2026, 8, 3), customer: customer, recurrence: .weekly, in: context)
        let timed = TS.job("Estimate visit", start: TS.day(2026, 9, 22), hour: 13, minutes: 90, customer: customer, in: context)
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)

        let output = MBToolHarness.output(await MBToolHarness.run(
            box, "report", ["kind": "schedule", "date_from": "2026-09-21", "date_to": "2026-09-27"]))
        let days = output["days"]?.arrayValue ?? []
        #expect(days.count == 7)
        #expect(days[0]["date"]?.stringValue == "2026-09-21")
        #expect(days[0]["jobs"]?[0]?["id"]?.stringValue == weekly.syncID?.uuidString, "an occurrence names its stored series")
        #expect(days[1]["jobs"]?[0]?["id"]?.stringValue == timed.syncID?.uuidString)
        #expect(days[1]["jobs"]?[0]?["start_time"]?.stringValue == "13:00")
        #expect(days[1]["jobs"]?[0]?["end_time"]?.stringValue == "14:30")
        #expect(days[5]["workday"]?.boolValue == false, "Saturday")
        #expect(output["job_days"]?.intValue == 2)

        let long = MBToolHarness.output(await MBToolHarness.run(
            box, "report", ["kind": "schedule", "date_from": "2026-09-01", "date_to": "2027-09-01"]))
        #expect(long["days"]?.arrayValue.map { $0.count <= MBReportTool.maxScheduleDays } ?? false)
        #expect(long["note"] != nil)
        #expect(long.serializedByteCount <= GLAIWire.maxToolOutputBytes)

        let openings = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "openings", "date_from": "2026-09-21"]))
        #expect(openings["next_available"]?.stringValue == "2026-09-23", "Monday is booked all day, Tuesday has a visit")
        #expect(openings["open_ended_repeats"]?.boolValue == true)
    }

    // MARK: - Documents, estimates, jobs

    @Test func expiringDocumentsListsWhatRunsOutSoonOrHasRunOut() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let output = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "expiring_documents"]))
        let kinds = Set((output["documents"]?.arrayValue ?? []).compactMap { $0["document"]?.stringValue })
        #expect(kinds == ["customer_coi", "subcontractor_coi", "wc_exemption", "license"])
        let license = output["documents"]?.arrayValue?.first { $0["document"]?.stringValue == "license" }
        #expect(license?["expired"]?.boolValue == true)
        #expect(license?["owner"] == .null, "the business's own documents name no record")
    }

    @Test func estimatePipelineCountsOpenAndDecided() async throws {
        let context = try DomainFixtures.context()
        let open = TS.estimate(number: "EST-0001", createdAt: MBToolHarness.now, status: .sent, lines: [(500, false)], in: context)
        open.validUntil = TS.calendar.date(byAdding: .day, value: 400, to: .now) ?? .now
        _ = TS.estimate(number: "EST-0002", status: .accepted, lines: [(800, false)], in: context)
        _ = TS.estimate(number: "EST-0003", status: .declined, lines: [(100, false)], in: context)
        TS.optionsEstimate(number: "EST-0004", groups: [("Good", [(10, false)]), ("Best", [(99, false)])], in: context).validUntil =
            TS.calendar.date(byAdding: .day, value: 400, to: .now) ?? .now
        context.saveChanges()
        let box = try MBToolHarness.toolbox(context)
        let output = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "estimate_pipeline"]))
        #expect(output["open"]?["count"]?.intValue == 2)
        #expect(output["open"]?["total"]?.doubleValue == 500, "an options estimate has no single total")
        #expect(output["accepted"]?["total"]?.doubleValue == 800)
        #expect(output["win_rate_percent"]?.doubleValue == 50)
        #expect(output["open_estimates"]?.arrayValue?.count == 2)
    }

    @Test func jobProfitIsApproximateAndSaysWhy() async throws {
        let world = try MBToolWorld()
        let box = try MBToolHarness.toolbox(world.context)
        let id = world.job.syncID?.uuidString ?? ""
        let only = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "job_profit", "id": .string(id)]))
        #expect(only["approximate"]?.boolValue == true)
        #expect(only["costs"]?["receipts"]?.doubleValue == 123.45)
        #expect(only["costs"]?["labor"]?.doubleValue == 360)
        #expect(only["costs"]?["subcontractors"]?.doubleValue == 450)
        #expect(only["costs"]?["total"]?.doubleValue == 933.45)
        #expect(only["contracted"]?.doubleValue == 2500)
        #expect(only["profit_on_contract"]?.doubleValue == 1566.55)

        // A second job for the same customer: hours and sub work can't be split, so they're out.
        TS.job("Bathroom", start: TS.day(2026, 10, 5), customer: world.customer, in: world.context)
        world.context.saveChanges()
        let shared = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "job_profit", "id": .string(id)]))
        #expect(shared["costs"]?["labor"]?.doubleValue == 0)
        #expect(shared["reasons"]?.arrayValue?.contains { $0.stringValue?.contains("2 jobs") == true } == true)
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "report", ["kind": "job_profit"])) == "invalid_arguments")
    }

    // MARK: - Payments and backup

    @Test func paymentsSetupAndCardPaymentStatus() async throws {
        let world = try MBToolWorld()
        let cards = FakeCardPayments()
        cards.answer = .success(StripePayLinkStatusResponse(status: "paid", amountPaidCents: 20_000, paidAt: nil))
        let box = try MBToolHarness.toolbox(world.context, cards: cards)

        let setup = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "payments_setup"]))
        #expect(setup["card_payments_connected"]?.boolValue == true)
        #expect(setup["card_charges_enabled"]?.boolValue == true)

        let id = world.invoice.syncID?.uuidString ?? ""
        let paid = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "card_payment_status", "id": .string(id)]))
        #expect(paid["status"]?.stringValue == "paid")
        #expect(paid["amount_paid"]?.doubleValue == 200)
        #expect(paid["recorded_in_app"]?.boolValue == true)
        #expect(cards.calls.count == 1)

        cards.answer = .failure(StripeBackendError.offline)
        let unknown = MBToolHarness.output(await MBToolHarness.run(box, "report", ["kind": "card_payment_status", "id": .string(id)]))
        #expect(unknown["status"]?.stringValue == "unknown")
        #expect(unknown["last_known"]?.stringValue == "open")

        // No link was ever made: answered locally, the Worker is never asked.
        let plain = TS.invoice(number: "INV-0100", status: .sent, in: world.context)
        world.context.saveChanges()
        let none = MBToolHarness.output(await MBToolHarness.run(
            box, "report", ["kind": "card_payment_status", "id": .string(plain.syncID?.uuidString ?? "")]))
        #expect(none["status"]?.stringValue == "none")
        #expect(cards.calls.count == 2)
    }

    @Test func backupStatusReadsTheSyncStateAndThePause() async throws {
        let world = try MBToolWorld()
        let plainBox = try MBToolHarness.toolbox(world.context)
        let fine = MBToolHarness.output(await MBToolHarness.run(plainBox, "report", ["kind": "backup_status"]))
        #expect(fine["backed_up"]?.boolValue == true)
        #expect(fine["paused"]?.boolValue == false)
        let trip = GLSyncBreakerTrip(deletions: 40, threshold: 25, at: MBToolHarness.now)
        let pausedBox = try MBToolHarness.toolbox(world.context, pause: trip)
        let paused = MBToolHarness.output(await MBToolHarness.run(pausedBox, "report", ["kind": "backup_status"]))
        #expect(paused["paused"]?.boolValue == true)
        #expect(paused["paused_deletions"]?.intValue == 40)
    }

    @Test func anUnknownReportIsTheModelsSlip() async throws {
        let box = try MBToolHarness.toolbox(DomainFixtures.context())
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "report", ["kind": "weather"])) == "invalid_arguments")
        #expect(MBToolHarness.failureReason(await MBToolHarness.run(
            box, "report", ["kind": "money_summary", "date_from": "03/01/2026"])) == "invalid_arguments")
    }

    // MARK: - Help

    @Test func helpAnswersFromTheAppsOwnWords() async throws {
        let box = try MBToolHarness.toolbox(DomainFixtures.context())
        let whatsNew = MBToolHarness.output(await MBToolHarness.run(box, "help", ["question": "what's new", "section": "whats_new"]))
        #expect(whatsNew["items"]?.arrayValue?.count == MBWhatsNew.items.count)
        #expect(whatsNew["version"]?.stringValue?.isEmpty == false)
        // The installed app's own version, never a typed one (found 2026-09-29: "Version 3.0" on 3.1).
        let short = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(whatsNew["version"]?.stringValue == "Version \(short)")
        #expect(MBWhatsNew.versionLabel(short: "9.8.7") == "Version 9.8.7")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GLSmallBusiness/Screens/WhatsNewScreen.swift"), encoding: .utf8)
        #expect(source.range(of: #""Version [0-9]"#, options: .regularExpression) == nil, "no typed version")

        let howTo = MBToolHarness.output(await MBToolHarness.run(
            box, "help", ["question": "How do I bill a deposit on an invoice?", "section": "how_to"]))
        let topics = (howTo["topics"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        #expect(topics.first?.localizedCaseInsensitiveContains("deposit") == true, "\(topics)")
        #expect(howTo["guides"]?.stringValue?.contains("how_to") == true)

        let about = MBToolHarness.output(await MBToolHarness.run(box, "help", ["question": "which version", "section": "about"]))
        #expect(about["app"]?.stringValue == "My Business")
        #expect(about["version"]?.stringValue?.isEmpty == false)

        #expect(MBToolHarness.failureReason(await MBToolHarness.run(box, "help", ["question": "x", "section": "faq"])) == "invalid_arguments")
    }

    /// Every InfoLabel / InfoButton explanation a screen shows is in the help catalog, word for
    /// word (the same catalog key) — so the assistant can never be missing one or say it
    /// differently. Texts built at runtime (interpolated) are the only exception.
    @Test func everyInAppExplanationIsInTheHelpCatalog() throws {
        let helpSource = try #require(GLSource.file("AI/MBHelpTool.swift"))
        let pattern = #"Info(?:Label|Button)\([^\n]*?(?:info|text): "((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var checked = 0
        for file in GLSource.files(excluding: ["AI/", "UIComponents/InfoButton.swift"]) {
            let range = NSRange(file.text.startIndex..., in: file.text)
            for match in regex.matches(in: file.text, range: range) {
                guard let textRange = Range(match.range(at: 1), in: file.text) else { continue }
                let literal = String(file.text[textRange])
                if literal.contains("\\(") { continue }
                checked += 1
                #expect(helpSource.contains("text: \"\(literal)\""), "\(file.path): \(literal.prefix(60))… is not in MBHelpCatalog")
            }
        }
        #expect(checked >= 25, "the scan found the screens' explanations (\(checked))")
    }
}
