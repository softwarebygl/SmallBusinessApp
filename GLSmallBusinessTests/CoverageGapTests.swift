//
//  CoverageGapTests.swift
//  GLSmallBusinessTests
//
//  Remaining unit-testable logic that was sitting at 0%: URL.readSecurityScoped, Receipt.displayVendor,
//  the per-document nextNumber sequences, and DemoMode.isActive.
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct URLReadTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).bin")
    }

    @Test func readsNonEmptyFile() throws {
        let url = tempURL("read")
        let data = Data("hello".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.readSecurityScoped() == data)
    }

    @Test func emptyFileReturnsNil() throws {
        let url = tempURL("empty")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.readSecurityScoped() == nil)
    }

    @Test func missingFileReturnsNil() {
        #expect(tempURL("missing").readSecurityScoped() == nil)
    }
}

@MainActor
struct ReceiptDisplayVendorTests {
    @Test func usesVendorWhenPresent() {
        let r = Receipt(vendor: "Home Depot", date: .now, total: 42, category: "Materials")
        #expect(r.displayVendor == "Home Depot")
    }

    @Test func fallsBackWhenBlank() {
        #expect(Receipt(vendor: "", date: .now, total: 1, category: "x").displayVendor == "Receipt")
        #expect(Receipt(vendor: "   ", date: .now, total: 1, category: "x").displayVendor == "Receipt")
    }
}

@MainActor
struct NextNumberTests {
    @Test func estimateSequenceAndGarbage() {
        #expect(Estimate.nextNumber(after: []) == "EST-0001")
        #expect(Estimate.nextNumber(after: [TS.estimate(number: "EST-0007")]) == "EST-0008")
        #expect(Estimate.nextNumber(after: [TS.estimate(number: "EST-abc")]) == "EST-0001")   // non-numeric ignored
    }

    @Test func invoiceSequence() {
        #expect(Invoice.nextNumber(after: []) == "INV-0001")
        #expect(Invoice.nextNumber(after: [Invoice(number: "INV-0042")]) == "INV-0043")
    }

    @Test func changeOrderSequence() {
        #expect(ChangeOrder.nextNumber(after: []) == "CO-0001")
        let co = ChangeOrder(number: "CO-0003", title: "x", taxRatePercent: 0)
        #expect(ChangeOrder.nextNumber(after: [co]) == "CO-0004")
    }
}

@MainActor
struct DemoModeTests {
    @Test func inactiveWithoutLaunchArgument() {
        // The test runner never passes `-demoMode`, so the gate stays off.
        #expect(DemoMode.isActive == false)
    }
}
