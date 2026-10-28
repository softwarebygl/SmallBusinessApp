//
//  AccessGatePaginationTests.swift
//  GLSmallBusinessTests
//
//  Covers two pieces that were exercised only at runtime: the freemium cap gate (AccessGate) and the
//  shared PDF paginator (PaginatedPDF). Both are new and load-bearing, so they get real unit tests.
//

import Testing
import SwiftUI
import SwiftData
import PDFKit
@testable import GLSmallBusiness

@MainActor
struct AccessGateTests {
    @Test func capLogicAcrossEntitlementStates() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let subs = SubscriptionManager.shared
        // Host-process pin: a leftover sample-mode flag opens every gate
        // (sample data is never capped) and fails the blocked expectations.
        UserDemoMode.shared.isDemoActive = false

        func addCustomers(_ n: Int) throws {
            for _ in 0..<n { ctx.insert(Customer(firstName: "T", lastName: "C")) }
            try ctx.save()
        }

        // Status not yet known (cold launch / loading) -> gate stays OPEN so a real subscriber is never
        // briefly walled, even when over the cap.
        try addCustomers(5)
        subs.isSubscribed = false; subs.statusKnown = false
        #expect(AccessGate.decide(Customer.self, cap: 2, in: ctx, subscription: subs) == .allowed)

        // Subscribed -> always allowed, even far over the cap.
        subs.isSubscribed = true; subs.statusKnown = true
        #expect(AccessGate.decide(Customer.self, cap: 2, in: ctx, subscription: subs) == .allowed)

        // Known not-subscribed and AT/OVER the cap -> blocked (5 >= 2).
        subs.isSubscribed = false; subs.statusKnown = true
        #expect(AccessGate.decide(Customer.self, cap: 2, in: ctx, subscription: subs) != .allowed)

        // Known not-subscribed but UNDER the cap -> allowed (5 < 10).
        #expect(AccessGate.decide(Customer.self, cap: 10, in: ctx, subscription: subs) == .allowed)

        // Reset shared state so it can't leak into other tests.
        subs.isSubscribed = false; subs.statusKnown = false
    }
}

@MainActor
struct PaginatedPDFTests {
    @Test func splitsTallContentIntoLetterPages() throws {
        // ~120 rows × 30pt ≈ 3600pt of content — several US-Letter (792pt) pages tall.
        let tall = VStack(spacing: 0) {
            ForEach(0..<120, id: \.self) { i in
                Text("Line \(i)").frame(maxWidth: .infinity, minHeight: 30)
            }
        }
        .frame(width: PaginatedPDF.pageWidth)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pgtest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PaginatedPDF.render(tall, width: PaginatedPDF.pageWidth, to: url) != nil)
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount >= 3)   // proves it actually paginates instead of one oversized page
        for i in 0..<doc.pageCount {
            let box = try #require(doc.page(at: i)).bounds(for: .mediaBox)
            #expect(abs(box.width - PaginatedPDF.pageWidth) < 1)
            #expect(abs(box.height - PaginatedPDF.pageHeight) < 1)   // every page is true Letter size
        }
    }

    @Test func shortContentIsASinglePage() throws {
        let short = Text("Just one line").frame(width: PaginatedPDF.pageWidth)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pgtest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PaginatedPDF.render(short, width: PaginatedPDF.pageWidth, to: url) != nil)
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 1)
    }
}
