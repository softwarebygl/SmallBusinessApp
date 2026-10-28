//
//  DemoMode.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  Screenshot/demo support. Active ONLY in DEBUG builds launched with the `-demoMode` argument,
//  so it can never affect a real user's app. When active, the gate is bypassed and a realistic
//  sample dataset is seeded into an empty store.
//

import Foundation
import SwiftData
import GoldLifeMoney
#if canImport(UIKit)
import UIKit
#endif

enum DemoMode {
    static var isActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoMode")
        #else
        false
        #endif
    }
}

/// Release-visible since the sample-data door became a standard (every GL app
/// offers "Explore with sample data" from its gate — Adrian, 2026-08-28): this
/// dataset is what that door seeds, so it can no longer be DEBUG-only. The
/// screenshot-harness extras inside stay gated where they must be.
///
/// INVARIANT (the sample data must be disposable): a person exploring sample data taps "Exit" and
/// is left with exactly the device state they had. Everything here goes into the passed-in
/// `ModelContext`, with ONE deliberate exception: taxpayer IDs go through SecureTINStore, which
/// `UserDemoMode.startDemo` has already swapped to memory for the session, so they are disposable
/// too. No UserDefaults, no files on disk, no un-fenced Keychain. Anything that outlives the
/// container is a defect, not a detail.
enum DemoSeed {
    @MainActor
    static func populate(_ context: ModelContext) {
        // Idempotent: only seed an empty store.
        let existing = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        guard existing.isEmpty else { return }

        let biz = BusinessProfile()
        biz.businessName = "Summit Tile & Stone"
        biz.phone = "(850) 555-0142"
        biz.email = "office@summittilestone.com"
        biz.licenseNumber = "CBC1245789"
        biz.address = Address(street1: "1280 Commerce Blvd", city: "Miami", state: "FL", postalCode: "33131")
        biz.warrantyText = "Summit Tile & Stone warrants all installed tile and stone workmanship for one (1) year from the date of completion — including cracked grout lines and loose or lifting tile due to installation. It does not cover damage from impact, abuse, structural movement, or normal wear."
        biz.w9TINTypeRaw = W9TINType.ein.rawValue
        // Safe because SecureTINStore swaps to memory for the whole sample session
        // (UserDemoMode.startDemo). Without that fence this line would replace the owner's REAL
        // EIN/SSN in the device and iCloud Keychain with a fictional number, and the sample W-9
        // would print the owner's own — the Keychain is device state, and the sample container's
        // disposability does not cover it.
        biz.updateTIN("98-7654321")   // payer EIN, so the demo 1099-NEC can be generated
        // For the "Get Paid" (Stripe) marketing shot only: seed a connected, charge-ready account so
        // the screen shows the finished state + the Pay-button picker. Scoped to `-demoScreen stripe`
        // so normal demo/UI-test runs are unaffected.
        #if DEBUG
        if DemoMode.screen == "stripe" {
            biz.stripeConnectedAccountId = "acct_demo"
            biz.stripeChargesEnabled = true
            biz.payLinkDefaultOn = true
        }
        #endif
        #if canImport(UIKit)
        // Only brand the demo business when explicitly requested (-demoBrand). Without it,
        // the app falls back to the bundled GL logo — so the default screenshots show the
        // GL design, and -demoBrand is used to demonstrate white-labeling.
        if ProcessInfo.processInfo.arguments.contains("-demoBrand"),
           let logo = UIImage(named: "DemoBrandLogo")?.pngData() {
            biz.logoData = logo
            // Light variant for light mode; white variant so the logo stays visible in dark mode.
            biz.logoDataDark = UIImage(named: "DemoBrandLogoDark")?.pngData() ?? logo
        }
        #endif
        context.insert(biz)

        let c1 = Customer(firstName: "Marcus", lastName: "Reed", email: "marcus@reedgc.com",
                          phoneNumber: "(850) 555-0193", businessName: "Reed General Contracting",
                          address: Address(street1: "1180 Capital Cir NE", city: "Miami", state: "FL", postalCode: "33131"))
        let c2 = Customer(firstName: "Danielle", lastName: "Carter", email: "dani.carter@gmail.com",
                          phoneNumber: "(850) 555-0148",
                          address: Address(street1: "742 Magnolia Dr", city: "Miami", state: "FL", postalCode: "33131"))
        let c3 = Customer(firstName: "Sofia", lastName: "Nguyen", email: "sofia@nguyenpm.com",
                          phoneNumber: "(850) 555-0176", businessName: "Nguyen Property Management",
                          address: Address(street1: "305 John Knox Rd", city: "Miami", state: "FL", postalCode: "33131"))
        [c1, c2, c3].forEach(context.insert)

        // demo receipts (fictional vendors) for the Receipts + Stats screenshots
        let r1 = Receipt(vendor: "Henderson Hardware", date: .now.addingTimeInterval(-4 * 86_400), total: 127.43, category: "Materials", notes: "Tile spacers, grout, mortar", customer: c1)
        let r2 = Receipt(vendor: "Coastal Supply", date: .now.addingTimeInterval(-2 * 86_400), total: 456.78, category: "Materials", notes: "LVP flooring stock", customer: c2)
        let r3 = Receipt(vendor: "Sunbelt Tool Rental", date: .now.addingTimeInterval(-6 * 86_400), total: 184.00, category: "Equipment", notes: "Wet saw, 2-day rental", customer: c1)
        let r4 = Receipt(vendor: "QuickStop Fuel", date: .now.addingTimeInterval(-1 * 86_400), total: 62.15, category: "Fuel", notes: "Job-site travel", customer: nil)
        [r1, r2, r3, r4].forEach(context.insert)

        // Estimate 1 — Marcus, master bath tile (Sent)
        let e1 = Estimate(number: "EST-0001", jobTitle: "Master Bath — Porcelain Tile",
                          createdAt: .now.addingTimeInterval(-2 * 86_400), status: .sent, customer: c1)
        e1.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Miami", state: "FL", postalCode: "33131")
        e1.taxRatePercent = 7.5
        e1.depositType = .percentage; e1.depositValue = 30
        e1.terms = "Balance due on completion. Estimate valid for 30 days."
        context.insert(e1)
        let e1a = EstimateGroup(name: "Tile & Flooring", sortIndex: 0); e1a.estimate = e1; context.insert(e1a)
        let e1b = EstimateGroup(name: "Prep & Demo", sortIndex: 1); e1b.estimate = e1; context.insert(e1b)
        insert(into: context, group: e1a, [
            .init(name: "Porcelain tile 12×24", details: "Matte, rectified", quantity: 130, unit: .squareFoot, unitPrice: 4.25, kind: .material, isTaxable: true),
            .init(name: "Tile installation", details: "Set, grout, seal", quantity: 120, unit: .squareFoot, unitPrice: 6.50, kind: .labor, isTaxable: false),
            .init(name: "Thinset, grout & sealer", quantity: 1, unit: .job, unitPrice: 180, kind: .material, isTaxable: true),
        ])
        insert(into: context, group: e1b, [
            .init(name: "Demo & haul-away", quantity: 1, unit: .job, unitPrice: 450, kind: .labor, isTaxable: false),
            .init(name: "Floor leveling", quantity: 120, unit: .squareFoot, unitPrice: 2.00, kind: .labor, isTaxable: false),
        ])

        // Estimate 2 — Danielle, LVP (Accepted)
        let e2 = Estimate(number: "EST-0002", jobTitle: "Luxury Vinyl Plank — Living & Hall",
                          createdAt: .now.addingTimeInterval(-6 * 86_400), status: .accepted, customer: c2)
        e2.taxRatePercent = 7.5
        e2.depositType = .percentage; e2.depositValue = 25
        context.insert(e2)
        let e2a = EstimateGroup(name: "Flooring", sortIndex: 0); e2a.estimate = e2; context.insert(e2a)
        insert(into: context, group: e2a, [
            .init(name: "LVP — European Oak", details: "7\" wide, 20-mil wear layer", quantity: 540, unit: .squareFoot, unitPrice: 3.10, kind: .material, isTaxable: true),
            .init(name: "LVP installation", quantity: 540, unit: .squareFoot, unitPrice: 2.25, kind: .labor, isTaxable: false),
            .init(name: "Underlayment", quantity: 540, unit: .squareFoot, unitPrice: 0.45, kind: .material, isTaxable: true),
        ])

        context.saveChanges()

        // Invoice — converted from Estimate 2, deposit paid (Partially Paid)
        let inv = Invoice.make(from: e2, number: "INV-0001", in: context)
        inv.createdAt = .now.addingTimeInterval(-3 * 86_400)
        inv.status = .sent
        // Stored as it shows, whole cents (law 60) — like every recorded payment.
        let deposit = inv.amountDueNow > 0 ? DomainMoney.decimal(inv.amountDueNow) : DomainMoney.product(inv.total, 0.25)
        let pay = InvoicePayment(amount: DomainMoney.roundedToCents(deposit),
                                 date: .now.addingTimeInterval(-1 * 86_400), method: .check, note: "Deposit to start")
        pay.invoice = inv
        context.insert(pay)

        // A progress payment so the demo shows a healthy positive net (income comfortably above expenses).
        let pay2 = InvoicePayment(amount: 1400, date: .now.addingTimeInterval(-43_200), method: .card, note: "Progress payment")
        pay2.invoice = inv
        context.insert(pay2)
        // The seed inserts payments directly (bypassing recordPayment, which normally decrements this),
        // so clear the deposit request — it's fully covered by the payments above.
        inv.amountDueNow = 0

        // Demo employees: hours (one crosses 40 → over-40 flag), accrued pay, and a recorded paycheck.
        let nextFriday = Calendar.current.nextDate(after: .now, matching: DateComponents(weekday: 6),
                                                   matchingPolicy: .nextTime) ?? .now
        let emp1 = Employee(firstName: "Owen", lastName: "Caldwell", email: "owen.caldwell@example.com",
                            phone: "(850) 555-0110", payType: .hourly, hourlyRate: 28,
                            payFrequency: .weekly, anchorPayday: nextFriday,
                            hireDate: .now.addingTimeInterval(-300 * 86_400))
        let emp2 = Employee(firstName: "Hannah", lastName: "Whitfield", email: "hannah.whitfield@example.com",
                            phone: "(850) 555-0121", payType: .hourly, hourlyRate: 24,
                            payFrequency: .biweekly, anchorPayday: nextFriday,
                            hireDate: .now.addingTimeInterval(-540 * 86_400))
        let emp3 = Employee(firstName: "Caleb", lastName: "Fletcher", email: "caleb.fletcher@example.com",
                            phone: "(850) 555-0137", payType: .salary, annualSalary: 62_400,
                            payFrequency: .monthly, anchorPayday: nextFriday,
                            hireDate: .now.addingTimeInterval(-800 * 86_400))
        [emp1, emp2, emp3].forEach(context.insert)

        for (offset, hours) in [(0, 9.0), (-1, 9.0), (-2, 9.0), (-3, 9.0), (-4, 9.0)] {
            let entry = TimeEntry(date: .now.addingTimeInterval(Double(offset) * 86_400), hours: hours,
                                  rateSnapshot: 28, employee: emp1, customer: c1)
            context.insert(entry)
        }
        for (offset, hours) in [(0, 8.0), (-1, 7.5), (-2, 8.0)] {
            let entry = TimeEntry(date: .now.addingTimeInterval(Double(offset) * 86_400), hours: hours,
                                  rateSnapshot: 24, employee: emp2, customer: c2)
            context.insert(entry)
        }
        let paycheck = Paycheck(payPeriodStart: .now.addingTimeInterval(-21 * 86_400),
                                payPeriodEnd: .now.addingTimeInterval(-8 * 86_400),
                                payDate: .now.addingTimeInterval(-7 * 86_400),
                                grossAmount: 24 * 76, hoursPaid: 76, method: .check, employee: emp2)
        context.insert(paycheck)

        // Demo subcontractors: one over the 1099-NEC threshold ($3,050 clears even the 2026 $2,000
        // figure), one under it — keep that contrast if these amounts ever change.
        let sub1 = Subcontractor(firstName: "Luis", lastName: "Mendoza", businessName: "Mendoza Plumbing",
                                 email: "luis@mendozaplumbing.com", phone: "(850) 555-0164",
                                 address: Address(street1: "904 Industrial Dr", city: "Miami", state: "FL", postalCode: "33131"))
        let sub2 = Subcontractor(firstName: "Tara", lastName: "Boyd", businessName: "Boyd Electric",
                                 email: "tara@boydelectric.com", phone: "(850) 555-0188", hourlyRate: 20)
        [sub1, sub2].forEach(context.insert)
        // Same fence as the business TIN above. Un-fenced, these are worse than an overwrite: each
        // sub's Keychain item is keyed by a `tinKey` minted into the throwaway container, so the
        // only handle `clearSecureTIN` could ever use dies with it — every tap of "Explore with
        // sample data" would strand two more fake SSN/EIN items across the owner's devices,
        // unreachable from inside the app forever.
        sub1.w9TINType = .ein; sub1.updateTIN("12-3456789")     // EIN — has a W-9 on file
        sub2.w9TINType = .ssn; sub2.updateTIN("123-45-6789")
        for (offset, amount, note) in [(-30.0, 1_800.0, "Rough-in plumbing — Reed job"), (-10.0, 1_250.0, "Fixture set")] {
            let d = Date.now.addingTimeInterval(offset * 86_400)
            let p = SubPayment(amount: amount, date: d, paidDate: d, method: .check,
                               detail: note, subcontractor: sub1, customer: c1)
            context.insert(p)
        }
        let paid2 = SubPayment(amount: 425, date: .now.addingTimeInterval(-5 * 86_400),
                               paidDate: .now.addingTimeInterval(-5 * 86_400), method: .transfer,
                               detail: "Panel inspection fix", subcontractor: sub2, customer: c2)
        context.insert(paid2)
        // An OWED (unpaid) entry — the "I owe him $100 for 5 hours last Friday" scenario.
        let owed = SubPayment(amount: 100, hours: 5, date: .now.addingTimeInterval(-3 * 86_400),
                              detail: "5 hrs — helped on the Reed job", subcontractor: sub2, customer: c1)
        context.insert(owed)

        // Demo calendar bookings — a spread that shows every Phase-1 Job path: two scheduled from a
        // source doc (with open workdays between them so "View gaps" has content), one created from
        // scratch (verbal price, no source), and one already completed.
        let job1 = ScheduledJob(title: inv.jobTitle.isEmpty ? "Kitchen tile install" : inv.jobTitle,
                                customerName: inv.customerDisplayName,
                                startDate: .now.addingTimeInterval(3 * 86_400), durationDays: 3,
                                invoice: inv, customer: inv.customer)
        let job2 = ScheduledJob(title: e1.jobTitle, customerName: e1.customerDisplayName,
                                startDate: .now.addingTimeInterval(18 * 86_400), durationDays: 4,
                                estimate: e1, customer: e1.customer)
        let job3 = ScheduledJob(title: "Bathroom regrout", customerName: c2.listDisplayName,
                                startDate: .now.addingTimeInterval(30 * 86_400), durationDays: 1,
                                customer: c2, serviceAddress: c2.address, agreedPrice: 450)
        let job4 = ScheduledJob(title: "Backsplash install", customerName: c1.listDisplayName,
                                startDate: .now.addingTimeInterval(-12 * 86_400), durationDays: 2,
                                customer: c1, serviceAddress: c1.address, agreedPrice: 1_200, status: .completed)
        job4.completedAt = .now.addingTimeInterval(-10 * 86_400)
        // A timed job (a 2-hour cleaning) — shares its day, shows a time, and creates intra-day gaps.
        let job5 = ScheduledJob(title: "Recurring cleaning", customerName: c1.listDisplayName,
                                startDate: .now.addingTimeInterval(2 * 86_400),
                                customer: c1, serviceAddress: c1.address, agreedPrice: 120)
        job5.isAllDay = false
        job5.startTime = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0,
                                               of: .now.addingTimeInterval(2 * 86_400))
        job5.durationMinutes = 120
        job5.recurrenceFrequencyRaw = RecurrenceFrequency.weekly.rawValue   // a standing weekly cleaning
        [job1, job2, job3, job4, job5].forEach(context.insert)
        inv.job = job1   // demo: link the invoice as job1's billing invoice (shows progress billing on the job)
        // A demo Project grouping two jobs, so All Projects + the project roll-up have content.
        let demoProject = Project(name: "Reed kitchen remodel")
        context.insert(demoProject)
        job3.project = demoProject
        job4.project = demoProject
        // A fully-paid invoice billing the completed job4 — so its Billing card reads "Paid in full"
        // and the Completion package becomes available to generate + share.
        let job4Invoice = Invoice.make(from: e1, number: "INV-0002", in: context)
        job4Invoice.createdAt = .now.addingTimeInterval(-12 * 86_400)
        job4Invoice.status = .sent
        job4Invoice.job = job4
        job4.agreedPrice = job4Invoice.total   // contracted == invoiced for a clean paid-in-full
        let job4Pay = InvoicePayment(amount: job4Invoice.total, date: .now.addingTimeInterval(-10 * 86_400),
                                     method: .check, note: "Final payment")
        job4Pay.invoice = job4Invoice
        context.insert(job4Pay)
        job4Invoice.amountDueNow = 0

        // Attach proof-of-work photos, a document, and material/equipment receipts to the completed
        // backsplash job so the Job's Photos / Documents / Receipts sections have content to test.
        r1.job = job4   // Henderson Hardware materials
        r3.job = job4   // Sunbelt wet-saw rental
        let photoBefore = JobAttachment(kind: .photo, name: "Before",
                                        data: demoPhotoData("BEFORE", color: UIColor(red: 0.55, green: 0.50, blue: 0.42, alpha: 1)),
                                        job: job4)
        let photoAfter = JobAttachment(kind: .photo, name: "Finished",
                                       data: demoPhotoData("FINISHED", color: UIColor(red: 0.78, green: 0.62, blue: 0.28, alpha: 1)),
                                       job: job4)
        let permit = JobAttachment(kind: .document, name: "City Permit.pdf",
                                   data: demoDocData("City Permit — Backsplash Install"), job: job4)
        [photoBefore, photoAfter, permit].forEach(context.insert)

        // UI-test-only fixture (gated by a launch arg so it never shows in normal demo / screenshot runs):
        // a round-number invoice — $1,000 work, $300 paid — with one APPROVED, not-yet-added change order
        // of +$200, so the change-order/balance UI test can assert exact figures ($700 before, $900 after).
        if ProcessInfo.processInfo.arguments.contains("-uiTestChangeOrder") {
            let coInv = Invoice(number: "INV-0099", jobTitle: "Fence repair", createdAt: .now,
                                status: .sent, customer: c1)
            context.insert(coInv)
            let coGroup = InvoiceGroup(name: "Labor", sortIndex: 0); coGroup.invoice = coInv
            context.insert(coGroup)
            let coLine = InvoiceLineItem(name: "Fence repair", quantity: 1, unit: .job,
                                         unitPrice: 1000, kind: .labor, isTaxable: false, sortIndex: 0)
            coLine.group = coGroup
            context.insert(coLine)
            let coPay = InvoicePayment(amount: 300, date: .now, method: .check, note: "Deposit")
            coPay.invoice = coInv
            context.insert(coPay)
            coInv.amountDueNow = 0
            let co = ChangeOrder(number: "CO-0001", title: "Added gate", createdAt: .now)
            co.status = .approved
            co.invoice = coInv
            context.insert(co)
            let coItem = ChangeOrderLineItem(name: "Added gate", quantity: 1, unit: .job,
                                             unitPrice: 200, isTaxable: false, sortIndex: 0)
            coItem.changeOrder = co
            context.insert(coItem)
        }

        // Demo Money Data (Bank Accounts, Transactions, Rules, Subscriptions per Finding 11)
        let chaseChecking = BankAccount(
            plaidAccountId: "acc_demo_chase_4821",
            itemId: "item_demo_chase",
            institutionName: "Chase",
            name: "Chase Business Complete",
            mask: "4821",
            subtypeRaw: "checking",
            currentBalanceCents: 24_850_00,
            isoCurrencyCode: "USD"
        )
        let amexCard = BankAccount(
            plaidAccountId: "acc_demo_amex_1004",
            itemId: "item_demo_amex",
            institutionName: "American Express",
            name: "Amex Personal Gold",
            mask: "1004",
            subtypeRaw: "credit card",
            currentBalanceCents: 1_280_45,
            isoCurrencyCode: "USD"
        )
        context.insert(chaseChecking)
        context.insert(amexCard)

        let txData: [(acc: String, name: String, merchant: String, cents: Int64, date: String, biz: Bool?, isSub: Bool)] = [
            ("acc_demo_chase_4821", "Henderson Hardware Store #402", "Henderson Hardware", 127_43, "2026-10-20", true, false),
            ("acc_demo_chase_4821", "QuickStop Fuel Miami FL", "QuickStop Fuel", 62_15, "2026-10-23", true, false),
            ("acc_demo_chase_4821", "Adobe Creative Cloud", "Adobe", 34_99, "2026-10-21", true, true),
            ("acc_demo_chase_4821", "Sunbelt Tool Rental #12", "Sunbelt Tool Rental", 450_00, "2026-10-19", true, false),
            ("acc_demo_chase_4821", "The Home Depot #0231", "The Home Depot", 845_20, "2026-10-18", true, false),
            ("acc_demo_chase_4821", "Starbucks Store 10842", "Starbucks", 6_45, "2026-10-22", false, false),
            ("acc_demo_chase_4821", "Shell Oil 575432", "Shell", 48_10, "2026-10-21", true, false),
            ("acc_demo_chase_4821", "QuickBooks Online Payroll", "QuickBooks", 60_00, "2026-10-12", true, true),
            ("acc_demo_chase_4821", "Ferguson Plumbing Supply", "Ferguson", 312_80, "2026-10-16", true, false),
            ("acc_demo_chase_4821", "USPS PO 120485", "USPS", 18_40, "2026-10-15", true, false),
            ("acc_demo_amex_1004", "Netflix.com", "Netflix", 14_99, "2026-10-22", false, true),
            ("acc_demo_amex_1004", "Spotify USA", "Spotify", 11_99, "2026-10-17", false, true),
            ("acc_demo_amex_1004", "Target T-0842", "Target", 84_12, "2026-10-20", false, false),
            ("acc_demo_amex_1004", "Whole Foods Market #102", "Whole Foods", 142_65, "2026-10-19", false, false),
            ("acc_demo_amex_1004", "Chevron 0092144", "Chevron", 54_20, "2026-10-18", false, false),
            ("acc_demo_amex_1004", "Amazon.com*2K84M", "Amazon", 39_50, "2026-10-17", false, false),
            ("acc_demo_amex_1004", "Trader Joe's #541", "Trader Joe's", 76_30, "2026-10-16", false, false),
            ("acc_demo_amex_1004", "Apple.com/bill", "Apple", 2_99, "2026-10-14", false, false)
        ]

        for (idx, t) in txData.enumerated() {
            let tx = BankTransaction(
                plaidTransactionId: "tx_demo_\(idx + 1)",
                plaidAccountId: t.acc,
                name: t.name,
                merchantName: t.merchant,
                amountCents: t.cents,
                isoCurrencyCode: "USD",
                date: t.date,
                pending: false,
                isBusinessOverride: t.biz,
                isTrackedSubscription: t.isSub
            )
            context.insert(tx)
        }

        let rule1 = TransactionCategoryRule(
            normalizedMerchantPattern: "quickstop fuel",
            displayMerchantName: "QuickStop Fuel",
            isBusiness: true
        )
        let rule2 = TransactionCategoryRule(
            normalizedMerchantPattern: "adobe",
            displayMerchantName: "Adobe",
            isBusiness: true
        )
        let rule3 = TransactionCategoryRule(
            normalizedMerchantPattern: "netflix",
            displayMerchantName: "Netflix",
            isBusiness: false
        )
        let rule4 = TransactionCategoryRule(
            normalizedMerchantPattern: "the home depot",
            displayMerchantName: "The Home Depot",
            isBusiness: true
        )
        let rule5 = TransactionCategoryRule(
            normalizedMerchantPattern: "starbucks",
            displayMerchantName: "Starbucks",
            isBusiness: false
        )
        [rule1, rule2, rule3, rule4, rule5].forEach(context.insert)

        let rsub1 = RecurringSubscription(
            plaidStreamId: "stream_demo_1",
            plaidAccountId: "acc_demo_chase_4821",
            merchantName: "Adobe",
            amountCents: 34_99,
            isoCurrencyCode: "USD",
            cadenceRaw: "monthly",
            lastDate: "2026-10-21",
            nextExpectedDate: "2026-11-21",
            isActive: true,
            isBusinessOverride: true
        )
        let rsub2 = RecurringSubscription(
            plaidStreamId: "stream_demo_2",
            plaidAccountId: "acc_demo_chase_4821",
            merchantName: "QuickBooks Online",
            amountCents: 60_00,
            isoCurrencyCode: "USD",
            cadenceRaw: "monthly",
            lastDate: "2026-10-12",
            nextExpectedDate: "2026-11-12",
            isActive: true,
            isBusinessOverride: true
        )
        let rsub3 = RecurringSubscription(
            plaidStreamId: "stream_demo_3",
            plaidAccountId: "acc_demo_amex_1004",
            merchantName: "Netflix",
            amountCents: 14_99,
            isoCurrencyCode: "USD",
            cadenceRaw: "monthly",
            lastDate: "2026-10-22",
            nextExpectedDate: "2026-11-22",
            isActive: true,
            isBusinessOverride: false
        )
        let rsub4 = RecurringSubscription(
            plaidStreamId: "stream_demo_4",
            plaidAccountId: "acc_demo_amex_1004",
            merchantName: "Spotify",
            amountCents: 11_99,
            isoCurrencyCode: "USD",
            cadenceRaw: "monthly",
            lastDate: "2026-10-17",
            nextExpectedDate: "2026-11-17",
            isActive: true,
            isBusinessOverride: false
        )
        [rsub1, rsub2, rsub3, rsub4].forEach(context.insert)

        context.saveChanges()
        ContractMigration.backfill(context)
    }

    /// A solid-color JPEG with a centered label — stands in for a job-site photo in demo mode.
    private static func demoPhotoData(_ label: String, color: UIColor) -> Data? {
        let size = CGSize(width: 1000, height: 750)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            ]
            let text = label as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    /// A one-page PDF with a title — stands in for an uploaded job document in demo mode.
    private static func demoDocData(_ title: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            (title as NSString).draw(at: CGPoint(x: 48, y: 64),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
        }
    }

    @MainActor
    private static func insert(into context: ModelContext, group: EstimateGroup, _ items: [EstimateLineItem]) {
        for (i, item) in items.enumerated() {
            item.sortIndex = i
            item.group = group
            context.insert(item)
        }
    }
}
