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
        biz.businessName = "Evolved by GL"
        biz.phone = "(850) 555-0142"
        biz.email = "hello@evolvedbygl.com"
        biz.licenseNumber = "FL-CBC1525487"
        biz.address = Address(street1: "2491 Dundee Dr", city: "Tallahassee", state: "FL", postalCode: "32308")
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

        try? context.save()

        // Invoice — converted from Estimate 2, deposit paid (Partially Paid)
        let inv = Invoice.make(from: e2, number: "INV-0001", in: context)
        inv.createdAt = .now.addingTimeInterval(-3 * 86_400)
        inv.status = .sent
        let pay = InvoicePayment(amount: inv.amountDueNow > 0 ? inv.amountDueNow : inv.total * 0.25,
                                 date: .now.addingTimeInterval(-1 * 86_400), method: .check, note: "Deposit to start")
        pay.invoice = inv
        context.insert(pay)

        try? context.save()
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
