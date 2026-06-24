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

#if DEBUG
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
        biz.address = Address(street1: "1280 Commerce Blvd", city: "Tallahassee", state: "FL", postalCode: "32301")
        biz.w9TINTypeRaw = W9TINType.ein.rawValue
        biz.updateTIN("98-7654321")   // payer EIN, so the demo 1099-NEC can be generated
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
                          address: Address(street1: "1180 Capital Cir NE", city: "Tallahassee", state: "FL", postalCode: "32308"))
        let c2 = Customer(firstName: "Danielle", lastName: "Carter", email: "dani.carter@gmail.com",
                          phoneNumber: "(850) 555-0148",
                          address: Address(street1: "742 Magnolia Dr", city: "Tallahassee", state: "FL", postalCode: "32301"))
        let c3 = Customer(firstName: "Sofia", lastName: "Nguyen", email: "sofia@nguyenpm.com",
                          phoneNumber: "(850) 555-0176", businessName: "Nguyen Property Management",
                          address: Address(street1: "305 John Knox Rd", city: "Tallahassee", state: "FL", postalCode: "32303"))
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
        e1.serviceAddress = Address(street1: "88 Lakeshore Dr", city: "Tallahassee", state: "FL", postalCode: "32312")
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
        let pay = InvoicePayment(amount: inv.amountDueNow > 0 ? inv.amountDueNow : inv.total * 0.25,
                                 date: .now.addingTimeInterval(-1 * 86_400), method: .check, note: "Deposit to start")
        pay.invoice = inv
        context.insert(pay)

        // A progress payment so the demo shows a healthy positive net (income comfortably above expenses).
        let pay2 = InvoicePayment(amount: 1400, date: .now.addingTimeInterval(-43_200), method: .check, note: "Progress payment")
        pay2.invoice = inv
        context.insert(pay2)
        // The seed inserts payments directly (bypassing recordPayment, which normally decrements this),
        // so clear the deposit request — it's fully covered by the payments above.
        inv.amountDueNow = 0

        // Demo employees: hours (one crosses 40 → over-40 flag), accrued pay, and a recorded paycheck.
        let nextFriday = Calendar.current.nextDate(after: .now, matching: DateComponents(weekday: 6),
                                                   matchingPolicy: .nextTime) ?? .now
        let emp1 = Employee(firstName: "Jason", lastName: "Garcia", email: "jason.garcia@example.com",
                            phone: "(850) 555-0110", payType: .hourly, hourlyRate: 28,
                            payFrequency: .weekly, anchorPayday: nextFriday,
                            hireDate: .now.addingTimeInterval(-300 * 86_400))
        let emp2 = Employee(firstName: "Rebecca", lastName: "Grimes", email: "rebecca.grimes@example.com",
                            phone: "(850) 555-0121", payType: .hourly, hourlyRate: 24,
                            payFrequency: .biweekly, anchorPayday: nextFriday,
                            hireDate: .now.addingTimeInterval(-540 * 86_400))
        let emp3 = Employee(firstName: "Devin", lastName: "Odom", email: "devin.odom@example.com",
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

        // Demo subcontractors: one over the $600 1099 threshold, one under it.
        let sub1 = Subcontractor(firstName: "Luis", lastName: "Mendoza", businessName: "Mendoza Plumbing",
                                 email: "luis@mendozaplumbing.com", phone: "(850) 555-0164",
                                 address: Address(street1: "904 Industrial Dr", city: "Tallahassee", state: "FL", postalCode: "32310"))
        let sub2 = Subcontractor(firstName: "Tara", lastName: "Boyd", businessName: "Boyd Electric",
                                 email: "tara@boydelectric.com", phone: "(850) 555-0188", hourlyRate: 20)
        [sub1, sub2].forEach(context.insert)
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
        [job1, job2, job3, job4, job5].forEach(context.insert)
        inv.job = job1   // demo: link the invoice as job1's billing invoice (shows progress billing on the job)
        // A demo Project grouping two jobs, so All Projects + the project roll-up have content.
        let demoProject = Project(name: "Reed kitchen remodel")
        context.insert(demoProject)
        job3.project = demoProject
        job4.project = demoProject

        context.saveChanges()
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
#endif
