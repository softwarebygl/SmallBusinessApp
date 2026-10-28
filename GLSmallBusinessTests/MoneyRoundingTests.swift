//
//  MoneyRoundingTests.swift
//  GLSmallBusinessTests
//
//  THE ONE MONEY RULE (REQUIREMENTS law 60, owner ruling 2026-09-27): every amount — line totals,
//  discounts, tax, totals, deposits, balances, amounts due — is rounded to the cent ONCE, half-up,
//  on the amount as written, so the screen, the PDF, the email, the assistant and the Stripe charge
//  always agree. Found 2026-09-27: screens and PDFs formatted exact half cents to even ($1,000.025 →
//  $1,000.02) while the assistant's row rounded half-up (1000.03), and the pay link charged
//  `Int((amount × 100).rounded())` of the binary Double — 7.5 h × $43.73 is 327.975 as written but
//  327.97499999999997 as a Double, shown as $327.97 and charged $327.98.
//
//  What is pinned here, each with its own instrument:
//    • the rule itself (DomainMoney): half-up on the written amount, the nearest Double back out
//      (the old NSDecimalNumber.doubleValue path landed 327.97 on 327.96999999999997), whole cents;
//    • the three tie cases on EVERY surface: the row the assistant reads, the money the screen draws
//      and the PDF the customer receives (both read back off the rendered pixels), the email/SMS
//      body, and the cents the pay link is minted for;
//    • Deposit + Balance == Total to the cent, swept;
//    • stored amounts: what a person types is stored in whole cents by every service; wherever
//      amounts are added they are added as written and rounded once — the sync Worker's rule — so
//      every total (ledger, receipts, Statistics, CSV, the assistant's report) agrees with every other;
//    • prices, rates and percentages kept as typed on both doors — the form and the assistant make
//      the same amount from them;
//    • paying the owed total shown settles every entry, for an employee and a subcontractor alike;
//    • a million amounts whose value, text and cents never disagree;
//    • the call sites (a source scan): no money text outside `.money`, no cents taken off a binary value;
//    • the sync Worker's copy of the formula: gl-business-api's shared money vectors replayed here, so
//      the Worker's paid lock and the app's Paid badge can never disagree about a cent.
//
//  Serialized: two tests host screens (GLTestHost — see its header).
//

import Testing
import Foundation
import SwiftData
import SwiftUI
import UIKit
import PDFKit
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MoneyRoundingTests {

    // MARK: - Helpers

    /// Money text as an American reads it (the literals below are en_US).
    private func text(_ amount: Double) -> String { amount.formatted(.money.locale(Locale(identifier: "en_US"))) }

    /// OCR text with the spaces taken out, so "$ 1,000.03" and "$1,000.03" read the same.
    private func squeezed(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "") }

    /// The PDF the customer receives, read back off its rendered pages via the shared DrawnText harness.
    private func pdfText(_ url: URL?) throws -> String {
        let document = try #require(url.flatMap { PDFDocument(url: $0) })
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: box.width * 2, height: box.height * 2), for: .mediaBox)
            if let cg = image.cgImage { pages.append(try DrawnText.read(cg)) }
        }
        return pages.joined(separator: "\n")
    }

    /// The screen as it is drawn: hosted via the shared DrawnText harness.
    private func screenText<V: View>(_ view: V, container: ModelContainer) throws -> String {
        try DrawnText.screen(view, container: container, size: CGSize(width: 430, height: 1800))
    }

    /// The row the assistant is handed for a record.
    private func dto(_ context: ModelContext) -> MBRecordDTO {
        MBRecordDTO(env: MBToolHarness.environment(context), context: context)
    }

    /// A business that takes cards, so an invoice can carry a pay link.
    private func business(in context: ModelContext) -> BusinessProfile {
        let profile = BusinessProfile()
        profile.businessName = "Gold Standard Tile"
        profile.stripeConnectedAccountId = "acct_1"
        profile.stripeChargesEnabled = true
        context.insert(profile)
        return profile
    }

    /// A sent invoice with ONE line of `quantity` × `unitPrice` — how a half cent arrives from typing.
    private func invoice(_ quantity: Double, _ unitPrice: Double, in context: ModelContext) throws -> Invoice {
        let invoice = TS.invoice(number: "INV-0060", status: .sent, lines: [(unitPrice, false)], in: context)
        try #require(invoice.allLineItems.first).quantity = quantity
        invoice.includePayLink = true
        context.saveChanges()
        return invoice
    }

    /// The cents a pay link is minted for — against a stand-in Stripe, never the network.
    private func mintedCents(_ invoice: Invoice, in context: ModelContext) async throws -> Int? {
        let stripe = FakeStripe()
        let environment = PayLinkEnvironment(isConfigured: true, deviceLinked: true, backend: stripe)
        _ = try await DomainState.subscribed.runAsync {
            try await SendPreparer.mintPayLink(for: invoice, accountId: "acct_1", in: context, environment: environment)
        }
        return stripe.mints.last?.amountCents
    }

    // MARK: - App-Specific Formatter Wiring (Core GLMoney math lives in GoldLifeDocumentsTests)

    @Test func form1099Box1aRoundsHalfUp() {
        #expect(Form1099NECPDF.box1aAmount(1000.025) == "1,000.03")
    }

    // MARK: - The three ties, on every surface

    /// $2,000.05 at a 50% deposit is $1,000.025 as written: $1,000.03 on the estimate row, screen and
    /// PDF, then on the invoice it becomes (row, screen, PDF, email) and in the pay link's cents —
    /// and Deposit + Balance == Total once it is paid.
    @Test func aHalfCentDepositReadsTheSameEverywhereAndChargesThatCent() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let profile = business(in: context)
        let estimate = TS.estimate(lines: [(2000.05, false)], in: context)
        estimate.customer = TS.customer(in: context)
        estimate.depositType = .percentage
        estimate.depositValue = 50
        context.saveChanges()

        #expect(estimate.total == 2000.05)
        #expect(estimate.depositAmount == 1000.03)
        #expect(dto(context).row(estimate)["deposit"]?.doubleValue == 1000.03)
        let estimatePDF = squeezed(try pdfText(EstimatePDF.render(estimate, business: profile)))
        #expect(estimatePDF.contains("$1,000.03") && !estimatePDF.contains("$1,000.02"), "\(estimatePDF)")
        let estimateScreen = squeezed(try screenText(EstimateDetailScreen(estimate: estimate), container: container))
        #expect(estimateScreen.contains("$1,000.03") && !estimateScreen.contains("$1,000.02"), "\(estimateScreen)")

        let invoice = Invoice.make(from: estimate, number: "INV-0061", in: context)
        invoice.status = .sent
        invoice.includePayLink = true
        context.saveChanges()
        #expect(invoice.amountDueNow == 1000.03)
        #expect(invoice.currentAmountDue == 1000.03)
        #expect(dto(context).row(invoice)["amount_due_now"]?.doubleValue == 1000.03)
        #expect(InvoiceMessage.plainBody(invoice: invoice, business: profile)
            .contains("Amount due now: \(1000.03.formatted(.money))"))
        #expect(InvoiceMessage.htmlBody(invoice: invoice, business: profile).contains(1000.03.formatted(.money)))
        let invoicePDF = squeezed(try pdfText(InvoicePDF.render(invoice, business: profile)))
        #expect(invoicePDF.contains("$1,000.03") && !invoicePDF.contains("$1,000.02"), "\(invoicePDF)")
        #expect(try await mintedCents(invoice, in: context) == 100_003)

        _ = try DomainState.subscribed.run {
            try InvoiceService.recordPayment(on: invoice, amount: invoice.currentAmountDue, method: .card,
                                             origin: .screen, in: context)
        }
        #expect(invoice.amountPaid == 1000.03)
        #expect(invoice.balanceDue == 1000.02)
        #expect(DomainMoney.decimal(invoice.amountPaid) + DomainMoney.decimal(invoice.balanceDue)
                == DomainMoney.decimal(invoice.total), "Deposit + Balance == Total")
        #expect(!invoice.hasAmountDueRequest, "the deposit request is drawn down to nothing")
    }

    /// 2.5 × $400.01 = $1,000.025 as written: every surface says $1,000.03 and the pay link charges
    /// 100,003 cents. Paying the old screen amount leaves the cent owed, and says so everywhere.
    @Test func aHalfCentTotalReadsTheSameEverywhere() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let profile = business(in: context)
        let invoice = try invoice(2.5, 400.01, in: context)
        invoice.customer = TS.customer(in: context)
        context.saveChanges()

        #expect(try #require(invoice.allLineItems.first).lineTotal == 1000.03)
        #expect(invoice.total == 1000.03)
        #expect(invoice.balanceDue == 1000.03)
        let row = dto(context).row(invoice)
        #expect(row["total"]?.doubleValue == 1000.03)
        #expect(row["balance_due"]?.doubleValue == 1000.03)
        #expect(InvoiceMessage.plainBody(invoice: invoice, business: profile)
            .contains("Total: \(1000.03.formatted(.money))"))
        let pdf = squeezed(try pdfText(InvoicePDF.render(invoice, business: profile)))
        #expect(pdf.contains("$1,000.03") && !pdf.contains("$1,000.02"), "\(pdf)")
        let screen = squeezed(try screenText(InvoiceDetailScreen(invoice: invoice), container: container))
        #expect(screen.contains("$1,000.03") && !screen.contains("$1,000.02"), "\(screen)")
        #expect(try await mintedCents(invoice, in: context) == 100_003)

        TS.pay(invoice, 1000.02, in: context)          // what the screen used to ask for
        #expect(invoice.balanceDue == 0.01)
        #expect(!invoice.isPaid && !invoice.isMoneyLocked, "the cent is still owed — and the Worker agrees")
        TS.pay(invoice, 0.01, in: context)
        #expect(invoice.balanceDue == 0 && invoice.isPaid)
    }

    /// 7.5 hours × $43.73 is $327.975 as written (327.97499999999997 as a Double): $327.98 on the
    /// line, the total, the PDF, the screen, the assistant's row and in the pay link — never $327.97.
    @Test func theHoursTimesRateTieChargesWhatItShows() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let profile = business(in: context)
        let invoice = try invoice(7.5, 43.73, in: context)
        invoice.customer = TS.customer(in: context)
        context.saveChanges()

        #expect(try #require(invoice.allLineItems.first).lineTotal == 327.98)
        #expect(invoice.total == 327.98)
        #expect(dto(context).row(invoice)["total"]?.doubleValue == 327.98)
        #expect(InvoiceMessage.plainBody(invoice: invoice, business: profile)
            .contains("Balance: \(327.98.formatted(.money))"))
        let pdf = squeezed(try pdfText(InvoicePDF.render(invoice, business: profile)))
        #expect(pdf.contains("$327.98") && !pdf.contains("$327.97"), "\(pdf)")
        let screen = squeezed(try screenText(InvoiceDetailScreen(invoice: invoice), container: container))
        #expect(screen.contains("$327.98") && !screen.contains("$327.97"), "\(screen)")
        #expect(try await mintedCents(invoice, in: context) == 32_798)
    }

    /// The same product on the payroll side: a sub's ledger entry, an employee's accrued pay and a
    /// salaried paycheck are each worked out exactly and rounded once — and paying the amount shown
    /// settles it to the cent.
    @Test func payrollAmountsFollowTheSameRule() throws {
        let context = try DomainFixtures.context()
        let sub = TS.subcontractor(in: context)
        let entry = try DomainState.subscribed.run {
            try SubcontractorService.recordEntry(.hours(7.5, on: .now, rate: 43.73), detail: "Tile", customer: nil,
                                                 paidOn: nil, method: .check, for: sub, in: context)
        }
        #expect(entry.amount == 327.98)
        #expect(sub.outstanding == 327.98)
        let paid = try DomainState.subscribed.run {
            try SubcontractorService.payNow(sub.outstanding, paidDate: .now, method: .check, for: sub, in: context)
        }
        #expect(paid.count == 1 && sub.outstanding == 0)

        let hourly = TS.employee(hourlyRate: 43.73, in: context)
        try DomainState.subscribed.run {
            _ = try EmployeeService.logTime(.hours(7.5, on: .now, rate: 43.73), customer: nil, note: "",
                                            for: hourly, in: context)
        }
        #expect(hourly.accruedGross == 327.98)
        let salaried = TS.employee(payType: .salary, annualSalary: 50_000, payFrequency: .biweekly, in: context)
        #expect(salaried.salaryPerPeriod == 1923.08)        // 50,000 / 26 = 1,923.0769…
        #expect(PaymentProcessor(name: "Card", feePercent: 2.9, flatFee: 0.3).fee(on: 15) == 0.74) // 0.435 + 0.30 = 0.735
    }

    // MARK: - Stored amounts: one rule

    /// Rows an older build stored exactly as typed (or that sync brings in from one): payments of
    /// $5.005 and $4.995 and three $1.005 receipts. Each row reads its own cents ($5.01, $5.00,
    /// $1.01); every total adds the amounts as written and is rounded once — the sync Worker's
    /// paid-lock rule — so every total agrees with every other: the invoice's amount paid ($10.00,
    /// Paid — as build 83 and the Worker say), the customer's paid total, each payment receipt, the
    /// Receipts header ($3.02), Statistics, the accountant's CSV and the assistant's report. And the
    /// Worker's own vector: 333.333 + 333.333 + 333.334 on $1,000 is $1,000.00 paid, Paid.
    /// (Whether a total should instead add its rows as they show is an open owner question.)
    @Test func olderSubCentAmountsAddExactlyAndRoundOnceOnEveryTotal() async throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let profile = business(in: context)
        let customer = TS.customer(in: context)
        let invoice = TS.invoice(number: "INV-0061", createdAt: TS.day(2026, 3, 1), status: .sent,
                                 lines: [(10, false)], in: context)
        invoice.customer = customer
        let first = TS.pay(invoice, 5.005, date: TS.day(2026, 3, 10), in: context)
        let second = TS.pay(invoice, 4.995, date: TS.day(2026, 3, 12), in: context)
        let receipts = (1...3).map { day in
            let receipt = TS.receipt(total: 1.005, category: "Tile", date: TS.day(2026, 3, day + 12), in: context)
            receipt.customer = customer
            return receipt
        }
        context.saveChanges()

        // The rows.
        let rows = dto(context)
        #expect(rows.row(first)["amount"]?.doubleValue == 5.01 && text(first.amount) == "$5.01")
        #expect(rows.row(second)["amount"]?.doubleValue == 5.00 && text(second.amount) == "$5.00")
        for receipt in receipts {
            #expect(rows.row(receipt)["total"]?.doubleValue == 1.01 && text(receipt.total) == "$1.01")
        }

        // Every total: the amounts as written, added exactly, rounded once — all in agreement.
        #expect(invoice.amountPaid == 10)
        #expect(invoice.balanceDue == 0 && invoice.isPaid)
        #expect(customer.totalPaidToUs == 10)
        #expect(DomainMoney.decimal(invoice.paidThrough(first)) + DomainMoney.decimal(invoice.remainingAfter(first))
                == DomainMoney.decimal(invoice.total), "paid to date + remaining == total on the first receipt")
        let firstBody = PaymentReceiptMessage.plainBody(invoice: invoice, payment: first, business: profile)
        #expect(firstBody.contains("Payment received: \(5.01.formatted(.money))")
                && firstBody.contains("Paid to date: \(5.01.formatted(.money))")
                && firstBody.contains("Remaining balance: \(4.99.formatted(.money))"), "\(firstBody)")
        let secondBody = PaymentReceiptMessage.plainBody(invoice: invoice, payment: second, business: profile)
        #expect(secondBody.contains("Paid to date: \(10.00.formatted(.money))")
                && secondBody.contains("Paid in full"), "\(secondBody)")
        let firstPDF = squeezed(try pdfText(PaymentReceiptPDF.render(invoice, payment: first, business: profile)))
        #expect(firstPDF.contains("$5.01") && firstPDF.contains("$4.99") && !firstPDF.contains("$5.00"), "\(firstPDF)")
        let secondPDF = squeezed(try pdfText(PaymentReceiptPDF.render(invoice, payment: second, business: profile)))
        #expect(secondPDF.contains("$10.00") && secondPDF.contains("$5.00") && !secondPDF.contains("$10.01"),
                "\(secondPDF)")

        let header = squeezed(try screenText(ReceiptsListScreen(customer: customer), container: container))
        #expect(header.contains("$3.02") && !header.contains("$3.03"), "\(header)")   // 3.015 → $3.02

        let summary = StatsEngine.summary(period: .all, invoices: [invoice], estimates: [], receipts: receipts)
        #expect(summary.collected == 10 && summary.expenses == 3.02 && summary.net == 6.98)
        #expect(summary.expensesByCategory.first?.amount == 3.02)
        #expect(summary.inOut.reduce(0) { $0 + $1.moneyIn } == 10)
        let files = StatsExport.files(period: .all, invoices: [invoice], estimates: [], receipts: receipts, business: profile)
        let csv = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(csv.components(separatedBy: "\n").filter { $0.contains(",1.01,") }.count == 3, "\(csv)")
        let taxSummary = try String(contentsOf: try #require(files.last), encoding: .utf8)
        #expect(taxSummary.contains("Collected (cash received): \(10.00.formatted(.money))")
                && taxSummary.contains("Total expenses: \(3.02.formatted(.money))"), "\(taxSummary)")

        let box = try MBToolHarness.toolbox(context)
        let report = MBToolHarness.output(await MBToolHarness.run(
            box, "report", ["kind": "money_summary", "date_from": "2026-03-01", "date_to": "2026-03-31", "query": "tile"]))
        #expect(report["collected"]?.doubleValue == 10)
        #expect(report["expenses"]?.doubleValue == 3.02)
        #expect(report["expenses_matching"]?["amount"]?.doubleValue == 3.02)

        // A processing fee is worked out on the amount as written, rounded once: 3% of $1.495 is
        // $0.04485 → $0.04 — never 3% of the row's $1.50 ($0.045 → $0.05).
        let card = InvoicePayment(amount: 1.495)
        card.processorName = "Card"
        card.processorFeePercentSnapshot = 3
        #expect(card.processingFee == 0.04)

        // The Worker's vector, in the app: none of these is a tie, and they add to exactly $1,000.
        let thirds = TS.invoice(number: "INV-0065", status: .sent, lines: [(1000, false)], in: context)
        for amount in [333.333, 333.333, 333.334] { TS.pay(thirds, amount, in: context) }
        context.saveChanges()
        #expect(thirds.amountPaid == 1000 && thirds.balanceDue == 0 && thirds.isPaid)
    }

    /// The screen and the assistant now store the same value: every typed amount is rounded to the
    /// cent when its service writes it — a payment, a receipt, a subcontractor's flat entry and
    /// "Pay now", an employee's bonus and paycheck, the amount-due request — and the request is
    /// drawn down exactly (29,926.295 less 24,807.80 used to ask for $5,118.49, not $5,118.50).
    @Test func typedAmountsAreStoredAsTheyShow() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            let invoice = TS.invoice(number: "INV-0062", status: .sent, lines: [(20, false)], in: context)
            context.saveChanges()
            let first = try InvoiceService.recordPayment(on: invoice, amount: 5.005, method: .cash,
                                                         origin: .screen, in: context)
            let second = try InvoiceService.recordPayment(on: invoice, amount: 4.995, method: .cash, in: context)
            #expect(first.amount == 5.01 && second.amount == 5.00)
            #expect(invoice.amountPaid == 10.01 && invoice.balanceDue == 9.99)
            #expect(throws: DomainError.self) {         // rounds to $0.00: nothing to record
                try InvoiceService.recordPayment(on: invoice, amount: 0.004, method: .cash, in: context)
            }

            let milestone = TS.invoice(number: "INV-0063", status: .sent, lines: [(30_000, false)], in: context)
            context.saveChanges()
            try InvoiceService.setAmountDue(milestone, amount: 29_926.295, detail: "Draw 1", in: context)
            #expect(milestone.amountDueNow == 29_926.30 && milestone.currentAmountDue == 29_926.30)
            _ = try InvoiceService.recordPayment(on: milestone, amount: 24_807.80, method: .check, in: context)
            #expect(milestone.amountDueNow == 5_118.50 && milestone.currentAmountDue == 5_118.50)
            let older = TS.invoice(number: "INV-0064", status: .sent, lines: [(30_000, false)], in: context)
            older.amountDueNow = 29_926.295              // a request an older build stored as typed
            context.saveChanges()
            _ = try InvoiceService.recordPayment(on: older, amount: 24_807.80, method: .check, in: context)
            #expect(older.amountDueNow == 5_118.50, "the request as it read, less the payment")

            let receipt = try ReceiptService.create(ReceiptDraft(vendor: "Tile Depot", total: 1.005), in: context)
            #expect(receipt.total == 1.01)
            #expect(!ReceiptDraft(total: 0.004).hasDetails, "a total that stores as $0.00 is no detail")

            let sub = TS.subcontractor(in: context)
            let owed = try SubcontractorService.recordEntry(.dollars(1.005, on: .now), detail: "Grout", customer: nil,
                                                            paidOn: nil, method: .check, for: sub, in: context)
            #expect(owed.amount == 1.01 && sub.outstanding == 1.01)
            let paid = try SubcontractorService.payNow(1.005, paidDate: .now, method: .check, for: sub, in: context)
            #expect(paid.count == 1 && paid.first?.amount == 1.01 && sub.outstanding == 0)

            let employee = TS.employee(hourlyRate: 10.01, in: context)
            let bonus = try EmployeeService.logBonus(1.005, on: .now, note: "", for: employee, in: context)
            #expect(bonus.amount == 1.01)
            let check = try EmployeeService.recordPaycheck(for: employee, amount: 1.005, bonus: 0.995, payDate: .now,
                                                           method: .check, note: "", in: context)
            #expect(check.grossAmount == 2.01 && check.note.contains(1.00.formatted(.money)))
            try EmployeeService.editPaycheck(check, payDate: .now, gross: 2.005, method: .check, note: "", in: context)
            #expect(check.grossAmount == 2.01)

            let job = try JobService.create(JobDraft(title: "Floor", startDate: .now, agreedPrice: 2_500.005),
                                            for: TS.customer(in: context), origin: .screen, in: context)
            #expect(job.agreedPrice == 2_500.01, "the form stores what the assistant's boundary stores")
        }
    }

    /// Two 1.5-hour entries at $10.01 are $15.015 each, $30.03 together (added exactly, rounded once —
    /// the accrued pay on screen). Paying that $30.03 settles both: it used to settle the first at its
    /// row's $15.02, find $15.01 left for the second's $15.02, split it and leave a sliver owed.
    @Test func payingTheAccruedPayShownSettlesEveryEntry() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 10.01, in: context)
        try DomainState.subscribed.run {
            for day in [2, 3] {
                _ = try EmployeeService.logTime(.hours(1.5, on: TS.day(2026, 3, day), rate: 10.01), customer: nil,
                                                note: "", for: employee, in: context)
            }
            #expect(employee.accruedGross == 30.03)
            let check = try EmployeeService.recordPaycheck(for: employee, amount: employee.accruedGross,
                                                           payDate: TS.day(2026, 3, 6), method: .check, note: "",
                                                           in: context)
            #expect(check.grossAmount == 30.03 && check.hoursPaid == 3)
        }
        #expect(employee.accruedGross == 0)
        #expect(employee.liveRows(employee.timeEntries).count == 2, "no slice split off")
        #expect(employee.liveRows(employee.timeEntries).allSatisfy { $0.paycheck != nil })
    }

    /// The same rule for rows an older build stored with a fraction of a cent: two flat entries of
    /// $1.005 are owed $2.01 (added exactly, rounded once — never $1.01 + $1.01 = $2.02), and paying
    /// that $2.01 settles both, for an employee and for a subcontractor (`DomainMoney.settle`). Taking
    /// each entry at its own cents used to settle the first at $1.01, split the second and leave a
    /// cent owed.
    @Test func payingTheOwedTotalShownSettlesOlderSubCentEntries() throws {
        let context = try DomainFixtures.context()
        let employee = TS.employee(hourlyRate: 10, in: context)
        let sub = TS.subcontractor(in: context)
        for day in [2, 3] {
            let entry = TimeEntry(date: TS.day(2026, 3, day), amount: 1.005)
            entry.employee = employee
            employee.timeEntries = (employee.timeEntries ?? []) + [entry]
            context.insert(entry)
            TS.oweSub(sub, 1.005, date: TS.day(2026, 3, day), in: context)
        }
        context.saveChanges()
        #expect(employee.accruedGross == 2.01 && sub.outstanding == 2.01)
        try DomainState.subscribed.run {
            let check = try EmployeeService.recordPaycheck(for: employee, amount: employee.accruedGross,
                                                           payDate: TS.day(2026, 3, 6), method: .check, note: "",
                                                           in: context)
            #expect(check.grossAmount == 2.01)
            let paid = try SubcontractorService.payNow(sub.outstanding, paidDate: TS.day(2026, 3, 6), method: .check,
                                                       for: sub, in: context)
            #expect(paid.count == 2, "both entries settle; no slice, no extra")
        }
        #expect(employee.accruedGross == 0 && employee.liveRows(employee.timeEntries).count == 2)
        #expect(sub.outstanding == 0 && sub.liveRows(sub.payments).count == 2)
        #expect(sub.lifetimePaid == 2.01)
    }

    /// Prices, rates and percentages are kept as typed on BOTH doors, and the amount made from them
    /// is rounded once, so the form and the assistant make the same document: 1,000 sq ft × $0.125
    /// less 12.345% is $125.00 − $15.43 = $109.57 either way (the assistant's boundary used to round
    /// the price to $0.13 and the percentage to 12.35% first — $130.00 − $16.06), and 7.5 h × $43.735
    /// is $328.0125 → $328.01 for an employee and a subcontractor (not 7.5 × $43.74 = $328.05).
    @Test func theFormAndTheAssistantMakeTheSameAmountFromATypedPriceOrRate() async throws {
        let world = try MBWriteWorld()
        let context = world.context

        var draft = InvoiceDraft()
        draft.jobTitle = "Floor"
        draft.discountType = .percentage
        draft.discountValue = 12.345
        var line = InvoiceLineDraft()
        line.name = "Tile install"
        line.quantity = 1000
        line.unitPrice = 0.125
        draft.groups = [InvoiceGroupDraft(name: "Work", lines: [line])]
        let byForm = try DomainState.subscribed.run {
            try InvoiceService.create(draft, for: world.customer, origin: .screen, in: context)
        }
        _ = MBWriteHarness.output(await MBWriteHarness.run(world.box, "create_invoice", [
            "customer_id": .string(world.customerID), "job_title": "Floor",
            "discount_type": "percentage", "discount_value": .number(12.345),
            "groups": [["name": "Work", "lines": [["name": "Tile install", "quantity": .number(1000),
                                                   "unit_price": .number(0.125)]]]],
        ]))
        let byAssistant = try #require(world.invoices().first { $0.persistentModelID != byForm.persistentModelID })
        for invoice in [byForm, byAssistant] {
            let item = try #require(invoice.allLineItems.first)
            #expect(item.unitPrice == 0.125 && item.lineTotal == 125, "\(invoice.number)")
            #expect(invoice.discountValue == 12.345 && invoice.discountAmount == 15.43 && invoice.total == 109.57,
                    "\(invoice.number)")
        }

        let employee = TS.employee(hourlyRate: 20, in: context)
        let sub = TS.subcontractor(in: context)
        context.saveChanges()
        let formEntry = try DomainState.subscribed.run {
            try EmployeeService.logTime(.hours(7.5, on: TS.day(2026, 3, 2), rate: 43.735), customer: nil, note: "",
                                        for: employee, in: context)
        }
        let assistantEntry = MBWriteHarness.output(await MBWriteHarness.run(world.box, "log_time", [
            "employee_id": .string(world.id(employee)), "mode": "hours", "hours": .number(7.5),
            "rate": .number(43.735), "date": "2026-03-03",
        ]))
        #expect(formEntry.grossValue == 328.01 && formEntry.rateSnapshot == 43.735)
        #expect(assistantEntry["time_entry"]?["amount"]?.doubleValue == 328.01)
        #expect(employee.liveRows(employee.timeEntries).allSatisfy { $0.rateSnapshot == 43.735 && $0.grossValue == 328.01 })

        let formWork = try DomainState.subscribed.run {
            try SubcontractorService.recordEntry(.hours(7.5, on: TS.day(2026, 3, 2), rate: 43.735), detail: "Tile",
                                                 customer: nil, paidOn: nil, method: .check, for: sub, in: context)
        }
        let assistantWork = MBWriteHarness.output(await MBWriteHarness.run(world.box, "log_sub_work", [
            "subcontractor_id": .string(world.id(sub)), "mode": "hours", "hours": .number(7.5),
            "rate": .number(43.735), "date": "2026-03-03", "detail": "Tile",
        ]))
        #expect(formWork.amount == 328.01)
        #expect(assistantWork["sub_payment"]?["amount"]?.doubleValue == 328.01)
        #expect(sub.outstanding == 656.02)

        // The price sheet and an estimate's deposit percentage keep what was sent too.
        let item = MBWriteHarness.output(await MBWriteHarness.run(world.box, "save_price_item", [
            "name": "Mosaic", "unit": "squareFoot", "unit_price": .number(0.125), "kind": "material",
        ]))
        let priceItem = try #require(MBRecordLookup.record(.priceItem, id: MBWriteHarness.id(item, "price_item"),
                                                           as: PriceSheetItem.self, in: context))
        #expect(priceItem.unitPrice == 0.125)
        // …and the assistant READS them back exact (law 60, found 2026-09-29: the DTOs rounded
        // rates to cents, so the model saw $0.13 a piece and $43.74 an hour).
        let readItem = MBWriteHarness.output(await MBWriteHarness.run(world.box, "get", [
            "kind": "price_item", "id": .string(MBWriteHarness.id(item, "price_item"))]))
        #expect(Self.values(for: "unit_price", in: readItem).contains(0.125), "\(readItem)")
        let listed = MBWriteHarness.output(await MBWriteHarness.run(world.box, "find", ["kind": "price_item"]))
        #expect(Self.values(for: "unit_price", in: listed).contains(0.125), "\(listed)")
        let hours = MBWriteHarness.output(await MBWriteHarness.run(world.box, "get", [
            "kind": "time_entry", "id": .string(MBWriteHarness.id(assistantEntry, "time_entry"))]))
        #expect(Self.values(for: "rate", in: hours).contains(43.735), "\(hours)")
        _ = MBWriteHarness.output(await MBWriteHarness.run(world.box, "create_estimate", [
            "customer_id": .string(world.customerID), "job_title": "Floor",
            "deposit_type": "percentage", "deposit_value": .number(12.345),
            "groups": [["lines": [["name": "Tile install", "quantity": .number(1000), "unit_price": .number(0.125)]]]],
        ]))
        let estimate = try #require(world.estimates().first)
        #expect(estimate.depositValue == 12.345 && estimate.total == 125)
        #expect(estimate.depositAmount == 15.43)        // 125 × 12.345% = 15.43125 — never 12.35% = 15.44
    }

    /// A change order is a document too: 1.5 × $100.35 = $150.525 → $150.53 on the saved order, the
    /// form's preview (the same formula) and the PDF the customer signs.
    @Test func aChangeOrderTieShowsAndBillsTheSameCent() throws {
        let invoice = TS.invoice(lines: [(1000, false)])
        let order = TS.changeOrder(invoice, status: .approved, lines: [(100.35, false)])
        try #require(order.sortedLineItems.first).quantity = 1.5
        #expect(order.total == 150.53)
        let draft = ChangeOrderLineDraft(name: "Extra coat", quantity: 1.5, unitPrice: 100.35)
        #expect(ChangeOrderMath.totals(lines: [(draft.exactLineTotal, draft.isTaxable)], taxRatePercent: 0).total
                == order.total, "the form's preview is the saved order's formula")
        #expect(invoice.revisedTotal == 1150.53)
        let pdf = squeezed(try pdfText(ChangeOrderPDF.render(order, business: nil)))
        #expect(pdf.contains("150.53") && !pdf.contains("150.52"), "\(pdf)")
    }

    /// A change-order CREDIT of an exact half cent rounds away from zero (-$150.525 → -$150.53) on the
    /// saved order, its row and its group; and the revised total the order shows before it is added
    /// ($1,000 − $150.525 = $849.475 → $849.48, worked out exactly and rounded once) is exactly what
    /// the invoice bills after it is added.
    @Test func aCreditHalfCentRoundsAwayFromZeroAndTheRevisedTotalIsWhatGetsBilled() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(lines: [(1000, false)], in: context)
        let order = TS.changeOrder(invoice, status: .approved, lines: [(-100.35, false)], in: context)
        try #require(order.sortedLineItems.first).quantity = 1.5         // 1.5 × −100.35 = −150.525
        context.saveChanges()
        #expect(order.total == -150.53)
        #expect(invoice.approvedChangeOrderTotal == -150.53)
        #expect(invoice.revisedTotal == 849.48)
        #expect(ChangeOrderPDFDocument(changeOrder: order, business: nil).revisedTotal == 849.48)
        #expect(ChangeOrderMessage.plainBody(order, business: nil).contains("Revised total: \(849.48.formatted(.money))"))

        // Added to the invoice by the real path: a full-price, signed credit line in its own group.
        order.addItemsToInvoice(using: context)
        context.saveChanges()
        let group = try #require(invoice.sortedGroups.first { $0.changeOrder === order })
        let credit = try #require(group.sortedLineItems.first)
        let screen = InvoiceDetailScreen(invoice: invoice)
        #expect(screen.displayLineTotal(credit) == -150.53)
        #expect(screen.groupSubtotal(group) == -150.53)
        #expect(invoice.total == 849.48, "the invoice bills the revised total the order showed")
        #expect(ChangeOrderPDFDocument(changeOrder: order, business: nil).revisedTotal == invoice.total)

        // The assistant is handed the group as the screen and the PDF show it — the signed credit,
        // never the floored $0.00 — next to the signed line it lists for it.
        let groups = dto(context).detail(invoice)["groups"]?.arrayValue ?? []
        let row = try #require(groups.first { $0["name"]?.stringValue == group.name })
        #expect(row["subtotal"]?.doubleValue == -150.53)
    }

    // MARK: - The call sites

    /// Every money text goes through `.money` and every charge through `wholeCents` — a new screen
    /// that formats with the system's tie-to-even style, or takes cents off a binary value, fails here.
    @Test func everyMoneyTextAndEveryChargeGoesThroughTheOneRule() {
        var offenders: [String] = []
        for file in GLSource.files(excluding: ["Services/Domain/DomainMoney.swift"]) {
            for (number, line) in file.text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let at = "\(file.path):\(number + 1)"
                if line.contains(".currency(code:") { offenders.append("\(at) money text without .money") }
                if line.range(of: #"Int\(\(.*\* ?100\)\.rounded\(\)\)"#, options: .regularExpression) != nil {
                    offenders.append("\(at) cents taken off a binary value — use DomainMoney.wholeCents")
                }
                if line.contains("String(format: \"%.2f"), line.range(of: "hours", options: .caseInsensitive) == nil {
                    offenders.append("\(at) %.2f rounds the binary value — use DomainMoney.plain")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    // MARK: - The sync Worker's copy

    /// gl-business-api `test/vectors/money.json`, beside this repo.
    nonisolated static var workerVectors: URL {
        URL(fileURLWithPath: #filePath)                     // …/SmallBusinessApp/GLSmallBusinessTests/MoneyRoundingTests.swift
            .deletingLastPathComponent()                    // …/SmallBusinessApp/GLSmallBusinessTests
            .deletingLastPathComponent()                    // …/SmallBusinessApp
            .deletingLastPathComponent()                    // …/Github
            .appendingPathComponent("gl-business-api/test/vectors/money.json")
    }

    /// The Worker's paid lock recomputes every invoice with src/money.ts; the shared vectors are its
    /// contract. Replayed through the app's own models, every amount must match exactly and every
    /// Paid verdict must agree — or the app and the Worker disagree about whether an invoice is paid.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: MoneyRoundingTests.workerVectors.path)))
    func theWorkersMoneyVectorsReplayHereToTheCent() throws {
        let data = try Data(contentsOf: Self.workerVectors)
        let vectors = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var replayed = 0
        for vector in vectors {
            let name = vector["name"] as? String ?? "(unnamed)"
            let expect = try #require(vector["expect"] as? [String: Any], "\(name)")
            let actual: [String: Double]
            switch vector["fn"] as? String {
            case "invoice_derived":
                let invoice = Self.invoice(from: vector)
                #expect((expect["isPaid"] as? Bool) == invoice.isPaid, "\(name): isPaid")
                actual = ["subtotal": invoice.subtotal, "discountAmount": invoice.discountAmount,
                          "taxAmount": invoice.taxAmount, "total": invoice.total,
                          "amountPaid": invoice.amountPaid, "balanceDue": invoice.balanceDue]
            case "estimate_totals":
                let totals = EstimateTotals(
                    lines: (vector["lines"] as? [[String: Any]] ?? []).map {
                        (lineTotal: DomainMoney.decimal(Self.number($0["lineTotal"])), isTaxable: Self.flag($0["isTaxable"]))
                    },
                    taxRatePercent: Self.number(vector["taxRatePercent"]),
                    discountType: Self.adjustment(vector["discountType"]), discountValue: Self.number(vector["discountValue"]),
                    depositType: Self.adjustment(vector["depositType"]), depositValue: Self.number(vector["depositValue"]))
                actual = ["subtotal": totals.subtotal, "discount": totals.discount, "tax": totals.tax,
                          "total": totals.total, "deposit": totals.deposit]
            default:
                Issue.record("\(name): unknown fn")
                continue
            }
            for (key, value) in actual {
                #expect(Self.number(expect[key], .nan) == value, "\(name): \(key) is \(value)")
            }
            replayed += 1
        }
        #expect(replayed == vectors.count && replayed > 30, "every vector replayed")
    }

    /// A JSON number, or `fallback` for anything else — the Worker's `num()` (missing → model default).
    private static func number(_ value: Any?, _ fallback: Double = 0) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
        return number.doubleValue.isFinite ? number.doubleValue : fallback
    }

    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// An unknown adjustment reads as none — the Worker's deviation 1, and what the sync decoder does.
    private static func adjustment(_ value: Any?) -> AdjustmentType {
        AdjustmentType(rawValue: value as? String ?? "") ?? .none
    }

    /// A detached invoice built from a vector's payloads, missing fields at the model defaults.
    private static func invoice(from vector: [String: Any]) -> Invoice {
        let fields = vector["invoice"] as? [String: Any] ?? [:]
        let invoice = Invoice(number: "VECTOR")
        invoice.taxRatePercent = number(fields["taxRatePercent"])
        invoice.discountType = adjustment(fields["discountType"])
        invoice.discountValue = number(fields["discountValue"])
        invoice.status = InvoiceStatus(rawValue: fields["status"] as? String ?? "") ?? .draft
        invoice.groups = (vector["groups"] as? [[String: Any]] ?? []).map { entry in
            let group = InvoiceGroup(sortIndex: Int(number((entry["group"] as? [String: Any])?["sortIndex"])))
            group.invoice = invoice
            // A group pushed from a change order: the order's payload rides as the entry's
            // `changeOrder`, and its signed rate taxes the group's change-order lines (QA F82).
            if let order = entry["changeOrder"] as? [String: Any] {
                group.changeOrder = ChangeOrder(number: "CO-VECTOR", taxRatePercent: number(order["taxRatePercent"]))
            }
            group.lineItems = (entry["lines"] as? [[String: Any]] ?? []).map { line in
                let item = InvoiceLineItem(quantity: number(line["quantity"], 1), unitPrice: number(line["unitPrice"]),
                                           isTaxable: flag(line["isTaxable"]), sortIndex: Int(number(line["sortIndex"])),
                                           discountType: adjustment(line["discountType"]),
                                           discountValue: number(line["discountValue"]))
                item.fromChangeOrder = flag(line["fromChangeOrder"])
                item.group = group
                return item
            }
            return group
        }
        invoice.payments = (vector["payments"] as? [[String: Any]] ?? []).map { entry in
            let payment = InvoicePayment(amount: number(entry["amount"]))
            payment.invoice = invoice
            return payment
        }
        return invoice
    }

    /// Every number stored under `key`, anywhere inside `json`.
    static func values(for key: String, in json: GLAIJSON) -> [Double] {
        switch json {
        case .object(let fields):
            return fields.flatMap { k, v in (k == key ? [v.doubleValue].compactMap { $0 } : []) + values(for: key, in: v) }
        case .array(let items):
            return items.flatMap { values(for: key, in: $0) }
        default:
            return []
        }
    }
}
