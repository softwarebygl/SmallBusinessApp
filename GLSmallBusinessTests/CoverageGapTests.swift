//
//  CoverageGapTests.swift
//  GLSmallBusinessTests
//
//  Remaining unit-testable logic that was sitting at 0%: the Files importers' read, Receipt.displayVendor,
//  and DemoMode.isActive. (Document numbering lives in DocumentNumberingTests.)
//

import Testing
import Foundation
@testable import GLSmallBusiness

/// The Files importers' read (`FileImport.read`, which replaced the main-thread
/// `URL.readSecurityScoped` in the F124 fix; the size limit is in FileImportLimitTests).
struct URLReadTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).bin")
    }

    @Test func readsNonEmptyFile() async throws {
        let url = tempURL("read")
        let data = Data("hello".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await FileImport.read(url) == .success(data))
    }

    @Test func emptyFileIsUnreadable() async throws {
        let url = tempURL("empty")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await FileImport.read(url) == .failure(.unreadable))
    }

    @Test func missingFileIsUnreadable() async {
        #expect(await FileImport.read(tempURL("missing")) == .failure(.unreadable))
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
struct DemoModeTests {
    @Test func inactiveWithoutLaunchArgument() {
        // The test runner never passes `-demoMode`, so the gate stays off.
        #expect(DemoMode.isActive == false)
    }
}
