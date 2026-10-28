//
//  StatsExportTests.swift
//  GLSmallBusinessTests
//

import Testing
import Foundation
@testable import GLSmallBusiness

@MainActor
struct StatsExportTests {
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test func exportProducesReceiptsCSVAndSummary() {
        let receipt = TS.receipt(total: 125.50, category: "Materials", date: TS.day(2026, 6, 1))
        let files = StatsExport.files(period: .year(2026), invoices: [], estimates: [], receipts: [receipt], business: nil)
        #expect(files.count == 2)   // a receipts CSV + a tax summary
        let csv = files.first { $0.lastPathComponent.hasSuffix(".csv") }.map(read) ?? ""
        // Column 5 holds the customer's name (or "Business") — the header must say so.
        #expect(csv.contains("Date,Vendor,Category,Amount,Customer,Notes"))
        #expect(csv.contains("Materials"))
        #expect(csv.contains("125.50"))
        let summary = files.first { $0.lastPathComponent.hasSuffix(".txt") }.map(read) ?? ""
        #expect(summary.contains("Tax summary"))
        #expect(summary.contains("NET"))
    }

    @Test func csvCustomerColumnCarriesCustomerNameOrBusiness() {
        let assigned = TS.receipt(total: 20, category: "Materials", date: TS.day(2026, 6, 1))
        assigned.customer = Customer(firstName: "Dana", lastName: "Reed")
        let general = TS.receipt(total: 5, category: "Fuel", date: TS.day(2026, 6, 2))
        let files = StatsExport.files(period: .year(2026), invoices: [], estimates: [], receipts: [assigned, general], business: nil)
        let csv = files.first { $0.lastPathComponent.hasSuffix(".csv") }.map(read) ?? ""
        #expect(csv.contains("\"Reed, Dana\""))   // listDisplayName is "Last, First" → CSV-quoted
        #expect(csv.contains("Business"))         // unassigned receipts fall back to Business
    }

    @Test func csvNeutralizesFormulaInjection() {
        // A vendor that starts with "=" would execute as a formula in Excel/Numbers.
        let r = Receipt(vendor: "=HYPERLINK(\"evil\")", date: TS.day(2026, 6, 1), total: 10, category: "X")
        let files = StatsExport.files(period: .year(2026), invoices: [], estimates: [], receipts: [r], business: nil)
        let csv = files.first { $0.lastPathComponent.hasSuffix(".csv") }.map(read) ?? ""
        // The dangerous field is prefixed with a quote so spreadsheets treat it as text.
        #expect(csv.contains("'=HYPERLINK"))
        #expect(!csv.contains(",=HYPERLINK"))   // never a bare leading '='
    }

    @Test func csvQuotesFieldsWithCommas() {
        let r = Receipt(vendor: "Smith, Jones & Co", date: TS.day(2026, 6, 1), total: 5, category: "X")
        let files = StatsExport.files(period: .year(2026), invoices: [], estimates: [], receipts: [r], business: nil)
        let csv = files.first { $0.lastPathComponent.hasSuffix(".csv") }.map(read) ?? ""
        #expect(csv.contains("\"Smith, Jones & Co\""))
    }

    @Test func summaryIncludesBusinessNameAndNet() {
        let profile = BusinessProfile()
        profile.businessName = "Gold Life LLC"
        let inv = TS.invoice(createdAt: TS.day(2026, 6, 1), lines: [(1000, false)])
        TS.pay(inv, 1000, date: TS.day(2026, 6, 1))
        let files = StatsExport.files(period: .year(2026), invoices: [inv], estimates: [], receipts: [], business: profile)
        let summary = files.first { $0.lastPathComponent.hasSuffix(".txt") }.map(read) ?? ""
        #expect(summary.contains("Gold Life LLC"))
        #expect(summary.contains("Collected"))
    }
}
